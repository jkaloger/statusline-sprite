const std = @import("std");
const Io = std.Io;

/// Assemble the three-line text block, optionally prefixed by sprite cells.
///
/// With `sprite_rows == null` the block is just the text lines joined by '\n'.
/// Otherwise each line is `sprite_rows[i] ++ gap ++ text_lines[i]`, and
/// `sprite_rows` must have exactly three entries. No trailing newline.
pub fn assembleRows(
    allocator: std.mem.Allocator,
    sprite_rows: ?[]const []const u8,
    text_lines: [3][]const u8,
    gap: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (sprite_rows) |rows| {
        if (rows.len != 3) return error.SpriteRowCountMismatch;
        for (0..3) |i| {
            if (i > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, rows[i]);
            try out.appendSlice(allocator, gap);
            try out.appendSlice(allocator, text_lines[i]);
        }
    } else {
        for (0..3) |i| {
            if (i > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, text_lines[i]);
        }
    }

    return out.toOwnedSlice(allocator);
}

/// First non-blank line of `bytes` (trailing CR stripped). Leading blank lines
/// are skipped so multi-line prompt commands (e.g. `starship prompt`, which
/// leads with an empty line) still yield their content. Empty if all blank.
fn firstLine(bytes: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len > 0) return line;
    }
    return bytes[0..0];
}

/// Run `sh -c "<cmd>"`, capture stdout, enforce a wall-clock `timeout_ms`.
///
/// Returns an owned slice containing only the FIRST line of stdout (with any
/// trailing CR/LF stripped). Any failure -- spawn error, non-zero exit,
/// timeout, empty stdout -- yields an empty owned slice. Errors are NEVER
/// propagated: a broken prompt command must not break the statusline.
pub fn runCommand(
    allocator: std.mem.Allocator,
    io: Io,
    cmd: []const u8,
    timeout_ms: u64,
) []u8 {
    const empty: []u8 = &.{};

    const argv = [_][]const u8{ "sh", "-c", cmd };
    const timeout: Io.Timeout = .{ .duration = .{
        .raw = Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } };

    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .timeout = timeout.toDeadline(io),
    }) catch return empty;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return empty,
        else => return empty,
    }

    return allocator.dupe(u8, firstLine(result.stdout)) catch empty;
}

test "assembleRows: no sprite joins text lines with newlines, no trailing" {
    const a = std.testing.allocator;
    const out = try assembleRows(a, null, .{ "L1", "L2", "L3" }, "  ");
    defer a.free(out);
    try std.testing.expectEqualStrings("L1\nL2\nL3", out);
}

test "assembleRows: sprite prefix with gap per line" {
    const a = std.testing.allocator;
    const sprite = [_][]const u8{ "S0", "S1", "S2" };
    const out = try assembleRows(a, &sprite, .{ "a", "b", "c" }, "  ");
    defer a.free(out);
    try std.testing.expectEqualStrings("S0  a\nS1  b\nS2  c", out);
}

test "assembleRows: empty text line still yields its sprite-prefixed line" {
    const a = std.testing.allocator;
    const sprite = [_][]const u8{ "S0", "S1", "S2" };
    const out = try assembleRows(a, &sprite, .{ "a", "", "c" }, "|");
    defer a.free(out);
    try std.testing.expectEqualStrings("S0|a\nS1|\nS2|c", out);
}

test "assembleRows: wrong sprite row count errors" {
    const a = std.testing.allocator;
    const sprite = [_][]const u8{ "S0", "S1" };
    try std.testing.expectError(
        error.SpriteRowCountMismatch,
        assembleRows(a, &sprite, .{ "a", "b", "c" }, " "),
    );
}

test "runCommand: echo returns first line only" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hi = runCommand(a, io, "echo hi", 2000);
    defer a.free(hi);
    try std.testing.expectEqualStrings("hi", hi);

    const first = runCommand(a, io, "printf 'hi\\nsecond'", 2000);
    defer a.free(first);
    try std.testing.expectEqualStrings("hi", first);
}

test "runCommand: non-zero exit with no stdout yields empty" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const out = runCommand(a, io, "false", 2000);
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "runCommand: timeout kills child and returns empty promptly" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const start = Io.Clock.now(.awake, io);
    const out = runCommand(a, io, "sleep 1", 50);
    const elapsed_ms = start.durationTo(Io.Clock.now(.awake, io)).toMilliseconds();
    defer a.free(out);

    try std.testing.expectEqual(@as(usize, 0), out.len);
    // Must not have blocked for the full 1s sleep.
    try std.testing.expect(elapsed_ms < 800);
}
