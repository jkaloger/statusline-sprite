const std = @import("std");
const config = @import("config.zig");
const Allocator = std.mem.Allocator;

/// Resolve the ordered frame paths for a tier. Null means "no sprite".
/// Caller owns the result; free with `freeFrames`. Returns paths only —
/// reading the files is the caller's job.
pub fn resolveTierFrames(
    allocator: Allocator,
    io: std.Io,
    cfg: config.Config,
    tier_idx: u32,
) !?[][]u8 {
    var derived: ?[][]u8 = null;
    defer if (derived) |d| config.freeFaces(allocator, d);

    const base: []const u8 = blk: {
        if (cfg.sprite.faces) |faces| {
            if (faces.len == 0) return null;
            break :blk faces[@min(@as(usize, tier_idx), faces.len - 1)];
        }
        const d = try config.deriveFaces(allocator, cfg.sprite.dir, cfg.sprite.tiers);
        derived = d;
        if (d.len == 0) return null;
        break :blk d[@min(@as(usize, tier_idx), d.len - 1)];
    };

    // The frame-directory candidate is the tier path sans `.png`, so both the
    // derived `<dir>/faceN.png` and an explicit "faceN.png" faces entry map to
    // `faceN/`; an entry already naming a directory passes through unchanged.
    const dir_path = if (std.mem.endsWith(u8, base, ".png"))
        base[0 .. base.len - ".png".len]
    else
        base;

    // Directory wins over a sibling `.png` file (spec: adding frames shouldn't
    // require deleting the old single-frame PNG).
    if (isDirectory(io, dir_path)) {
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |p| allocator.free(p);
            list.deinit(allocator);
        }

        var n: u32 = 0;
        while (n < cfg.sprite.max_frames) : (n += 1) {
            const frame_path = try std.fmt.allocPrint(allocator, "{s}/{d}.png", .{ dir_path, n });
            std.Io.Dir.cwd().access(io, frame_path, .{}) catch {
                allocator.free(frame_path);
                break;
            };
            try list.append(allocator, frame_path);
        }

        if (list.items.len == 0) {
            list.deinit(allocator);
            return null;
        }
        return try list.toOwnedSlice(allocator);
    }

    std.Io.Dir.cwd().access(io, base, .{}) catch return null;
    const single = try allocator.alloc([]u8, 1);
    errdefer allocator.free(single);
    single[0] = try allocator.dupe(u8, base);
    return single;
}

fn isDirectory(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

pub fn freeFrames(allocator: Allocator, frames: [][]u8) void {
    for (frames) |f| allocator.free(f);
    allocator.free(frames);
}

fn tmpConfig(dir: []const u8) config.Config {
    var cfg = config.defaults();
    cfg.sprite.dir = dir;
    return cfg;
}

fn writeDummyPng(dir: std.Io.Dir, sub_path: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = "png" });
}

test "resolveTierFrames collects contiguous frames from a face directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var face_dir = try tmp.dir.createDirPathOpen(std.testing.io, "face1", .{});
    defer face_dir.close(std.testing.io);
    try writeDummyPng(face_dir, "0.png");
    try writeDummyPng(face_dir, "1.png");
    try writeDummyPng(face_dir, "2.png");

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const frames = (try resolveTierFrames(std.testing.allocator, std.testing.io, tmpConfig(root), 1)).?;
    defer freeFrames(std.testing.allocator, frames);

    try std.testing.expectEqual(@as(usize, 3), frames.len);
    for (frames, 0..) |frame, n| {
        const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/face1/{d}.png", .{ root, n });
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, frame);
    }
}

test "resolveTierFrames stops at the first missing frame index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var face_dir = try tmp.dir.createDirPathOpen(std.testing.io, "face1", .{});
    defer face_dir.close(std.testing.io);
    try writeDummyPng(face_dir, "0.png");
    try writeDummyPng(face_dir, "2.png");

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const frames = (try resolveTierFrames(std.testing.allocator, std.testing.io, tmpConfig(root), 1)).?;
    defer freeFrames(std.testing.allocator, frames);

    try std.testing.expectEqual(@as(usize, 1), frames.len);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/face1/0.png", .{root});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, frames[0]);
}

test "resolveTierFrames prefers the directory over a sibling png" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var face_dir = try tmp.dir.createDirPathOpen(std.testing.io, "face1", .{});
    defer face_dir.close(std.testing.io);
    try writeDummyPng(face_dir, "0.png");
    try writeDummyPng(face_dir, "1.png");
    try writeDummyPng(tmp.dir, "face1.png");

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const frames = (try resolveTierFrames(std.testing.allocator, std.testing.io, tmpConfig(root), 1)).?;
    defer freeFrames(std.testing.allocator, frames);

    try std.testing.expectEqual(@as(usize, 2), frames.len);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/face1/0.png", .{root});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, frames[0]);
}

test "resolveTierFrames falls back to the single png when no directory exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeDummyPng(tmp.dir, "face1.png");

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const frames = (try resolveTierFrames(std.testing.allocator, std.testing.io, tmpConfig(root), 1)).?;
    defer freeFrames(std.testing.allocator, frames);

    try std.testing.expectEqual(@as(usize, 1), frames.len);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/face1.png", .{root});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, frames[0]);
}

test "resolveTierFrames yields no sprite when neither directory nor png exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const frames = try resolveTierFrames(std.testing.allocator, std.testing.io, tmpConfig(root), 1);
    try std.testing.expectEqual(@as(?[][]u8, null), frames);
}

test "resolveTierFrames yields no sprite for an empty frame directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var face_dir = try tmp.dir.createDirPathOpen(std.testing.io, "face1", .{});
    defer face_dir.close(std.testing.io);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const frames = try resolveTierFrames(std.testing.allocator, std.testing.io, tmpConfig(root), 1);
    try std.testing.expectEqual(@as(?[][]u8, null), frames);
}

test "resolveTierFrames caps the frame count at max_frames" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var face_dir = try tmp.dir.createDirPathOpen(std.testing.io, "face1", .{});
    defer face_dir.close(std.testing.io);
    var n: u32 = 0;
    while (n < 5) : (n += 1) {
        const name = try std.fmt.allocPrint(std.testing.allocator, "{d}.png", .{n});
        defer std.testing.allocator.free(name);
        try writeDummyPng(face_dir, name);
    }

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var cfg = tmpConfig(root);
    cfg.sprite.max_frames = 3;

    const frames = (try resolveTierFrames(std.testing.allocator, std.testing.io, cfg, 1)).?;
    defer freeFrames(std.testing.allocator, frames);

    try std.testing.expectEqual(@as(usize, 3), frames.len);
}

test "resolveTierFrames resolves an explicit faces entry naming a directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var face_dir = try tmp.dir.createDirPathOpen(std.testing.io, "walkcycle", .{});
    defer face_dir.close(std.testing.io);
    try writeDummyPng(face_dir, "0.png");
    try writeDummyPng(face_dir, "1.png");

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const entry = try std.fmt.allocPrint(std.testing.allocator, "{s}/walkcycle", .{root});
    defer std.testing.allocator.free(entry);

    var cfg = config.defaults();
    cfg.sprite.faces = &.{entry};

    // Clamped index: tier 3 with a single faces entry still resolves entry 0.
    const frames = (try resolveTierFrames(std.testing.allocator, std.testing.io, cfg, 3)).?;
    defer freeFrames(std.testing.allocator, frames);

    try std.testing.expectEqual(@as(usize, 2), frames.len);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/walkcycle/1.png", .{root});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, frames[1]);
}
