const std = @import("std");
const anim = @import("anim.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

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

/// Daemon entrypoint (`--animate <manifest>`). Singleton via the daemon lock
/// (loser exits), then `setsid` for a fresh session, then a minimal alive-loop.
///
/// T1 scope: the loop only keeps the process observably resident and exits when
/// the manifest disappears (the tests' deterministic stop). It transmits no
/// frames and enforces no TTL.
/// TODO(T3): replace the alive-loop with lock→read→bare-`a=t`→unlock→sleep.
/// TODO(T5): heartbeat-TTL exit, tty-write-failure exit.
pub fn run(gpa: Allocator, io: Io, manifest_path: []const u8) void {
    const lock_path = anim.daemonLockPathFromManifest(gpa, manifest_path) catch return;
    defer gpa.free(lock_path);

    const maybe_lock = acquireLock(io, lock_path) catch return;
    var lock = maybe_lock orelse return; // another daemon owns this target
    defer lock.close(io);

    // A fresh exec is never a process-group leader, so this succeeds and
    // detaches the daemon into its own session. libc-only (see build.zig).
    _ = std.c.setsid();

    while (true) {
        io.sleep(.fromMilliseconds(200), .awake) catch {};
        Io.Dir.accessAbsolute(io, manifest_path, .{}) catch return;
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
