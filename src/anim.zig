const std = @import("std");
const state = @import("state.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The statusline->daemon handoff: everything the detached animator needs to
/// re-transmit frames to a stable image id without re-resolving config or cwd.
/// Frame paths and the tty path are ABSOLUTE — the daemon's cwd is not the
/// statusline's (see SPEC-007 "Animation manifest").
pub const Manifest = struct {
    image_id: u32,
    gap_ms: u32,
    /// Hard fps cap (SPEC-007 config, default 30). The daemon clamps its tick
    /// interval so it never transmits faster than this, bounding tty-write
    /// frequency. T4/T6 populate it from config; a manifest written without the
    /// field parses back at `default_max_fps` for forward/backward compat.
    max_fps: u32,
    /// Heartbeat staleness the daemon tolerates before exiting, in milliseconds
    /// (SPEC-007 config, default 5000). The statusline writes it from
    /// `sprite.daemon_ttl_ms`; a manifest without the field parses back at
    /// `default_daemon_ttl_ms` for forward/backward compat.
    daemon_ttl_ms: u32,
    tmux: bool,
    tty_path: []const u8,
    frames: []const []const u8,
    frame_sig: u64,
};

/// Applied when a manifest omits `max_fps` (older writer, or a hand-edited file).
pub const default_max_fps: u32 = 30;

/// Applied when a manifest omits `daemon_ttl_ms`.
pub const default_daemon_ttl_ms: u32 = 5000;

/// A parsed manifest whose strings live in an arena. Caller must `deinit`.
pub const Parsed = struct {
    value: Manifest,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *Parsed) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

/// `$XDG_STATE_HOME/statusline-sprite/anim-<key hex>` (or the HOME fallback),
/// alongside `state-<key>`. Mirrors `state.resolveStatePath`. Caller owns it.
pub fn manifestPath(allocator: Allocator, xdg_state_home: ?[]const u8, home: ?[]const u8, key: u64) ![]u8 {
    return statePathNamed(allocator, xdg_state_home, home, "anim", key);
}

/// `heartbeat-<key hex>` alongside the manifest. A SEPARATE file from the
/// manifest so a manifest read never bumps the liveness clock. Caller owns it.
pub fn heartbeatPath(allocator: Allocator, xdg_state_home: ?[]const u8, home: ?[]const u8, key: u64) ![]u8 {
    return statePathNamed(allocator, xdg_state_home, home, "heartbeat", key);
}

/// `daemon-<key hex>.lock` alongside the manifest — the singleton lock for one
/// animator daemon per graphics target. The statusline's `ensureDaemon` probes
/// this via (xdg, home, key); the daemon, which only receives its manifest path
/// on argv, re-derives the identical path with `daemonLockPathFromManifest`.
/// Caller owns the result.
pub fn daemonLockPath(allocator: Allocator, xdg_state_home: ?[]const u8, home: ?[]const u8, key: u64) ![]u8 {
    if (xdg_state_home) |xdg| {
        if (xdg.len != 0)
            return std.fmt.allocPrint(allocator, "{s}/statusline-sprite/daemon-{x:0>16}.lock", .{ xdg, key });
    }
    if (home) |h| {
        if (h.len != 0)
            return std.fmt.allocPrint(allocator, "{s}/.local/state/statusline-sprite/daemon-{x:0>16}.lock", .{ h, key });
    }
    return error.NoStateDir;
}

/// Re-derive the daemon lock path from a manifest path produced by
/// `manifestPath`: swap the `anim-` basename prefix for `daemon-` and append
/// `.lock`, keeping the same directory. Byte-identical to `daemonLockPath` for
/// the same key, so the daemon and the statusline probe the same file without
/// the daemon re-computing the key. Errors if the path is not an `anim-` file.
/// Caller owns the result.
pub fn daemonLockPathFromManifest(allocator: Allocator, manifest_path: []const u8) ![]u8 {
    return siblingFromManifest(allocator, manifest_path, "daemon", ".lock");
}

/// Re-derive the heartbeat path (`anim-<x>` → `heartbeat-<x>`) from a manifest
/// path, so the daemon can find the liveness file it was never handed on argv.
/// Byte-identical to `heartbeatPath` for the same key. Caller owns the result.
pub fn heartbeatPathFromManifest(allocator: Allocator, manifest_path: []const u8) ![]u8 {
    return siblingFromManifest(allocator, manifest_path, "heartbeat", "");
}

/// Re-derive the state path (`anim-<x>` → `state-<x>`) from a manifest path.
/// This is the file the statusline flocks around its transmit; the daemon takes
/// the SAME lock around each tty write so the two never interleave. Byte-identical
/// to `state.resolveStatePath` for the same key. Caller owns the result.
pub fn statePathFromManifest(allocator: Allocator, manifest_path: []const u8) ![]u8 {
    return siblingFromManifest(allocator, manifest_path, "state", "");
}

/// Swap an `anim-<key>` manifest basename for `<prefix>-<key><suffix>`, keeping
/// the directory. Errors if the path is not an `anim-` file. Caller owns it.
fn siblingFromManifest(allocator: Allocator, manifest_path: []const u8, comptime prefix: []const u8, comptime suffix: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(manifest_path) orelse return error.BadManifestPath;
    const base = std.fs.path.basename(manifest_path);
    if (!std.mem.startsWith(u8, base, "anim-")) return error.BadManifestPath;
    const key = base["anim-".len..];
    return std.fmt.allocPrint(allocator, "{s}/" ++ prefix ++ "-{s}" ++ suffix, .{ dir, key });
}

fn statePathNamed(allocator: Allocator, xdg_state_home: ?[]const u8, home: ?[]const u8, comptime prefix: []const u8, key: u64) ![]u8 {
    if (xdg_state_home) |xdg| {
        if (xdg.len != 0)
            return std.fmt.allocPrint(allocator, "{s}/statusline-sprite/" ++ prefix ++ "-{x:0>16}", .{ xdg, key });
    }
    if (home) |h| {
        if (h.len != 0)
            return std.fmt.allocPrint(allocator, "{s}/.local/state/statusline-sprite/" ++ prefix ++ "-{x:0>16}", .{ h, key });
    }
    return error.NoStateDir;
}

/// Whether a freshly-computed signature differs from the one a manifest stored.
/// The daemon resets its frame counter to 0 when this is true.
pub fn signatureChanged(stored: u64, current: u64) bool {
    return stored != current;
}

/// Asserts every path is absolute — a relative path in the manifest would be
/// resolved against the daemon's cwd, not the statusline's. Caller owns the result.
pub fn serialize(allocator: Allocator, m: Manifest) ![]u8 {
    std.debug.assert(std.fs.path.isAbsolute(m.tty_path));
    for (m.frames) |f| std.debug.assert(std.fs.path.isAbsolute(f));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "image_id = {d}\ngap_ms = {d}\nmax_fps = {d}\ndaemon_ttl_ms = {d}\ntmux = {d}\ntty = {s}\nframe_sig = {x}\n", .{
        m.image_id, m.gap_ms, m.max_fps, m.daemon_ttl_ms, @intFromBool(m.tmux), m.tty_path, m.frame_sig,
    });
    for (m.frames) |f| try out.print(allocator, "frame = {s}\n", .{f});
    return out.toOwnedSlice(allocator);
}

/// Tolerant: any missing/garbled field, an empty frame list, or a non-absolute
/// path yields null ("no valid manifest"), never a crash. Allocation failure is
/// the only error. Frame order is preserved.
pub fn parse(allocator: Allocator, bytes: []const u8) Allocator.Error!?Parsed {
    var image_id: ?u32 = null;
    var gap_ms: ?u32 = null;
    var max_fps: ?u32 = null;
    var daemon_ttl_ms: ?u32 = null;
    var tmux: ?bool = null;
    var frame_sig: ?u64 = null;
    var tty_path: ?[]const u8 = null;
    var frames: std.ArrayList([]const u8) = .empty;
    defer frames.deinit(allocator);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "image_id")) {
            image_id = std.fmt.parseInt(u32, rhs, 10) catch return null;
        } else if (std.mem.eql(u8, key, "gap_ms")) {
            gap_ms = std.fmt.parseInt(u32, rhs, 10) catch return null;
        } else if (std.mem.eql(u8, key, "max_fps")) {
            max_fps = std.fmt.parseInt(u32, rhs, 10) catch return null;
        } else if (std.mem.eql(u8, key, "daemon_ttl_ms")) {
            daemon_ttl_ms = std.fmt.parseInt(u32, rhs, 10) catch return null;
        } else if (std.mem.eql(u8, key, "tmux")) {
            if (std.mem.eql(u8, rhs, "1")) {
                tmux = true;
            } else if (std.mem.eql(u8, rhs, "0")) {
                tmux = false;
            } else return null;
        } else if (std.mem.eql(u8, key, "frame_sig")) {
            frame_sig = std.fmt.parseInt(u64, rhs, 16) catch return null;
        } else if (std.mem.eql(u8, key, "tty")) {
            if (!std.fs.path.isAbsolute(rhs)) return null;
            tty_path = rhs;
        } else if (std.mem.eql(u8, key, "frame")) {
            if (!std.fs.path.isAbsolute(rhs)) return null;
            try frames.append(allocator, rhs);
        }
    }

    const id = image_id orelse return null;
    const gap = gap_ms orelse return null;
    const tm = tmux orelse return null;
    const sig = frame_sig orelse return null;
    const tty = tty_path orelse return null;
    if (frames.items.len == 0) return null;

    // Only once fully valid do we allocate — nothing to unwind on a null return.
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const tty_dup = try a.dupe(u8, tty);
    const frame_dup = try a.alloc([]const u8, frames.items.len);
    for (frames.items, 0..) |f, i| frame_dup[i] = try a.dupe(u8, f);

    return .{
        .value = .{
            .image_id = id,
            .gap_ms = gap,
            .max_fps = max_fps orelse default_max_fps,
            .daemon_ttl_ms = daemon_ttl_ms orelse default_daemon_ttl_ms,
            .tmux = tm,
            .tty_path = tty_dup,
            .frames = frame_dup,
            .frame_sig = sig,
        },
        .arena = arena,
    };
}

/// Manifest file under an exclusive advisory lock, mirroring `state.Locked`'s
/// flock discipline. The daemon takes the lock, reads, and releases it BEFORE
/// sleeping (SPEC-007) — parsing is a separate `read` step so `open` stays
/// allocator-free.
pub const Locked = struct {
    file: Io.File,
    mtime_ns: i96,

    pub fn open(io: Io, path: []const u8) !Locked {
        if (std.fs.path.dirname(path)) |parent| {
            Io.Dir.cwd().createDirPath(io, parent) catch {};
        }
        const file = try Io.Dir.createFileAbsolute(io, path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
        });
        errdefer file.close(io);
        const st = try file.stat(io);
        return .{ .file = file, .mtime_ns = st.mtime.nanoseconds };
    }

    /// Parse the current contents. Null when the file is empty or corrupt.
    /// Returned value survives `close`.
    pub fn read(self: *Locked, allocator: Allocator, io: Io) !?Parsed {
        const st = try self.file.stat(io);
        const buf = try allocator.alloc(u8, @intCast(st.size));
        defer allocator.free(buf);
        const n = try self.file.readPositionalAll(io, buf, 0);
        return parse(allocator, buf[0..n]);
    }

    pub fn write(self: *Locked, allocator: Allocator, io: Io, manifest: Manifest) !void {
        const bytes = try serialize(allocator, manifest);
        defer allocator.free(bytes);
        try self.file.writePositionalAll(io, bytes, 0);
        try self.file.setLength(io, bytes.len);
    }

    pub fn close(self: *Locked, io: Io) void {
        self.file.close(io);
    }
};

/// Locked one-shot write for the statusline's per-invocation manifest refresh.
pub fn writeManifest(allocator: Allocator, io: Io, path: []const u8, manifest: Manifest) !void {
    var locked = try Locked.open(io, path);
    defer locked.close(io);
    try locked.write(allocator, io, manifest);
}

/// Locked one-shot read. Null when the manifest is missing or corrupt.
pub fn readManifest(allocator: Allocator, io: Io, path: []const u8) !?Parsed {
    var locked = try Locked.open(io, path);
    defer locked.close(io);
    return locked.read(allocator, io);
}

/// Outcome of a daemon frame-loop manifest read.
pub const TickRead = union(enum) {
    /// The manifest file is gone — the daemon's stop signal.
    gone,
    /// Present but empty/corrupt/unreadable this tick: skip and keep looping.
    invalid,
    ok: Parsed,
};

/// Daemon-side locked read that NEVER creates the file. `Locked.open` (used by
/// the statusline) creates the manifest if missing, which would resurrect a
/// removed manifest and defeat the "manifest gone ⇒ exit" stop; this opens
/// existing-only so a removal is observed as `.gone`. Takes the same exclusive
/// lock as the statusline's write, then releases it on return (the caller sleeps
/// without holding it). Allocation failure is the only error.
pub fn readManifestTick(allocator: Allocator, io: Io, path: []const u8) Allocator.Error!TickRead {
    const file = Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only, .lock = .exclusive }) catch |e| switch (e) {
        error.FileNotFound => return .gone,
        else => return .invalid,
    };
    defer file.close(io);

    const st = file.stat(io) catch return .invalid;
    const buf = try allocator.alloc(u8, @intCast(st.size));
    defer allocator.free(buf);
    const n = file.readPositionalAll(io, buf, 0) catch return .invalid;
    if (try parse(allocator, buf[0..n])) |p| return .{ .ok = p };
    return .invalid;
}

/// Bump the heartbeat file's mtime, creating it (and its parent dir) if needed.
/// The statusline calls this on EVERY invocation, including the state-hit path.
pub fn touchHeartbeat(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        Io.Dir.cwd().createDirPath(io, parent) catch {};
    }
    const file = try Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "1\n");
}

/// Age of the heartbeat in nanoseconds at `now_ns` (epoch). Null when the file
/// is missing or unreadable — the caller treats null as maximally stale.
pub fn heartbeatAgeNs(io: Io, path: []const u8, now_ns: i96) ?i96 {
    const file = Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const st = file.stat(io) catch return null;
    return now_ns - st.mtime.nanoseconds;
}

const test_tty = "/dev/ttys011";

fn sampleManifest() Manifest {
    return .{
        .image_id = 103,
        .gap_ms = 125,
        .max_fps = 24,
        .daemon_ttl_ms = 7000,
        .tmux = true,
        .tty_path = test_tty,
        .frames = &.{ "/abs/face1/0.png", "/abs/face1/1.png", "/abs/face1/2.png" },
        .frame_sig = 0xdeadbeefcafe1234,
    };
}

fn expectManifestEqual(expected: Manifest, actual: Manifest) !void {
    try std.testing.expectEqual(expected.image_id, actual.image_id);
    try std.testing.expectEqual(expected.gap_ms, actual.gap_ms);
    try std.testing.expectEqual(expected.max_fps, actual.max_fps);
    try std.testing.expectEqual(expected.daemon_ttl_ms, actual.daemon_ttl_ms);
    try std.testing.expectEqual(expected.tmux, actual.tmux);
    try std.testing.expectEqual(expected.frame_sig, actual.frame_sig);
    try std.testing.expectEqualStrings(expected.tty_path, actual.tty_path);
    try std.testing.expectEqual(expected.frames.len, actual.frames.len);
    for (expected.frames, actual.frames) |e, a| try std.testing.expectEqualStrings(e, a);
}

test "serialize/parse round trip preserves all fields and frame order" {
    const a = std.testing.allocator;
    const m = sampleManifest();
    const bytes = try serialize(a, m);
    defer a.free(bytes);

    var parsed = (try parse(a, bytes)).?;
    defer parsed.deinit();
    try expectManifestEqual(m, parsed.value);
}

test "parse yields null for missing, corrupt, or partial input" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(?Parsed, null), try parse(a, ""));
    try std.testing.expectEqual(@as(?Parsed, null), try parse(a, "total garbage\x00\xff\n"));
    // Missing frame_sig.
    try std.testing.expectEqual(@as(?Parsed, null), try parse(a, "image_id = 103\ngap_ms = 125\ntmux = 1\ntty = /dev/tty\nframe = /a/0.png\n"));
    // No frames.
    try std.testing.expectEqual(@as(?Parsed, null), try parse(a, "image_id = 103\ngap_ms = 125\ntmux = 1\ntty = /dev/tty\nframe_sig = ff\n"));
    // Unparsable int.
    try std.testing.expectEqual(@as(?Parsed, null), try parse(a, "image_id = nope\ngap_ms = 125\ntmux = 1\ntty = /dev/tty\nframe_sig = ff\nframe = /a/0.png\n"));
    // Non-boolean tmux.
    try std.testing.expectEqual(@as(?Parsed, null), try parse(a, "image_id = 103\ngap_ms = 125\ntmux = yes\ntty = /dev/tty\nframe_sig = ff\nframe = /a/0.png\n"));
}

test "parse defaults max_fps when the field is absent (backward compat)" {
    const a = std.testing.allocator;
    var parsed = (try parse(a, "image_id = 103\ngap_ms = 125\ntmux = 0\ntty = /dev/tty\nframe_sig = ff\nframe = /a/0.png\n")).?;
    defer parsed.deinit();
    try std.testing.expectEqual(default_max_fps, parsed.value.max_fps);
}

test "parse defaults daemon_ttl_ms when the field is absent (backward compat)" {
    const a = std.testing.allocator;
    var parsed = (try parse(a, "image_id = 103\ngap_ms = 125\nmax_fps = 30\ntmux = 0\ntty = /dev/tty\nframe_sig = ff\nframe = /a/0.png\n")).?;
    defer parsed.deinit();
    try std.testing.expectEqual(default_daemon_ttl_ms, parsed.value.daemon_ttl_ms);
}

test "parse reads an explicit daemon_ttl_ms" {
    const a = std.testing.allocator;
    var parsed = (try parse(a, "image_id = 103\ngap_ms = 125\ndaemon_ttl_ms = 500\ntmux = 0\ntty = /dev/tty\nframe_sig = ff\nframe = /a/0.png\n")).?;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 500), parsed.value.daemon_ttl_ms);
}

test "parse rejects non-absolute tty and frame paths" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(?Parsed, null), try parse(a, "image_id = 103\ngap_ms = 125\ntmux = 0\ntty = dev/tty\nframe_sig = ff\nframe = /a/0.png\n"));
    try std.testing.expectEqual(@as(?Parsed, null), try parse(a, "image_id = 103\ngap_ms = 125\ntmux = 0\ntty = /dev/tty\nframe_sig = ff\nframe = face1/0.png\n"));
}

test "parse tolerates blank lines and stray whitespace" {
    const a = std.testing.allocator;
    const m = sampleManifest();
    const bytes = try serialize(a, m);
    defer a.free(bytes);
    const padded = try std.fmt.allocPrint(a, "\n  {s}\n\n", .{bytes});
    defer a.free(padded);

    var parsed = (try parse(a, padded)).?;
    defer parsed.deinit();
    try expectManifestEqual(m, parsed.value);
}

test "signatureChanged detects a differing signature" {
    const before: []const state.FrameStat = &.{
        .{ .size = 100, .mtime = 1111 },
        .{ .size = 200, .mtime = 2222 },
    };
    const after: []const state.FrameStat = &.{
        .{ .size = 100, .mtime = 9999 },
        .{ .size = 200, .mtime = 2222 },
    };
    const stored = state.frameSignature(before);
    try std.testing.expect(!signatureChanged(stored, state.frameSignature(before)));
    try std.testing.expect(signatureChanged(stored, state.frameSignature(after)));
}

test "manifestPath and heartbeatPath sit alongside state-<key>" {
    const a = std.testing.allocator;
    const mp = try manifestPath(a, "/xdg-state", "/home/me", 0xabc);
    defer a.free(mp);
    try std.testing.expectEqualStrings("/xdg-state/statusline-sprite/anim-0000000000000abc", mp);

    const hp = try heartbeatPath(a, null, "/home/me", 0xabc);
    defer a.free(hp);
    try std.testing.expectEqualStrings("/home/me/.local/state/statusline-sprite/heartbeat-0000000000000abc", hp);

    try std.testing.expectError(error.NoStateDir, manifestPath(a, null, null, 1));
}

test "daemonLockPath sits alongside anim-<key> with a .lock suffix" {
    const a = std.testing.allocator;
    const lp = try daemonLockPath(a, "/xdg-state", "/home/me", 0xabc);
    defer a.free(lp);
    try std.testing.expectEqualStrings("/xdg-state/statusline-sprite/daemon-0000000000000abc.lock", lp);

    const lp2 = try daemonLockPath(a, null, "/home/me", 0xabc);
    defer a.free(lp2);
    try std.testing.expectEqualStrings("/home/me/.local/state/statusline-sprite/daemon-0000000000000abc.lock", lp2);

    try std.testing.expectError(error.NoStateDir, daemonLockPath(a, null, null, 1));
}

test "daemonLockPathFromManifest agrees byte-for-byte with daemonLockPath" {
    const a = std.testing.allocator;
    const mp = try manifestPath(a, "/xdg-state", "/home/me", 0xabc);
    defer a.free(mp);

    const from_manifest = try daemonLockPathFromManifest(a, mp);
    defer a.free(from_manifest);
    const from_key = try daemonLockPath(a, "/xdg-state", "/home/me", 0xabc);
    defer a.free(from_key);

    try std.testing.expectEqualStrings(from_key, from_manifest);
}

test "daemonLockPathFromManifest rejects a non-anim path" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.BadManifestPath, daemonLockPathFromManifest(a, "/tmp/state-0000000000000abc"));
    try std.testing.expectError(error.BadManifestPath, daemonLockPathFromManifest(a, "anim-abc"));
}

test "heartbeatPathFromManifest agrees byte-for-byte with heartbeatPath" {
    const a = std.testing.allocator;
    const mp = try manifestPath(a, "/xdg-state", "/home/me", 0xabc);
    defer a.free(mp);

    const from_manifest = try heartbeatPathFromManifest(a, mp);
    defer a.free(from_manifest);
    const from_key = try heartbeatPath(a, "/xdg-state", "/home/me", 0xabc);
    defer a.free(from_key);

    try std.testing.expectEqualStrings(from_key, from_manifest);
}

test "statePathFromManifest sits alongside anim-<key> as state-<key>" {
    const a = std.testing.allocator;
    const mp = try manifestPath(a, "/xdg-state", "/home/me", 0xabc);
    defer a.free(mp);

    const sp = try statePathFromManifest(a, mp);
    defer a.free(sp);
    try std.testing.expectEqualStrings("/xdg-state/statusline-sprite/state-0000000000000abc", sp);
}

test "heartbeatPathFromManifest and statePathFromManifest reject a non-anim path" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.BadManifestPath, heartbeatPathFromManifest(a, "/tmp/state-abc"));
    try std.testing.expectError(error.BadManifestPath, statePathFromManifest(a, "/tmp/daemon-abc.lock"));
}

test "Locked: write then read round-trips through the state dir" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/statusline-sprite/anim-abc", .{dir});
    defer a.free(path);

    const abs_frames = try std.fmt.allocPrint(a, "{s}/face1/0.png", .{dir});
    defer a.free(abs_frames);
    const abs_tty = try std.fmt.allocPrint(a, "{s}/tty", .{dir});
    defer a.free(abs_tty);
    const m: Manifest = .{
        .image_id = 104,
        .gap_ms = 63,
        .max_fps = 30,
        .daemon_ttl_ms = 2500,
        .tmux = false,
        .tty_path = abs_tty,
        .frames = &.{abs_frames},
        .frame_sig = 0xfeed,
    };

    try writeManifest(a, io, path, m);

    var parsed = (try readManifest(a, io, path)).?;
    defer parsed.deinit();
    try expectManifestEqual(m, parsed.value);
}

test "readManifest returns null for a corrupt file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "anim-abc", .data = "not a manifest\n" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/anim-abc", .{dir});
    defer a.free(path);

    const parsed = try readManifest(a, io, path);
    try std.testing.expectEqual(@as(?Parsed, null), parsed);
}

test "readManifest returns null when the file is missing (empty on create)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/anim-missing", .{dir});
    defer a.free(path);

    const parsed = try readManifest(a, io, path);
    try std.testing.expectEqual(@as(?Parsed, null), parsed);
}

test "heartbeat: touch then read staleness; missing reads as maximally stale" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/statusline-sprite/heartbeat-abc", .{dir});
    defer a.free(path);

    // Missing heartbeat: null (maximally stale).
    try std.testing.expectEqual(@as(?i96, null), heartbeatAgeNs(io, path, 1_000));

    try touchHeartbeat(io, path);

    // Present: age tracks the passed-in clock linearly.
    const age_now = heartbeatAgeNs(io, path, Io.Timestamp.now(io, .real).nanoseconds);
    try std.testing.expect(age_now != null);

    const a1 = heartbeatAgeNs(io, path, 5_000_000_000).?;
    const a2 = heartbeatAgeNs(io, path, 6_000_000_000).?;
    try std.testing.expectEqual(@as(i96, 1_000_000_000), a2 - a1);
}

test "Locked: second opener cannot take the lock" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/anim-abc", .{dir});
    defer a.free(path);

    var locked = try Locked.open(io, path);
    defer locked.close(io);

    const other = try Io.Dir.openFileAbsolute(io, path, .{});
    defer other.close(io);
    try std.testing.expect(!try other.tryLock(io, .exclusive));
}
