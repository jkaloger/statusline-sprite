const std = @import("std");
const anim = @import("anim.zig");
const kitty = @import("kitty.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Cap on a single frame PNG read, matching the statusline's `loadFrames`.
const max_frame_bytes: usize = 1 << 20;

/// Tick interval used only when a manifest can't be read this tick (transiently
/// corrupt/unreadable, never fully gone). Just paces the retry loop.
const fallback_gap_ms: u32 = 100;

/// How the binary was invoked. The two hidden flags re-enter the same binary in
/// daemon-related modes; everything else is the ordinary statusline run.
pub const Invocation = union(enum) {
    normal,
    /// `--animate <manifest>`: become the resident animator daemon.
    animate: []const u8,
    /// `--ensure-daemon <manifest>`: run the statusline-side ensure-check once
    /// and exit. A test/ops hook for driving `ensureDaemon` from a real,
    /// short-lived parent process (T4 wires the ensure-check into the normal
    /// flow; this flag is not that wiring).
    ensure: []const u8,
};

/// Pure argv classifier. `argv[0]` is the exe path and is skipped. A flag with
/// no following path falls through to `.normal` (nothing to animate).
pub fn classify(argv: []const []const u8) Invocation {
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--animate")) {
            if (i + 1 < argv.len) return .{ .animate = argv[i + 1] };
        } else if (std.mem.eql(u8, argv[i], "--ensure-daemon")) {
            if (i + 1 < argv.len) return .{ .ensure = argv[i + 1] };
        }
    }
    return .normal;
}

/// Take the singleton lock, or return null if another daemon already holds it.
/// A non-blocking `tryLock` (not `state.Locked`'s blocking `.lock = .exclusive`)
/// so the loser exits immediately rather than queueing behind the winner. The
/// returned file must stay open for the daemon's whole life — the flock releases
/// on close or process death.
fn acquireLock(io: Io, path: []const u8) !?Io.File {
    if (std.fs.path.dirname(path)) |parent| {
        Io.Dir.cwd().createDirPath(io, parent) catch {};
    }
    const file = try Io.Dir.createFileAbsolute(io, path, .{ .read = true, .truncate = false });
    const got = file.tryLock(io, .exclusive) catch |e| {
        file.close(io);
        return e;
    };
    if (!got) {
        file.close(io);
        return null;
    }
    return file;
}

/// Effective per-tick gap in milliseconds: `max(gap_ms, ceil(1000 / max_fps))`,
/// so the daemon never transmits faster than `max_fps`. `max_fps == 0` disables
/// the floor (used only defensively; the manifest defaults it to 30).
pub fn effectiveGapMs(gap_ms: u32, max_fps: u32) u32 {
    if (max_fps == 0) return gap_ms;
    const floor_ms: u32 = @intCast((1000 + @as(u64, max_fps) - 1) / max_fps);
    return @max(gap_ms, floor_ms);
}

/// The daemon-owned frame index. Advances one frame per tick, wrapping mod N; a
/// changed (or first-seen) manifest signature restarts the cycle at frame 0.
const FrameCursor = struct {
    index: usize = 0,
    sig: ?u64 = null,

    /// Index to transmit this tick, given the manifest's current signature and
    /// frame count. Same signature ⇒ advance; new/changed signature ⇒ frame 0.
    fn tick(self: *FrameCursor, sig: u64, n: usize) usize {
        std.debug.assert(n >= 1);
        if (self.sig != null and self.sig.? == sig) {
            self.index = (self.index + 1) % n;
        } else {
            self.index = 0;
        }
        self.sig = sig;
        if (self.index >= n) self.index = 0; // signature collision with a shrunk N
        return self.index;
    }
};

/// Decoded frame bytes for one manifest signature. Reloaded from disk only when
/// the signature changes, so an unchanged tier isn't re-read every tick.
const FrameCache = struct {
    sig: ?u64 = null,
    frames: [][]u8 = &.{},

    fn deinit(self: *FrameCache, gpa: Allocator) void {
        for (self.frames) |b| gpa.free(b);
        if (self.frames.len != 0) gpa.free(self.frames);
        self.frames = &.{};
        self.sig = null;
    }

    /// Frame bytes for `m`'s signature. Cache hit when the signature is
    /// unchanged; otherwise every frame is re-read from its absolute path.
    fn get(self: *FrameCache, gpa: Allocator, io: Io, m: anim.Manifest) ![]const []const u8 {
        if (self.sig) |s| {
            if (s == m.frame_sig) return self.frames;
        }
        self.deinit(gpa);

        const bytes = try gpa.alloc([]u8, m.frames.len);
        errdefer gpa.free(bytes);
        var loaded: usize = 0;
        errdefer for (bytes[0..loaded]) |b| gpa.free(b);
        for (m.frames, 0..) |path, i| {
            bytes[i] = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_frame_bytes));
            loaded = i + 1;
        }

        self.frames = bytes;
        self.sig = m.frame_sig;
        return self.frames;
    }
};

/// Bare `a=t` re-transmit of one frame to `image_id`, tmux-wrapped when asked,
/// written to the already-open tty. This is the whole daemon repaint (S1
/// outcome (a)): no `a=p`, no delete, no placeholder text, no `a=f`/`a=a`.
fn emitFrame(gpa: Allocator, io: Io, tty: Io.File, tmux: bool, image_id: u32, png: []const u8) !void {
    const esc = try kitty.transmit(gpa, image_id, png, .{});
    defer gpa.free(esc);
    if (tmux) {
        const wrapped = try kitty.wrapTmux(gpa, esc);
        defer gpa.free(wrapped);
        try tty.writeStreamingAll(io, wrapped);
    } else {
        try tty.writeStreamingAll(io, esc);
    }
}

/// Daemon entrypoint (`--animate <manifest>`). Singleton via the daemon lock
/// (loser exits), then `setsid` for a fresh session, then the frame loop.
///
/// Per tick: take the manifest lock, read it, release BEFORE sleeping; advance
/// the frame cursor (signature change resets it); re-transmit the current frame
/// with bare `a=t` to the manifest's tty; sleep the effective (max_fps-clamped)
/// gap. The manifest is re-read each tick, so gap/frames/fps changes take effect
/// without a restart. Exits when the manifest is removed (the deterministic
/// stop). TODO(T5): heartbeat-TTL exit, tty-write-failure exit, single write
/// under the shared lock.
pub fn run(gpa: Allocator, io: Io, manifest_path: []const u8) void {
    const lock_path = anim.daemonLockPathFromManifest(gpa, manifest_path) catch return;
    defer gpa.free(lock_path);

    const maybe_lock = acquireLock(io, lock_path) catch return;
    var lock = maybe_lock orelse return; // another daemon owns this target
    defer lock.close(io);

    // A fresh exec is never a process-group leader, so this succeeds and
    // detaches the daemon into its own session. libc-only (see build.zig).
    _ = std.c.setsid();

    var cursor: FrameCursor = .{};
    var cache: FrameCache = .{};
    defer cache.deinit(gpa);
    // Opened lazily from the first readable manifest and kept for the daemon's
    // life: writeStreamingAll advances the fd offset, so successive frames
    // append on a captured regular file and stream to a real tty. TODO(T5): a
    // tty path change or write failure should trigger reopen/exit.
    var tty: ?Io.File = null;
    defer if (tty) |t| t.close(io);

    var gap_ms: u32 = fallback_gap_ms;
    while (true) {
        var read: anim.TickRead = anim.readManifestTick(gpa, io, manifest_path) catch .invalid;
        switch (read) {
            .gone => return,
            .invalid => {},
            .ok => |*parsed| {
                defer parsed.deinit();
                const m = parsed.value;
                gap_ms = effectiveGapMs(m.gap_ms, m.max_fps);

                const idx = cursor.tick(m.frame_sig, m.frames.len);
                if (cache.get(gpa, io, m)) |frame_bytes| {
                    if (tty == null)
                        tty = Io.Dir.openFileAbsolute(io, m.tty_path, .{ .mode = .write_only }) catch null;
                    if (tty) |t|
                        emitFrame(gpa, io, t, m.tmux, m.image_id, frame_bytes[idx]) catch {};
                } else |_| {}
            },
        }
        io.sleep(.fromMilliseconds(gap_ms), .awake) catch {};
    }
}

/// Statusline-side "ensure a daemon is running for this target". Non-blocking
/// flock probe on the daemon lock: held ⇒ a daemon is alive, return null;
/// free ⇒ release the probe and spawn a detached `--animate <manifest>` child
/// (the S2 mechanism: `.ignore` stdio + never `wait()`, so the child reparents
/// to pid 1 and holds none of our fds), returning its pid.
///
/// TOCTOU-racy by design — two callers can both spawn; `run`'s loser-exits rule
/// collapses that to one live daemon. NOT wired into the statusline flow (T4).
pub fn ensureDaemon(gpa: Allocator, io: Io, lock_path: []const u8, manifest_path: []const u8) !?std.process.Child.Id {
    if (std.fs.path.dirname(lock_path)) |parent| {
        Io.Dir.cwd().createDirPath(io, parent) catch {};
    }
    const probe = Io.Dir.createFileAbsolute(io, lock_path, .{ .read = true, .truncate = false }) catch return null;
    const free = probe.tryLock(io, .exclusive) catch {
        probe.close(io);
        return null;
    };
    if (!free) {
        probe.close(io);
        return null; // a daemon holds the lock
    }
    probe.close(io); // release so the spawned daemon can take it

    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);

    const child = try std.process.spawn(io, .{
        .argv = &.{ exe, "--animate", manifest_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    // Detach: we never call child.wait(); on our exit it reparents to pid 1.
    return child.id;
}

test "classify: --animate with a path yields animate mode" {
    const argv: []const []const u8 = &.{ "/bin/statusline-sprite", "--animate", "/state/anim-abc" };
    switch (classify(argv)) {
        .animate => |m| try std.testing.expectEqualStrings("/state/anim-abc", m),
        else => return error.WrongMode,
    }
}

test "classify: --ensure-daemon with a path yields ensure mode" {
    const argv: []const []const u8 = &.{ "/bin/statusline-sprite", "--ensure-daemon", "/state/anim-abc" };
    switch (classify(argv)) {
        .ensure => |m| try std.testing.expectEqualStrings("/state/anim-abc", m),
        else => return error.WrongMode,
    }
}

test "classify: no flag, or a flag with no following path, is normal" {
    try std.testing.expectEqual(Invocation.normal, classify(&.{"/bin/statusline-sprite"}));
    try std.testing.expectEqual(Invocation.normal, classify(&.{ "/bin/statusline-sprite", "--animate" }));
    try std.testing.expectEqual(Invocation.normal, classify(&.{ "/bin/statusline-sprite", "other", "args" }));
}

test "effectiveGapMs: clamps to the max_fps floor, else keeps gap_ms" {
    // 125ms (8fps) is already slower than the 30fps floor (34ms): unchanged.
    try std.testing.expectEqual(@as(u32, 125), effectiveGapMs(125, 30));
    // 10ms (100fps) is faster than 30fps: clamped up to ceil(1000/30)=34.
    try std.testing.expectEqual(@as(u32, 34), effectiveGapMs(10, 30));
    try std.testing.expectEqual(@as(u32, 34), effectiveGapMs(0, 30));
    // ceil, not floor: 1000/3 = 333.3 -> 334.
    try std.testing.expectEqual(@as(u32, 334), effectiveGapMs(0, 3));
    // exactly at the floor stays.
    try std.testing.expectEqual(@as(u32, 34), effectiveGapMs(34, 30));
    // max_fps 0 disables the floor.
    try std.testing.expectEqual(@as(u32, 100), effectiveGapMs(100, 0));
}

test "FrameCursor: advances mod N and resets to 0 on a signature change" {
    var c: FrameCursor = .{};
    // first tick is always frame 0, then cycles.
    try std.testing.expectEqual(@as(usize, 0), c.tick(0xaa, 3));
    try std.testing.expectEqual(@as(usize, 1), c.tick(0xaa, 3));
    try std.testing.expectEqual(@as(usize, 2), c.tick(0xaa, 3));
    try std.testing.expectEqual(@as(usize, 0), c.tick(0xaa, 3)); // wrap
    try std.testing.expectEqual(@as(usize, 1), c.tick(0xaa, 3));

    // a signature change restarts the cycle at 0.
    try std.testing.expectEqual(@as(usize, 0), c.tick(0xbb, 2));
    try std.testing.expectEqual(@as(usize, 1), c.tick(0xbb, 2));
    try std.testing.expectEqual(@as(usize, 0), c.tick(0xbb, 2));

    // single-frame tier: always frame 0.
    try std.testing.expectEqual(@as(usize, 0), c.tick(0xcc, 1));
    try std.testing.expectEqual(@as(usize, 0), c.tick(0xcc, 1));
}

test "FrameCache: hit on unchanged signature skips re-read; changed signature reloads" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "0.png", .data = "AAA" });
    try tmp.dir.writeFile(io, .{ .sub_path = "1.png", .data = "BBB" });

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const f0 = try std.fmt.allocPrint(a, "{s}/0.png", .{dir});
    defer a.free(f0);
    const f1 = try std.fmt.allocPrint(a, "{s}/1.png", .{dir});
    defer a.free(f1);

    var m: anim.Manifest = .{
        .image_id = 100,
        .gap_ms = 100,
        .max_fps = 30,
        .tmux = false,
        .tty_path = "/dev/null",
        .frames = &.{ f0, f1 },
        .frame_sig = 1,
    };

    var cache: FrameCache = .{};
    defer cache.deinit(a);

    const first = try cache.get(a, io, m);
    try std.testing.expectEqualStrings("AAA", first[0]);
    try std.testing.expectEqualStrings("BBB", first[1]);
    const cached_ptr = first.ptr;

    // Rewrite disk but keep the signature: a cache hit must NOT re-read.
    try tmp.dir.writeFile(io, .{ .sub_path = "0.png", .data = "ZZZ" });
    const hit = try cache.get(a, io, m);
    try std.testing.expectEqual(cached_ptr, hit.ptr);
    try std.testing.expectEqualStrings("AAA", hit[0]);

    // A new signature invalidates the cache and re-reads.
    m.frame_sig = 2;
    const reloaded = try cache.get(a, io, m);
    try std.testing.expectEqualStrings("ZZZ", reloaded[0]);
    try std.testing.expectEqualStrings("BBB", reloaded[1]);
}

test "acquireLock: first caller wins, second gets null (loser-exits primitive)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/daemon-abc.lock", .{dir});
    defer a.free(path);

    var first = (try acquireLock(io, path)).?;
    defer first.close(io);

    try std.testing.expectEqual(@as(?Io.File, null), try acquireLock(io, path));
}
