const std = @import("std");
const config = @import("config.zig");
const statusline = @import("statusline.zig");
const tier = @import("tier.zig");
const kitty = @import("kitty.zig");
const rows = @import("rows.zig");
const frames = @import("frames.zig");
const state = @import("state.zig");
const anim = @import("anim.zig");
const daemon = @import("daemon.zig");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const environ = init.minimal.environ;

    switch (daemon.classify(collectArgv(init.arena.allocator(), init.minimal.args))) {
        .animate => |manifest_path| return daemon.run(gpa, io, manifest_path),
        .ensure => |manifest_path| return ensureDaemonMain(gpa, io, manifest_path),
        .normal => {},
    }

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
    // Base 100 keeps ids <= 255 so they fit a 256-color palette index; the
    // placeholder cell encodes the id via `38;5;<id>` (see kitty.placeholderGrid).
    const image_id: u32 = 100 + tier_idx;

    const fps = config.effectiveFps(cfg, tier_idx);
    const gap_ms = gapMs(fps);

    var loaded = loadFrames(gpa, io, cfg, tier_idx);
    defer if (loaded) |*l| l.deinit(gpa);

    const caps = detectCaps(environ);

    var dbg: std.ArrayList(u8) = .empty;
    defer dbg.deinit(gpa);
    dbg.print(gpa, "tmux={} kitty_capable={} tmux_pane={s} frames={?d} fps={d} gap_ms={d} box_cols={d}\n", .{
        caps.tmux,                      caps.kitty_capable,
        caps.tmux_pane orelse "(null)", if (loaded) |l| l.bytes.len else null,
        fps,                            gap_ms,
        cfg.sprite.box_cols,
    }) catch {};

    // Best-effort graphics. `grid` backs the sprite-row slices, so it must
    // outlive the assembleRows call below.
    var grid: ?[]u8 = null;
    defer if (grid) |g| gpa.free(g);
    var sprite_arr: [rows.line_count][]const u8 = undefined;
    var have_sprite = false;

    // tmux masks the host terminal's identity (TERM=tmux-256color, no
    // KITTY_WINDOW_ID), so capability can't be sniffed through it. Attempt
    // graphics anyway when inside tmux -- the escapes are passthrough-wrapped
    // and a non-graphics host simply drops them (best-effort, matches proto).
    const can_graphics = caps.kitty_capable or caps.tmux;
    dbg.print(gpa, "can_graphics={} image_id={d}\n", .{ can_graphics, image_id }) catch {};
    if (can_graphics and loaded != null) {
        const env_paths: StateEnv = .{
            .xdg_state_home = environ.getPosix("XDG_STATE_HOME"),
            .home = environ.getPosix("HOME"),
        };
        const animated = tierAnimated(loaded.?.bytes.len, fps, cfg.sprite.animate);
        dbg.print(gpa, "animated={} max_fps={d}\n", .{ animated, cfg.sprite.max_fps }) catch {};
        if (tryGraphics(gpa, io, caps, env_paths, tier_idx, image_id, fps, gap_ms, cfg.sprite.max_fps, animated, loaded.?, rows.line_count, cfg.sprite.box_cols, &dbg)) {
            if (kitty.placeholderGrid(gpa, image_id, rows.line_count, cfg.sprite.box_cols) catch null) |g| {
                grid = g;
                var count: usize = 0;
                var it = std.mem.splitScalar(u8, g, '\n');
                while (it.next()) |line| : (count += 1) {
                    if (count < rows.line_count) sprite_arr[count] = line;
                }
                if (count == rows.line_count) have_sprite = true;
            }
        }
    }
    dbg.print(gpa, "have_sprite={}\n", .{have_sprite}) catch {};

    const l1 = if (cfg.line1.command) |c| rows.runCommand(gpa, io, c, 1000) else try gpa.dupe(u8, "");
    defer gpa.free(l1);
    const l2 = if (cfg.line2.color) |c|
        try std.fmt.allocPrint(gpa, "\x1b[38;5;{d}m{s}\x1b[0m", .{ c, sl.model_display_name })
    else
        try gpa.dupe(u8, sl.model_display_name);
    defer gpa.free(l2);
    const l3 = if (cfg.line3.command) |c| rows.runCommand(gpa, io, c, 1000) else try gpa.dupe(u8, "");
    defer gpa.free(l3);
    const text_lines: [rows.line_count][]const u8 = .{ l1, l2, l3 };

    const sprite_rows: ?[]const []const u8 = if (have_sprite) sprite_arr[0..] else null;
    const block = try rows.assembleRows(gpa, sprite_rows, text_lines, "  ");
    defer gpa.free(block);

    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, block);
    try stdout.writeStreamingAll(io, "\n");

    if (environ.getPosix("SL_SPRITE_DEBUG")) |dbg_path| {
        if (std.Io.Dir.createFileAbsolute(io, dbg_path, .{})) |f| {
            var f_mut = f;
            defer f_mut.close(io);
            f_mut.writeStreamingAll(io, dbg.items) catch {};
        } else |_| {}
    }
}

/// Collect argv into a slice backed by `arena` (whole-process lifetime), so the
/// pure `daemon.classify` can scan it. On POSIX the arg bytes point into the OS
/// argv and outlive the process anyway.
fn collectArgv(arena: std.mem.Allocator, args: std.process.Args) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = args.iterate();
    while (it.next()) |arg| list.append(arena, arg) catch break;
    return list.toOwnedSlice(arena) catch &.{};
}

/// `--ensure-daemon <manifest>` handler: run the ensure-check once and print the
/// spawned daemon's pid (nothing if a daemon was already running). A hook for
/// the integration harness to exercise `ensureDaemon` from a real parent that
/// then exits, proving detachment.
fn ensureDaemonMain(gpa: std.mem.Allocator, io: Io, manifest_path: []const u8) !void {
    const lock_path = anim.daemonLockPathFromManifest(gpa, manifest_path) catch return;
    defer gpa.free(lock_path);

    const pid = daemon.ensureDaemon(gpa, io, lock_path, manifest_path) catch return;
    if (pid) |p| {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}\n", .{p}) catch return;
        std.Io.File.stdout().writeStreamingAll(io, s) catch {};
    }
}

fn readStdin(gpa: std.mem.Allocator, io: Io) ![]u8 {
    var buf: [4096]u8 = undefined;
    var fr = std.Io.File.stdin().readerStreaming(io, &buf);
    return fr.interface.allocRemaining(gpa, .limited(1 << 20));
}

/// Per-frame gap in milliseconds: round(1000 / fps). fps == 0 means a static
/// tier and yields 0, which buildGraphicsPayload treats as "no animation".
fn gapMs(fps: u32) u32 {
    if (fps == 0) return 0;
    return @intFromFloat(@round(1000.0 / @as(f64, @floatFromInt(fps))));
}

/// A tier animates iff it has more than one frame, a positive effective fps, and
/// the master animate switch is on. Otherwise it is static (frame 0 only), which
/// also means no daemon, manifest, or heartbeat.
fn tierAnimated(frame_count: usize, fps: u32, animate: bool) bool {
    return frame_count > 1 and fps > 0 and animate;
}

/// Resolve `path` to an absolute path against `cwd` (itself absolute): an
/// already-absolute path comes back normalized, a relative one joined onto cwd.
/// Pure/lexical (no filesystem access). The animator daemon runs from a
/// different cwd, so manifest frame paths must be absolute. Caller owns it.
fn absPath(gpa: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    return std.fs.path.resolve(gpa, &.{ cwd, path });
}

/// The tier's frame contents, their absolute paths (for the manifest), and the
/// stat signature the refresh state gates on.
const LoadedFrames = struct {
    bytes: []const []const u8,
    /// Absolute paths, index-aligned with `bytes`.
    paths: []const []const u8,
    sig: u64,

    fn deinit(self: *LoadedFrames, gpa: std.mem.Allocator) void {
        for (self.bytes) |b| gpa.free(b);
        gpa.free(self.bytes);
        for (self.paths) |p| gpa.free(p);
        gpa.free(self.paths);
    }
};

/// Resolve the tier's frames, then read and stat each one. Any failure yields
/// null (no sprite) -- the same degradation as a missing face PNG today.
fn loadFrames(gpa: std.mem.Allocator, io: Io, cfg: config.Config, tier_idx: u32) ?LoadedFrames {
    const paths = (frames.resolveTierFrames(gpa, io, cfg, tier_idx) catch null) orelse return null;
    defer frames.freeFrames(gpa, paths);

    const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", gpa) catch return null;
    defer gpa.free(cwd);

    var bytes: std.ArrayList([]const u8) = .empty;
    defer {
        for (bytes.items) |b| gpa.free(b);
        bytes.deinit(gpa);
    }
    var abs_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (abs_paths.items) |p| gpa.free(p);
        abs_paths.deinit(gpa);
    }
    var stats: std.ArrayList(state.FrameStat) = .empty;
    defer stats.deinit(gpa);

    for (paths) |path| {
        const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
        const b = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return null;
        bytes.append(gpa, b) catch {
            gpa.free(b);
            return null;
        };
        const abs = absPath(gpa, cwd, path) catch return null;
        abs_paths.append(gpa, abs) catch {
            gpa.free(abs);
            return null;
        };
        stats.append(gpa, .{ .size = st.size, .mtime = st.mtime.nanoseconds }) catch return null;
    }

    const sig = state.frameSignature(stats.items);
    const owned_bytes = bytes.toOwnedSlice(gpa) catch return null;
    const owned_paths = abs_paths.toOwnedSlice(gpa) catch {
        for (owned_bytes) |b| gpa.free(b);
        gpa.free(owned_bytes);
        return null;
    };
    return .{ .bytes = owned_bytes, .paths = owned_paths, .sig = sig };
}

const Caps = struct {
    tmux: bool,
    kitty_capable: bool,
    /// The `%N` pane this process belongs to (from $TMUX_PANE). Null outside
    /// tmux. Used to target `tmux display -t` at the correct pane's tty.
    tmux_pane: ?[]const u8,
    /// $KITTY_WINDOW_ID verbatim; keys the refresh state so distinct kitty
    /// windows keep distinct records. It does NOT detect a restarted kitty
    /// (ids restart from 1) — the state TTL bounds that staleness instead.
    kitty_window_id: ?[]const u8,
};

/// Environment inputs for state.resolveStatePath, threaded from main so
/// tryGraphics stays free of direct environ reads.
const StateEnv = struct {
    xdg_state_home: ?[]const u8,
    home: ?[]const u8,
};

fn detectCaps(environ: std.process.Environ) Caps {
    const term = environ.getPosix("TERM");
    const term_program = environ.getPosix("TERM_PROGRAM");
    const tmux_env = environ.getPosix("TMUX");
    const tmux_pane = environ.getPosix("TMUX_PANE");
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

    const pane = if (tmux_pane) |p| (if (p.len > 0) p else null) else null;
    return .{
        .tmux = is_tmux,
        .kitty_capable = capable,
        .tmux_pane = pane,
        .kitty_window_id = kitty_win,
    };
}

/// Open the graphics target and write the full escape sequence for the tier,
/// unless the refresh state says this exact (tier, image id, fps, frames)
/// already landed on this tty -- re-writing every refresh races Claude Code's
/// own writes on the same tty (interleaving mid-DCS corrupts the terminal),
/// blinks the sprite, and would restart the terminal-side animation loop.
/// Returns true only if everything succeeded; any failure degrades to no sprite.
fn tryGraphics(
    gpa: std.mem.Allocator,
    io: Io,
    caps: Caps,
    env_paths: StateEnv,
    tier_idx: u32,
    image_id: u32,
    fps: u32,
    gap_ms: u32,
    max_fps: u32,
    animated: bool,
    loaded: LoadedFrames,
    box_rows: u32,
    box_cols: u32,
    dbg: *std.ArrayList(u8),
) bool {
    var tty_path: []const u8 = "/dev/tty";
    var owned_path: ?[]u8 = null;
    defer if (owned_path) |p| gpa.free(p);

    if (caps.tmux) {
        // Pin the query to THIS pane (-t $TMUX_PANE). Without it, `tmux display`
        // resolves the session's *active* pane -- which, when we run as a
        // Claude Code statusline subprocess (no client focus), is often a
        // different pane, so the image lands on the wrong tty and never shows.
        const cmd = if (caps.tmux_pane) |pane|
            std.fmt.allocPrint(gpa, "tmux display -p -t '{s}' '#{{pane_tty}}'", .{pane}) catch return false
        else
            gpa.dupe(u8, "tmux display -p '#{pane_tty}'") catch return false;
        defer gpa.free(cmd);

        const out = rows.runCommand(gpa, io, cmd, 1000);
        dbg.print(gpa, "tmux_query={s} -> tty={s}\n", .{ cmd, out }) catch {};
        if (out.len == 0) {
            gpa.free(out);
            return false;
        }
        owned_path = out;
        tty_path = out;
    }

    // State setup is best-effort: any failure means "no gating", never "no
    // sprite". The exclusive lock also serializes concurrent statusline
    // instances so their tty writes can't interleave.
    var locked: ?state.Locked = null;
    defer if (locked) |*l| l.close(io);

    const key = state.stateKey(tty_path, caps.kitty_window_id, caps.tmux_pane);
    if (state.resolveStatePath(gpa, env_paths.xdg_state_home, env_paths.home, key) catch null) |path| {
        defer gpa.free(path);
        locked = state.Locked.open(io, path) catch null;
    }

    const current: state.State = .{
        .tier = tier_idx,
        .image_id = image_id,
        .fps = fps,
        .frame_sig = loaded.sig,
    };

    // A hit must NOT touch the state file: its mtime marks the last transmit,
    // so the TTL forces one retransmit ~10 min after that, bounding staleness
    // from a restarted terminal whose image store is gone while the state still
    // says "transmitted".
    const hit = if (locked) |l| blk: {
        const now_ns = Io.Timestamp.now(io, .real).nanoseconds;
        const h = state.matches(l.state, current) and !state.isExpired(l.mtime_ns, now_ns);
        dbg.print(gpa, "state={s} id={d}\n", .{ if (h) "hit" else "miss", image_id }) catch {};
        break :blk h;
    } else blk: {
        dbg.print(gpa, "state=bypass\n", .{}) catch {};
        break :blk false;
    };

    // On a hit, frame 0 is already on the tty; skip the transmit (re-writing
    // would delete-and-replace mid-animation, blinking the sprite back to frame
    // 0 and racing Claude Code's own tty writes). The animated upkeep below
    // still runs -- the daemon must stay fed regardless.
    if (!hit) {
        const tty = std.Io.Dir.openFileAbsolute(io, tty_path, .{ .mode = .write_only }) catch |e| {
            dbg.print(gpa, "open tty {s} failed: {}\n", .{ tty_path, e }) catch {};
            return false;
        };
        defer tty.close(io);

        buildAndWrite(gpa, io, tty, caps.tmux, image_id, loaded.bytes, box_rows, box_cols) catch |e| {
            dbg.print(gpa, "buildAndWrite failed: {}\n", .{e}) catch {};
            return false;
        };
        dbg.print(gpa, "graphics written to {s}\n", .{tty_path}) catch {};

        // Only a confirmed write gets recorded; a failed commit just means a
        // redundant retransmit next frame.
        if (locked) |*l| {
            l.state = current;
            l.commit(gpa, io) catch {};
        }
    }

    // Animated tiers refresh the manifest, touch the heartbeat, and ensure the
    // daemon on EVERY invocation (hit or miss) -- done after the transmit so the
    // daemon can't clobber our frame-0 bytes before they land. Static tiers do
    // none of this. All best-effort: a failure never downgrades a placed sprite.
    if (animated) {
        animatedUpkeep(gpa, io, env_paths, key, image_id, gap_ms, max_fps, caps.tmux, tty_path, loaded, dbg);
    }
    return true;
}

/// Feed the resident animator daemon for an animated tier: touch the heartbeat,
/// rewrite the manifest with the current tier's absolute frame paths, and ensure
/// a daemon is running. Every step is best-effort (any failure is logged and
/// skipped) so it can never turn a successfully-placed sprite into no sprite.
fn animatedUpkeep(
    gpa: std.mem.Allocator,
    io: Io,
    env_paths: StateEnv,
    key: u64,
    image_id: u32,
    gap_ms: u32,
    max_fps: u32,
    tmux: bool,
    tty_path: []const u8,
    loaded: LoadedFrames,
    dbg: *std.ArrayList(u8),
) void {
    const xdg = env_paths.xdg_state_home;
    const home = env_paths.home;

    if (anim.heartbeatPath(gpa, xdg, home, key)) |hb| {
        defer gpa.free(hb);
        anim.touchHeartbeat(io, hb) catch |e| dbg.print(gpa, "heartbeat failed: {}\n", .{e}) catch {};
    } else |_| {}

    const manifest_path = anim.manifestPath(gpa, xdg, home, key) catch return;
    defer gpa.free(manifest_path);

    // Normalise the tty to an absolute path (it already is, in practice) so the
    // manifest's absolute-path invariant holds even for a hand-set target.
    const abs_tty = std.fs.path.resolve(gpa, &.{tty_path}) catch return;
    defer gpa.free(abs_tty);

    const manifest: anim.Manifest = .{
        .image_id = image_id,
        .gap_ms = gap_ms,
        .max_fps = max_fps,
        .tmux = tmux,
        .tty_path = abs_tty,
        .frames = loaded.paths,
        .frame_sig = loaded.sig,
    };
    anim.writeManifest(gpa, io, manifest_path, manifest) catch |e| {
        dbg.print(gpa, "writeManifest failed: {}\n", .{e}) catch {};
        return;
    };

    const lock_path = anim.daemonLockPath(gpa, xdg, home, key) catch return;
    defer gpa.free(lock_path);
    if (daemon.ensureDaemon(gpa, io, lock_path, manifest_path)) |pid| {
        dbg.print(gpa, "ensureDaemon spawned={?d}\n", .{pid}) catch {};
    } else |e| {
        dbg.print(gpa, "ensureDaemon failed: {}\n", .{e}) catch {};
    }
}

fn buildAndWrite(
    gpa: std.mem.Allocator,
    io: Io,
    tty: std.Io.File,
    tmux: bool,
    image_id: u32,
    frame_bytes: []const []const u8,
    box_rows: u32,
    box_cols: u32,
) !void {
    const payload = try buildGraphicsPayload(gpa, tmux, image_id, frame_bytes, box_rows, box_cols);
    defer gpa.free(payload);
    try tty.writeStreamingAll(io, payload);
}

/// Assemble the static graphics escape payload for one image id: delete ->
/// transmit frame 0 -> virtual placement. Byte-identical to `staticSequence`.
/// With `tmux` set, every APC is individually passthrough-wrapped. Caller owns
/// the result.
///
/// Motion for animated tiers comes from the resident animator daemon
/// (SPEC-007), which re-transmits frames via bare `a=t`; the retired kitty
/// `a=f`/`a=a` animation escapes are never emitted here.
pub fn buildGraphicsPayload(
    gpa: std.mem.Allocator,
    tmux: bool,
    image_id: u32,
    frame_bytes: []const []const u8,
    box_rows: u32,
    box_cols: u32,
) ![]u8 {
    std.debug.assert(frame_bytes.len >= 1);

    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(gpa);

    {
        const esc = try kitty.delete(gpa, image_id);
        defer gpa.free(esc);
        try appendMaybeTmux(gpa, &payload, tmux, esc);
    }
    {
        const esc = try kitty.transmit(gpa, image_id, frame_bytes[0], .{});
        defer gpa.free(esc);
        try appendMaybeTmux(gpa, &payload, tmux, esc);
    }
    {
        const esc = try kitty.virtualPlacement(gpa, image_id, box_rows, box_cols);
        defer gpa.free(esc);
        try appendMaybeTmux(gpa, &payload, tmux, esc);
    }

    return payload.toOwnedSlice(gpa);
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
    _ = @import("frames.zig");
    _ = @import("rows.zig");
    _ = @import("state.zig");
    _ = @import("anim.zig");
    _ = @import("daemon.zig");
}

test "gapMs: fps 0 means static and yields 0" {
    try std.testing.expectEqual(@as(u32, 0), gapMs(0));
}

test "gapMs rounds 1000/fps to the nearest millisecond" {
    try std.testing.expectEqual(@as(u32, 125), gapMs(8));
    // 1000/16 = 62.5; @round rounds half away from zero.
    try std.testing.expectEqual(@as(u32, 63), gapMs(16));
    try std.testing.expectEqual(@as(u32, 33), gapMs(30));
    try std.testing.expectEqual(@as(u32, 1000), gapMs(1));
    // fps beyond 1000 rounds down to 0: no per-frame gap survives.
    try std.testing.expectEqual(@as(u32, 0), gapMs(3000));
}

/// The pre-animation static sequence (delete + transmit + placement), built
/// from the independently-tested kitty builders. The static path of
/// buildGraphicsPayload must be byte-identical to this.
fn staticSequence(
    a: std.mem.Allocator,
    image_id: u32,
    png: []const u8,
    box_rows: u32,
    box_cols: u32,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const del = try kitty.delete(a, image_id);
    defer a.free(del);
    try out.appendSlice(a, del);
    const tr = try kitty.transmit(a, image_id, png, .{});
    defer a.free(tr);
    try out.appendSlice(a, tr);
    const pl = try kitty.virtualPlacement(a, image_id, box_rows, box_cols);
    defer a.free(pl);
    try out.appendSlice(a, pl);
    return out.toOwnedSlice(a);
}

/// Parse a byte stream that must consist ONLY of tmux passthrough units
/// (`ESC Ptmux; <esc-doubled body> ESC \`). Returns the concatenated
/// un-doubled bodies; errors on any bytes outside a wrapper or any bare ESC
/// inside one.
fn unwrapTmuxUnits(a: std.mem.Allocator, wrapped: []const u8, count_out: *usize) ![]u8 {
    const prefix = "\x1bPtmux;";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var count: usize = 0;
    var i: usize = 0;
    while (i < wrapped.len) {
        if (!std.mem.startsWith(u8, wrapped[i..], prefix)) return error.BytesOutsideWrapper;
        i += prefix.len;
        count += 1;
        while (true) {
            if (i >= wrapped.len) return error.UnterminatedWrapper;
            const b = wrapped[i];
            if (b != 0x1b) {
                try out.append(a, b);
                i += 1;
                continue;
            }
            if (i + 1 >= wrapped.len) return error.UnterminatedWrapper;
            switch (wrapped[i + 1]) {
                0x1b => {
                    try out.append(a, 0x1b);
                    i += 2;
                },
                '\\' => {
                    i += 2;
                    break;
                },
                else => return error.BareEscapeInWrapper,
            }
        }
    }
    count_out.* = count;
    return out.toOwnedSlice(a);
}

test "tierAnimated: needs >1 frame, positive fps, and the animate switch" {
    try std.testing.expect(tierAnimated(3, 8, true));
    try std.testing.expect(!tierAnimated(1, 8, true)); // single frame
    try std.testing.expect(!tierAnimated(3, 0, true)); // fps 0
    try std.testing.expect(!tierAnimated(3, 8, false)); // animate off
    try std.testing.expect(!tierAnimated(0, 8, true)); // no frames
}

test "absPath: keeps an absolute path, joins a relative one onto cwd" {
    const a = std.testing.allocator;

    const kept = try absPath(a, "/home/me/proj", "/opt/sprites/0.png");
    defer a.free(kept);
    try std.testing.expectEqualStrings("/opt/sprites/0.png", kept);

    const joined = try absPath(a, "/home/me/proj", "test-sprites/anim/0.png");
    defer a.free(joined);
    try std.testing.expectEqualStrings("/home/me/proj/test-sprites/anim/0.png", joined);

    // The repo-relative default (`./test-sprites`) normalises the leading `.`.
    const dotted = try absPath(a, "/home/me/proj", "./test-sprites/face0.png");
    defer a.free(dotted);
    try std.testing.expectEqualStrings("/home/me/proj/test-sprites/face0.png", dotted);
}

test "buildGraphicsPayload: N=1 is byte-identical to the static sequence, no a=f/a=a" {
    const a = std.testing.allocator;
    const out = try buildGraphicsPayload(a, false, 103, &.{"F0"}, 3, 6);
    defer a.free(out);

    const expected = try staticSequence(a, 103, "F0", 3, 6);
    defer a.free(expected);
    try std.testing.expectEqualSlices(u8, expected, out);

    try std.testing.expect(std.mem.indexOf(u8, out, "a=f") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a=a") == null);
}

test "buildGraphicsPayload: N>1 still yields only the static frame-0 sequence" {
    const a = std.testing.allocator;
    // Extra frames belong to the daemon now; the statusline transmits frame 0
    // only, byte-identical to the static sequence.
    const out = try buildGraphicsPayload(a, false, 103, &.{ "F0", "F1", "F2" }, 3, 6);
    defer a.free(out);

    const expected = try staticSequence(a, 103, "F0", 3, 6);
    defer a.free(expected);
    try std.testing.expectEqualSlices(u8, expected, out);
    try std.testing.expect(std.mem.indexOf(u8, out, "a=f") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a=a") == null);
}

test "buildGraphicsPayload: static order is delete, a=t, placement" {
    const a = std.testing.allocator;
    const out = try buildGraphicsPayload(a, false, 103, &.{ "F0", "F1", "F2" }, 3, 6);
    defer a.free(out);

    const idx_delete = std.mem.indexOf(u8, out, "a=d,").?;
    const idx_transmit = std.mem.indexOf(u8, out, "a=t,").?;
    const idx_place = std.mem.indexOf(u8, out, "a=p,").?;
    try std.testing.expect(idx_delete < idx_transmit);
    try std.testing.expect(idx_transmit < idx_place);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "a=t"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "a=f"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "a=a"));
}

test "buildGraphicsPayload: tmux wraps every APC individually and nothing else" {
    const a = std.testing.allocator;
    const frame_list: []const []const u8 = &.{ "F0", "F1", "F2" };

    const wrapped = try buildGraphicsPayload(a, true, 103, frame_list, 3, 6);
    defer a.free(wrapped);
    const plain = try buildGraphicsPayload(a, false, 103, frame_list, 3, 6);
    defer a.free(plain);

    var count: usize = 0;
    const unwrapped = try unwrapTmuxUnits(a, wrapped, &count);
    defer a.free(unwrapped);

    // delete + a=t + placement
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, wrapped, "\x1bPtmux;"));
    try std.testing.expectEqualSlices(u8, plain, unwrapped);

    // any \x1b_G must be the doubled-ESC form inside a wrapper
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, wrapped, pos, "\x1b_G")) |i| {
        try std.testing.expect(i > 0 and wrapped[i - 1] == 0x1b);
        pos = i + 1;
    }
}
