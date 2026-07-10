const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// What was last transmitted to a graphics target. A terminal restart leaves
/// stale state behind (the image store is gone but the file still says
/// "transmitted") and nothing observable on the tty distinguishes that from a
/// live placement, so staleness is bounded by a TTL on the state file's age
/// instead: worst case is one visible retransmit (and animation-loop restart)
/// per `ttl_ns` — see `isExpired`.
pub const State = struct {
    tier: u32,
    image_id: u32,
    fps: u32,
    frame_sig: u64,
};

/// How long a recorded transmit stays trusted. On a hit the file is left
/// untouched, so its mtime marks the LAST TRANSMIT — the TTL fires ~10 min
/// after that, not 10 min after the last refresh.
pub const ttl_ns: i96 = 10 * std.time.ns_per_min;

/// Whether a state file with mtime `file_mtime_ns` is too old to trust at
/// `now_ns` (both epoch nanoseconds). Pure — callers pass the clock reading in.
/// Zero and negative ages (mtime in the future, clock skew) count as fresh.
pub fn isExpired(file_mtime_ns: i96, now_ns: i96) bool {
    return now_ns - file_mtime_ns > ttl_ns;
}

pub const FrameStat = struct { size: u64, mtime: i96 };

/// Length-prefix each field and tag presence so "ab"+"c" vs "a"+"bc" and
/// absent vs empty can never collide.
fn hashField(hasher: *std.hash.XxHash64, field: ?[]const u8) void {
    if (field) |f| {
        hasher.update(&[_]u8{1});
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, f.len, .little);
        hasher.update(&len);
        hasher.update(f);
    } else {
        hasher.update(&[_]u8{0});
    }
}

pub fn stateKey(
    tty_path: []const u8,
    kitty_window_id: ?[]const u8,
    tmux_pane: ?[]const u8,
) u64 {
    var hasher = std.hash.XxHash64.init(0);
    hashField(&hasher, tty_path);
    hashField(&hasher, kitty_window_id);
    hashField(&hasher, tmux_pane);
    return hasher.final();
}

/// Pure path resolver: `$XDG_STATE_HOME/statusline-sprite/state-<key hex>`
/// when `xdg_state_home` is set, else `$HOME/.local/state/...`. Kept free of
/// real-environment reads so it can be unit-tested deterministically. Caller
/// owns the returned slice.
pub fn resolveStatePath(
    allocator: Allocator,
    xdg_state_home: ?[]const u8,
    home: ?[]const u8,
    key: u64,
) ![]u8 {
    if (xdg_state_home) |xdg| {
        if (xdg.len != 0)
            return std.fmt.allocPrint(allocator, "{s}/statusline-sprite/state-{x:0>16}", .{ xdg, key });
    }
    if (home) |h| {
        if (h.len != 0)
            return std.fmt.allocPrint(allocator, "{s}/.local/state/statusline-sprite/state-{x:0>16}", .{ h, key });
    }
    return error.NoStateDir;
}

pub fn frameSignature(stats: []const FrameStat) u64 {
    var hasher = std.hash.XxHash64.init(0);
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, stats.len, .little);
    hasher.update(&buf);
    for (stats) |s| {
        std.mem.writeInt(u64, &buf, s.size, .little);
        hasher.update(&buf);
        var mbuf: [12]u8 = undefined;
        std.mem.writeInt(i96, &mbuf, s.mtime, .little);
        hasher.update(&mbuf);
    }
    return hasher.final();
}

/// Tolerant: any missing, duplicate-free-but-unparsable, or garbled field
/// yields null ("no valid state") so the caller re-transmits. Never an error.
pub fn parse(bytes: []const u8) ?State {
    var tier: ?u32 = null;
    var image_id: ?u32 = null;
    var fps: ?u32 = null;
    var frame_sig: ?u64 = null;

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "tier")) {
            tier = std.fmt.parseInt(u32, rhs, 10) catch return null;
        } else if (std.mem.eql(u8, key, "image_id")) {
            image_id = std.fmt.parseInt(u32, rhs, 10) catch return null;
        } else if (std.mem.eql(u8, key, "fps")) {
            fps = std.fmt.parseInt(u32, rhs, 10) catch return null;
        } else if (std.mem.eql(u8, key, "frame_sig")) {
            frame_sig = std.fmt.parseInt(u64, rhs, 16) catch return null;
        }
        // Unknown keys are ignored, mirroring the config reader.
    }

    return .{
        .tier = tier orelse return null,
        .image_id = image_id orelse return null,
        .fps = fps orelse return null,
        .frame_sig = frame_sig orelse return null,
    };
}

/// Caller owns the returned slice.
pub fn serialize(allocator: Allocator, state: State) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "tier = {d}\nimage_id = {d}\nfps = {d}\nframe_sig = {x}\n",
        .{ state.tier, state.image_id, state.fps, state.frame_sig },
    );
}

pub fn matches(recorded: ?State, current: State) bool {
    const r = recorded orelse return false;
    return std.meta.eql(r, current);
}

/// State file held under an exclusive advisory lock for the whole
/// read -> decide -> tty-write -> commit critical section, serializing
/// concurrent statusline instances. Lock releases on close/process death.
pub const Locked = struct {
    file: Io.File,
    state: ?State,
    /// The state file's mtime (epoch ns) at open — i.e. when the recorded
    /// transmit last happened. Feed to `isExpired` together with `state`.
    mtime_ns: i96,

    pub fn open(io: Io, path: []const u8) !Locked {
        // Best-effort: the state directory may not exist on first run; a
        // creation failure surfaces as the createFileAbsolute error instead.
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
        var buf: [4096]u8 = undefined;
        const n = try file.readPositionalAll(io, &buf, 0);
        return .{ .file = file, .state = parse(buf[0..n]), .mtime_ns = st.mtime.nanoseconds };
    }

    pub fn commit(self: *Locked, allocator: Allocator, io: Io) !void {
        const state = self.state orelse return;
        const bytes = try serialize(allocator, state);
        defer allocator.free(bytes);
        try self.file.writePositionalAll(io, bytes, 0);
        try self.file.setLength(io, bytes.len);
    }

    pub fn close(self: *Locked, io: Io) void {
        self.file.close(io);
    }
};

test "stateKey is stable for identical inputs" {
    const a = stateKey("/dev/ttys011", "3", "%1");
    const b = stateKey("/dev/ttys011", "3", "%1");
    try std.testing.expectEqual(a, b);

    try std.testing.expectEqual(
        stateKey("/dev/ttys011", null, null),
        stateKey("/dev/ttys011", null, null),
    );
}

test "stateKey distinguishes panes, window ids, and tty paths" {
    const base = stateKey("/dev/ttys011", "3", "%1");
    try std.testing.expect(base != stateKey("/dev/ttys011", "3", "%2"));
    try std.testing.expect(base != stateKey("/dev/ttys011", "4", "%1"));
    try std.testing.expect(base != stateKey("/dev/ttys012", "3", "%1"));
}

test "stateKey distinguishes absent from empty fields" {
    try std.testing.expect(stateKey("/dev/tty", null, null) != stateKey("/dev/tty", "", null));
    try std.testing.expect(stateKey("/dev/tty", null, null) != stateKey("/dev/tty", null, ""));
    try std.testing.expect(stateKey("/dev/tty", "", null) != stateKey("/dev/tty", null, ""));
}

test "stateKey has no concatenation-boundary collisions" {
    // "ab"+"c" vs "a"+"bc" across adjacent fields.
    try std.testing.expect(stateKey("/dev/tty", "ab", "c") != stateKey("/dev/tty", "a", "bc"));
    try std.testing.expect(stateKey("/dev/ttyX", "Y", null) != stateKey("/dev/tty", "XY", null));
}

test "resolveStatePath honours XDG_STATE_HOME when set" {
    const path = try resolveStatePath(std.testing.allocator, "/xdg-state", "/home/me", 0xabc);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/xdg-state/statusline-sprite/state-0000000000000abc", path);
}

test "resolveStatePath falls back to HOME/.local/state" {
    const path = try resolveStatePath(std.testing.allocator, null, "/home/me", 0xabc);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/me/.local/state/statusline-sprite/state-0000000000000abc", path);

    const path2 = try resolveStatePath(std.testing.allocator, "", "/home/me", 0xabc);
    defer std.testing.allocator.free(path2);
    try std.testing.expectEqualStrings("/home/me/.local/state/statusline-sprite/state-0000000000000abc", path2);
}

test "resolveStatePath errors when no home is available" {
    try std.testing.expectError(error.NoStateDir, resolveStatePath(std.testing.allocator, null, null, 1));
}

test "frameSignature is stable for identical stat lists" {
    const stats: []const FrameStat = &.{
        .{ .size = 100, .mtime = 1111 },
        .{ .size = 200, .mtime = 2222 },
    };
    try std.testing.expectEqual(frameSignature(stats), frameSignature(stats));
}

test "frameSignature changes on mtime, size, count, or order" {
    const base: []const FrameStat = &.{
        .{ .size = 100, .mtime = 1111 },
        .{ .size = 200, .mtime = 2222 },
    };
    const sig = frameSignature(base);

    try std.testing.expect(sig != frameSignature(&.{
        .{ .size = 100, .mtime = 9999 },
        .{ .size = 200, .mtime = 2222 },
    }));
    try std.testing.expect(sig != frameSignature(&.{
        .{ .size = 101, .mtime = 1111 },
        .{ .size = 200, .mtime = 2222 },
    }));
    try std.testing.expect(sig != frameSignature(&.{
        .{ .size = 100, .mtime = 1111 },
    }));
    try std.testing.expect(sig != frameSignature(&.{
        .{ .size = 200, .mtime = 2222 },
        .{ .size = 100, .mtime = 1111 },
    }));
    try std.testing.expect(frameSignature(&.{}) != frameSignature(base));
}

test "isExpired: fresh under the TTL, expired past it, tolerant of skew" {
    const mtime: i96 = 1_700_000_000_000_000_000;
    try std.testing.expect(!isExpired(mtime, mtime)); // zero age
    try std.testing.expect(!isExpired(mtime, mtime + ttl_ns - 1)); // just under
    try std.testing.expect(!isExpired(mtime, mtime + ttl_ns)); // exactly at
    try std.testing.expect(isExpired(mtime, mtime + ttl_ns + 1)); // just over
    try std.testing.expect(!isExpired(mtime, mtime - 1)); // negative age (skew)
}

test "serialize/parse round trip matches" {
    const s: State = .{
        .tier = 3,
        .image_id = 103,
        .fps = 8,
        .frame_sig = 0xdeadbeefcafe1234,
    };
    const bytes = try serialize(std.testing.allocator, s);
    defer std.testing.allocator.free(bytes);

    const back = parse(bytes);
    try std.testing.expect(back != null);
    try std.testing.expect(matches(back, s));
}

test "matches is false when any field differs" {
    const s: State = .{ .tier = 1, .image_id = 101, .fps = 8, .frame_sig = 0xff };

    try std.testing.expect(matches(s, s));

    var m = s;
    m.tier = 2;
    try std.testing.expect(!matches(m, s));
    m = s;
    m.image_id = 102;
    try std.testing.expect(!matches(m, s));
    m = s;
    m.fps = 12;
    try std.testing.expect(!matches(m, s));
    m = s;
    m.frame_sig = 0xfe;
    try std.testing.expect(!matches(m, s));
}

test "matches is false with no recorded state" {
    const s: State = .{ .tier = 1, .image_id = 101, .fps = 8, .frame_sig = 0xff };
    try std.testing.expect(!matches(null, s));
}

test "parse tolerates missing, corrupt, or partial input" {
    try std.testing.expectEqual(@as(?State, null), parse(""));
    try std.testing.expectEqual(@as(?State, null), parse("total garbage\x00\xff\n"));
    try std.testing.expectEqual(@as(?State, null), parse("tier = 1\nimage_id = 101\n"));
    try std.testing.expectEqual(@as(?State, null), parse("tier = notanumber\nimage_id = 101\nfps = 8\nframe_sig = ff\n"));
}

test "parse tolerates blank lines and stray whitespace" {
    const s: State = .{ .tier = 1, .image_id = 101, .fps = 8, .frame_sig = 0xff };
    const bytes = try serialize(std.testing.allocator, s);
    defer std.testing.allocator.free(bytes);

    const padded = try std.fmt.allocPrint(std.testing.allocator, "\n  {s}\n\n", .{bytes});
    defer std.testing.allocator.free(padded);

    try std.testing.expect(matches(parse(padded), s));
}

test "Locked: missing file opens with no state, commit round-trips" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/state-abc", .{dir});
    defer a.free(path);

    var locked = try Locked.open(io, path);
    try std.testing.expectEqual(@as(?State, null), locked.state);
    locked.state = .{ .tier = 2, .image_id = 102, .fps = 10, .frame_sig = 0xfeed };
    try locked.commit(a, io);
    locked.close(io);

    var reopened = try Locked.open(io, path);
    defer reopened.close(io);
    try std.testing.expect(matches(reopened.state, .{ .tier = 2, .image_id = 102, .fps = 10, .frame_sig = 0xfeed }));
    // The recorded mtime is a plausible epoch timestamp, usable with isExpired.
    try std.testing.expect(reopened.mtime_ns > 0);
    try std.testing.expect(!isExpired(reopened.mtime_ns, reopened.mtime_ns + 1));
}

test "Locked: open creates missing parent directories" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/statusline-sprite/state-abc", .{dir});
    defer a.free(path);

    var locked = try Locked.open(io, path);
    defer locked.close(io);
    try std.testing.expectEqual(@as(?State, null), locked.state);
}

test "Locked: corrupt file opens with no state" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "state-abc", .data = "not a state file\n" });

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/state-abc", .{dir});
    defer a.free(path);

    var locked = try Locked.open(io, path);
    defer locked.close(io);
    try std.testing.expectEqual(@as(?State, null), locked.state);
}

test "Locked: commit shrinks a previously longer file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const long = "x" ** 512 ++ "\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "state-abc", .data = long });

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/state-abc", .{dir});
    defer a.free(path);

    {
        var locked = try Locked.open(io, path);
        defer locked.close(io);
        locked.state = .{ .tier = 1, .image_id = 101, .fps = 8, .frame_sig = 1 };
        try locked.commit(a, io);
    }

    var reopened = try Locked.open(io, path);
    defer reopened.close(io);
    try std.testing.expect(matches(reopened.state, .{ .tier = 1, .image_id = 101, .fps = 8, .frame_sig = 1 }));
}

test "Locked: second opener cannot take the lock" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fmt.allocPrint(a, "{s}/state-abc", .{dir});
    defer a.free(path);

    var locked = try Locked.open(io, path);
    defer locked.close(io);

    // Advisory flock conflicts across separate fds even within one process.
    const other = try Io.Dir.openFileAbsolute(io, path, .{});
    defer other.close(io);
    try std.testing.expect(!try other.tryLock(io, .exclusive));
}
