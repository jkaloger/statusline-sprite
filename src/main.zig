const std = @import("std");
const config = @import("config.zig");
const statusline = @import("statusline.zig");
const tier = @import("tier.zig");
const kitty = @import("kitty.zig");
const rows = @import("rows.zig");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const environ = init.minimal.environ;

    const stdin_bytes = readStdin(gpa, io) catch &.{};
    defer gpa.free(stdin_bytes);

    const parsed: ?statusline.ParsedStatusline = statusline.parse(gpa, stdin_bytes) catch null;
    defer if (parsed) |p| p.deinit();
    const sl: statusline.Statusline = if (parsed) |p| p.value else .{
        .model_display_name = "",
        .total_input_tokens = 0,
        .used_percentage = null,
        .context_window_size = null,
    };

    var cfg = config.load(gpa, io, environ) catch config.defaults();
    defer cfg.deinit();

    const tokens = tier.tokensFrom(sl);
    const tier_idx = tier.selectTier(tokens, cfg.sprite.scale_tokens, cfg.sprite.tiers);
    const image_id: u32 = 1000 + tier_idx;

    const png_bytes = readFace(gpa, io, cfg, tier_idx);
    defer if (png_bytes) |b| gpa.free(b);

    const caps = detectCaps(environ);

    // Best-effort graphics. `grid` backs the sprite-row slices, so it must
    // outlive the assembleRows call below.
    var grid: ?[]u8 = null;
    defer if (grid) |g| gpa.free(g);
    var sprite_arr: [3][]const u8 = undefined;
    var have_sprite = false;

    // tmux masks the host terminal's identity (TERM=tmux-256color, no
    // KITTY_WINDOW_ID), so capability can't be sniffed through it. Attempt
    // graphics anyway when inside tmux -- the escapes are passthrough-wrapped
    // and a non-graphics host simply drops them (best-effort, matches proto).
    const can_graphics = caps.kitty_capable or caps.tmux;
    if (can_graphics and png_bytes != null and cfg.sprite.box_rows == 3) {
        if (tryGraphics(gpa, io, caps, image_id, png_bytes.?, cfg.sprite.box_rows, cfg.sprite.box_cols)) {
            if (kitty.placeholderGrid(gpa, image_id, cfg.sprite.box_rows, cfg.sprite.box_cols) catch null) |g| {
                grid = g;
                var count: usize = 0;
                var it = std.mem.splitScalar(u8, g, '\n');
                while (it.next()) |line| : (count += 1) {
                    if (count < 3) sprite_arr[count] = line;
                }
                if (count == 3) have_sprite = true;
            }
        }
    }

    const l1 = if (cfg.line1.command) |c| rows.runCommand(gpa, io, c, 1000) else try gpa.dupe(u8, "");
    defer gpa.free(l1);
    const l3 = if (cfg.line3.command) |c| rows.runCommand(gpa, io, c, 1000) else try gpa.dupe(u8, "");
    defer gpa.free(l3);
    const text_lines: [3][]const u8 = .{ l1, sl.model_display_name, l3 };

    const sprite_rows: ?[]const []const u8 = if (have_sprite) sprite_arr[0..] else null;
    const block = try rows.assembleRows(gpa, sprite_rows, text_lines, "  ");
    defer gpa.free(block);

    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, block);
    try stdout.writeStreamingAll(io, "\n");
}

fn readStdin(gpa: std.mem.Allocator, io: Io) ![]u8 {
    var buf: [4096]u8 = undefined;
    var fr = std.Io.File.stdin().readerStreaming(io, &buf);
    return fr.interface.allocRemaining(gpa, .limited(1 << 20));
}

/// Resolve and read the tier's face PNG. Any failure yields null (no sprite).
fn readFace(gpa: std.mem.Allocator, io: Io, cfg: config.Config, tier_idx: u32) ?[]u8 {
    var derived: ?[][]u8 = null;
    defer if (derived) |d| config.freeFaces(gpa, d);

    const face_path: []const u8 = blk: {
        if (cfg.sprite.faces) |faces| {
            if (faces.len == 0) return null;
            break :blk faces[@min(@as(usize, tier_idx), faces.len - 1)];
        }
        const d = config.deriveFaces(gpa, cfg.sprite.dir, cfg.sprite.tiers) catch return null;
        derived = d;
        if (d.len == 0) return null;
        break :blk d[@min(@as(usize, tier_idx), d.len - 1)];
    };

    return std.Io.Dir.cwd().readFileAlloc(io, face_path, gpa, .limited(1 << 20)) catch null;
}

const Caps = struct {
    tmux: bool,
    kitty_capable: bool,
};

fn detectCaps(environ: std.process.Environ) Caps {
    const term = environ.getPosix("TERM");
    const term_program = environ.getPosix("TERM_PROGRAM");
    const tmux_env = environ.getPosix("TMUX");
    const kitty_win = environ.getPosix("KITTY_WINDOW_ID");

    const is_tmux = (tmux_env != null and tmux_env.?.len > 0) or
        (term != null and (std.mem.startsWith(u8, term.?, "tmux") or
            std.mem.startsWith(u8, term.?, "screen")));

    var capable = kitty_win != null and kitty_win.?.len > 0;
    if (term) |t| {
        if (std.mem.indexOf(u8, t, "kitty") != null) capable = true;
        if (std.mem.indexOf(u8, t, "ghostty") != null) capable = true;
        if (std.mem.indexOf(u8, t, "wezterm") != null) capable = true;
    }
    if (term_program) |tp| {
        if (std.ascii.indexOfIgnoreCase(tp, "wezterm") != null) capable = true;
    }

    return .{ .tmux = is_tmux, .kitty_capable = capable };
}

/// Open the graphics target and write delete/transmit/placement escapes.
/// Returns true only if everything succeeded; any failure degrades to no sprite.
fn tryGraphics(
    gpa: std.mem.Allocator,
    io: Io,
    caps: Caps,
    image_id: u32,
    png: []const u8,
    box_rows: u32,
    box_cols: u32,
) bool {
    var tty_path: []const u8 = "/dev/tty";
    var owned_path: ?[]u8 = null;
    defer if (owned_path) |p| gpa.free(p);

    if (caps.tmux) {
        const out = rows.runCommand(gpa, io, "tmux display -p '#{pane_tty}'", 1000);
        if (out.len == 0) {
            gpa.free(out);
            return false;
        }
        owned_path = out;
        tty_path = out;
    }

    const tty = std.Io.Dir.openFileAbsolute(io, tty_path, .{ .mode = .write_only }) catch return false;
    defer tty.close(io);

    buildAndWrite(gpa, io, tty, caps.tmux, image_id, png, box_rows, box_cols) catch return false;
    return true;
}

fn buildAndWrite(
    gpa: std.mem.Allocator,
    io: Io,
    tty: std.Io.File,
    tmux: bool,
    image_id: u32,
    png: []const u8,
    box_rows: u32,
    box_cols: u32,
) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);

    {
        const esc = try kitty.delete(gpa, image_id);
        defer gpa.free(esc);
        try appendMaybeTmux(gpa, &payload, tmux, esc);
    }
    {
        const esc = try kitty.transmit(gpa, image_id, png, .{});
        defer gpa.free(esc);
        try appendMaybeTmux(gpa, &payload, tmux, esc);
    }
    {
        const esc = try kitty.virtualPlacement(gpa, image_id, box_rows, box_cols);
        defer gpa.free(esc);
        try appendMaybeTmux(gpa, &payload, tmux, esc);
    }

    try tty.writeStreamingAll(io, payload.items);
}

fn appendMaybeTmux(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(u8),
    tmux: bool,
    esc: []const u8,
) !void {
    if (tmux) {
        const wrapped = try kitty.wrapTmux(gpa, esc);
        defer gpa.free(wrapped);
        try list.appendSlice(gpa, wrapped);
    } else {
        try list.appendSlice(gpa, esc);
    }
}

test {
    _ = @import("config.zig");
    _ = @import("statusline.zig");
    _ = @import("tier.zig");
    _ = @import("kitty.zig");
    _ = @import("rows.zig");
}
