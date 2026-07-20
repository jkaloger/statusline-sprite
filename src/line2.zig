const std = @import("std");
const Allocator = std.mem.Allocator;
const Statusline = @import("statusline.zig").Statusline;
const Line2 = @import("config.zig").Line2;

/// `sl.model_display_name`. The parser default `"unknown"` is data, not
/// absence, and still renders; only a genuinely empty name hides it.
pub fn renderModel(a: Allocator, sl: Statusline) !?[]const u8 {
    if (sl.model_display_name.len == 0) return null;
    return try a.dupe(u8, sl.model_display_name);
}

/// Percentage + token counts, degrading gracefully when either half is
/// unavailable: `"45% (12.3k/200k)"`, `"45%"`, `"12.3k/200k"`, or hidden.
pub fn renderContext(a: Allocator, sl: Statusline) !?[]const u8 {
    const pct_ok = if (sl.used_percentage) |p| !std.math.isNan(p) else false;
    const counts_ok = sl.total_input_tokens != null and sl.context_window_size != null;

    if (!pct_ok and !counts_ok) return null;

    if (pct_ok and counts_ok) {
        const pct_i: i64 = @intFromFloat(@round(sl.used_percentage.?));
        const input_str = try formatTokenCount(a, sl.total_input_tokens.?);
        defer a.free(input_str);
        const window_str = try formatTokenCount(a, sl.context_window_size.?);
        defer a.free(window_str);
        return try std.fmt.allocPrint(a, "{d}% ({s}/{s})", .{ pct_i, input_str, window_str });
    }

    if (pct_ok) {
        const pct_i: i64 = @intFromFloat(@round(sl.used_percentage.?));
        return try std.fmt.allocPrint(a, "{d}%", .{pct_i});
    }

    // counts_ok is guaranteed true here (the !pct_ok and !counts_ok case
    // already returned above).
    const input_str = try formatTokenCount(a, sl.total_input_tokens.?);
    defer a.free(input_str);
    const window_str = try formatTokenCount(a, sl.context_window_size.?);
    defer a.free(window_str);
    return try std.fmt.allocPrint(a, "{s}/{s}", .{ input_str, window_str });
}

/// Formats a token count: `n <= 1000` renders raw; `n > 1000` renders with a
/// one-decimal `k` suffix, its trailing `.0` trimmed (`200000` -> `"200k"`).
fn formatTokenCount(a: Allocator, n: u64) ![]const u8 {
    if (n <= 1000) return try std.fmt.allocPrint(a, "{d}", .{n});

    const thousands: f64 = @as(f64, @floatFromInt(n)) / 1000.0;
    const rounded = @round(thousands * 10.0) / 10.0;
    const full = try std.fmt.allocPrint(a, "{d:.1}k", .{rounded});
    if (std.mem.endsWith(u8, full, ".0k")) {
        defer a.free(full);
        return try std.fmt.allocPrint(a, "{s}k", .{full[0 .. full.len - 3]});
    }
    return full;
}

/// `"$<amount>"` to two decimal places. Hidden only when the field is null;
/// `0.0` still renders as `"$0.00"`.
pub fn renderCost(a: Allocator, sl: Statusline) !?[]const u8 {
    const cost = sl.total_cost_usd orelse return null;
    return try std.fmt.allocPrint(a, "${d:.2}", .{cost});
}

/// `"5h <pct>%"`, rounded to the nearest integer percent.
pub fn renderSessionLimit(a: Allocator, sl: Statusline) !?[]const u8 {
    const pct = sl.five_hour_used_percentage orelse return null;
    const pct_i: i64 = @intFromFloat(@round(pct));
    return try std.fmt.allocPrint(a, "5h {d}%", .{pct_i});
}

/// `"7d <pct>%"`, rounded to the nearest integer percent.
pub fn renderWeeklyLimit(a: Allocator, sl: Statusline) !?[]const u8 {
    const pct = sl.seven_day_used_percentage orelse return null;
    const pct_i: i64 = @intFromFloat(@round(pct));
    return try std.fmt.allocPrint(a, "7d {d}%", .{pct_i});
}

/// `"+<added>/-<removed>"`. Both values must be present -- the spec doesn't
/// define a partial-data format, so a single missing half hides the segment
/// entirely rather than guessing a rendering for it.
pub fn renderLines(a: Allocator, sl: Statusline) !?[]const u8 {
    const added = sl.total_lines_added orelse return null;
    const removed = sl.total_lines_removed orelse return null;
    return try std.fmt.allocPrint(a, "+{d}/-{d}", .{ added, removed });
}

/// Compact duration: `"45s"` under a minute, `"12m"` under an hour, else
/// `"1h03m"` (minutes zero-padded to 2 digits).
pub fn renderDuration(a: Allocator, sl: Statusline) !?[]const u8 {
    const ms = sl.total_duration_ms orelse return null;
    return try formatDuration(a, ms);
}

fn formatDuration(a: Allocator, ms: u64) ![]const u8 {
    const total_seconds = ms / 1000;
    if (total_seconds < 60) return try std.fmt.allocPrint(a, "{d}s", .{total_seconds});
    if (total_seconds < 3600) return try std.fmt.allocPrint(a, "{d}m", .{total_seconds / 60});
    const hours = total_seconds / 3600;
    const minutes = (total_seconds % 3600) / 60;
    return try std.fmt.allocPrint(a, "{d}h{d:0>2}m", .{ hours, minutes });
}

/// Verbatim `sl.effort_level`, hidden if null or empty.
pub fn renderEffort(a: Allocator, sl: Statusline) !?[]const u8 {
    const level = sl.effort_level orelse return null;
    if (level.len == 0) return null;
    return try a.dupe(u8, level);
}

/// Verbatim `sl.output_style_name`, hidden if null, empty, or `"default"`
/// (the default style is noise, not a meaningful choice to surface).
pub fn renderStyle(a: Allocator, sl: Statusline) !?[]const u8 {
    const name = sl.output_style_name orelse return null;
    if (name.len == 0) return null;
    if (std.mem.eql(u8, name, "default")) return null;
    return try a.dupe(u8, name);
}

/// Verbatim `sl.version`, hidden if null or empty.
pub fn renderVersion(a: Allocator, sl: Statusline) !?[]const u8 {
    const version = sl.version orelse return null;
    if (version.len == 0) return null;
    return try a.dupe(u8, version);
}

/// Literal `"fast"` when `sl.fast_mode` is true; hidden otherwise.
pub fn renderFast(a: Allocator, sl: Statusline) !?[]const u8 {
    if (sl.fast_mode orelse false) return try a.dupe(u8, "fast");
    return null;
}

/// Literal `"think"` when `sl.thinking_enabled` is true; hidden otherwise.
pub fn renderThinking(a: Allocator, sl: Statusline) !?[]const u8 {
    if (sl.thinking_enabled orelse false) return try a.dupe(u8, "think");
    return null;
}

/// Verbatim `sl.vim_mode`, hidden if null or empty.
pub fn renderVim(a: Allocator, sl: Statusline) !?[]const u8 {
    const mode = sl.vim_mode orelse return null;
    if (mode.len == 0) return null;
    return try a.dupe(u8, mode);
}

/// `"PR#<number>"`, with `" (<review_state>)"` appended when present and
/// non-empty. Hidden if `pr_number` is null.
pub fn renderPr(a: Allocator, sl: Statusline) !?[]const u8 {
    const number = sl.pr_number orelse return null;
    if (sl.pr_review_state) |state| {
        if (state.len != 0) return try std.fmt.allocPrint(a, "PR#{d} ({s})", .{ number, state });
    }
    return try std.fmt.allocPrint(a, "PR#{d}", .{number});
}

/// Verbatim `sl.agent_name`, hidden if null or empty.
pub fn renderAgent(a: Allocator, sl: Statusline) !?[]const u8 {
    const name = sl.agent_name orelse return null;
    if (name.len == 0) return null;
    return try a.dupe(u8, name);
}

/// Dispatch a single segment name to its renderer. Unknown names yield `null`
/// (silently skipped), same as a renderer whose backing data is absent.
fn dispatchSegment(a: Allocator, name: []const u8, sl: Statusline) !?[]const u8 {
    if (std.mem.eql(u8, name, "model")) return renderModel(a, sl);
    if (std.mem.eql(u8, name, "context")) return renderContext(a, sl);
    if (std.mem.eql(u8, name, "cost")) return renderCost(a, sl);
    if (std.mem.eql(u8, name, "session_limit")) return renderSessionLimit(a, sl);
    if (std.mem.eql(u8, name, "weekly_limit")) return renderWeeklyLimit(a, sl);
    if (std.mem.eql(u8, name, "lines")) return renderLines(a, sl);
    if (std.mem.eql(u8, name, "duration")) return renderDuration(a, sl);
    if (std.mem.eql(u8, name, "effort")) return renderEffort(a, sl);
    if (std.mem.eql(u8, name, "style")) return renderStyle(a, sl);
    if (std.mem.eql(u8, name, "version")) return renderVersion(a, sl);
    if (std.mem.eql(u8, name, "fast")) return renderFast(a, sl);
    if (std.mem.eql(u8, name, "thinking")) return renderThinking(a, sl);
    if (std.mem.eql(u8, name, "vim")) return renderVim(a, sl);
    if (std.mem.eql(u8, name, "pr")) return renderPr(a, sl);
    if (std.mem.eql(u8, name, "agent")) return renderAgent(a, sl);
    return null;
}

/// Assembles line2 from `cfg`: resolves the segment list (default `["model"]`),
/// dispatches each in order, colors it (`colors[i]`, falling back to
/// `line2.color` for `model` when that position has no explicit color), and
/// joins the surviving (non-hidden) segments with `cfg.separator` (default
/// `"  "`). Hidden segments (unknown name, or a renderer returning null for
/// missing data) are dropped with no doubled separator. An all-hidden or
/// empty resolved list yields an empty owned slice, not an error.
pub fn renderLine2(a: Allocator, cfg: Line2, sl: Statusline) ![]const u8 {
    const default_segments = [_][]const u8{"model"};
    const segments: []const []const u8 = cfg.segments orelse &default_segments;
    const separator: []const u8 = cfg.separator orelse "  ";

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    var wrote_any = false;
    for (segments, 0..) |name, i| {
        const text = (try dispatchSegment(a, name, sl)) orelse continue;
        defer a.free(text);

        // Three states at position i, not two: an explicit `-1` entry
        // (colors[i] == null) means "explicitly unstyled" and must win over
        // the `line2.color` fallback -- only a truly absent/short-array
        // position falls back for `model`.
        const has_explicit_entry = if (cfg.colors) |colors| i < colors.len else false;
        var color: ?u8 = null;
        if (has_explicit_entry) {
            color = cfg.colors.?[i];
        } else if (std.mem.eql(u8, name, "model")) {
            color = cfg.color;
        }

        if (wrote_any) try out.appendSlice(a, separator);

        if (color) |c| {
            const wrapped = try std.fmt.allocPrint(a, "\x1b[38;5;{d}m{s}\x1b[0m", .{ c, text });
            defer a.free(wrapped);
            try out.appendSlice(a, wrapped);
        } else {
            try out.appendSlice(a, text);
        }
        wrote_any = true;
    }

    return try out.toOwnedSlice(a);
}

fn baseSl() Statusline {
    return .{
        .model_display_name = "unknown",
        .total_input_tokens = null,
        .used_percentage = null,
        .context_window_size = null,
    };
}

test "renderModel: representative name renders a dupe" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.model_display_name = "Opus 4.8";
    const out = (try renderModel(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("Opus 4.8", out);
}

test "renderModel: default 'unknown' still renders (data, not absence)" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.model_display_name = "unknown";
    const out = (try renderModel(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("unknown", out);
}

test "renderModel: empty name hides" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.model_display_name = "";
    try std.testing.expectEqual(@as(?[]const u8, null), try renderModel(a, sl));
}

test "renderContext: percentage and counts both present" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.used_percentage = 45.0;
    sl.total_input_tokens = 12345;
    sl.context_window_size = 200000;
    const out = (try renderContext(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("45% (12.3k/200k)", out);
}

test "renderContext: percentage only" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.used_percentage = 45.0;
    const out = (try renderContext(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("45%", out);
}

test "renderContext: counts only, no percent sign" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.total_input_tokens = 12345;
    sl.context_window_size = 200000;
    const out = (try renderContext(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("12.3k/200k", out);
}

test "renderContext: neither percentage nor full counts hides" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.total_input_tokens = 12345; // window missing, so counts are not "both present"
    try std.testing.expectEqual(@as(?[]const u8, null), try renderContext(a, sl));
}

test "renderContext: NaN percentage treated as absent, falls back to counts" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.used_percentage = std.math.nan(f64);
    sl.total_input_tokens = 12345;
    sl.context_window_size = 200000;
    const out = (try renderContext(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("12.3k/200k", out);
}

test "renderContext: NaN percentage with no counts hides" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.used_percentage = std.math.nan(f64);
    try std.testing.expectEqual(@as(?[]const u8, null), try renderContext(a, sl));
}

test "formatTokenCount: at or below 1000 is raw" {
    const a = std.testing.allocator;
    const s999 = try formatTokenCount(a, 999);
    defer a.free(s999);
    try std.testing.expectEqualStrings("999", s999);

    const s1000 = try formatTokenCount(a, 1000);
    defer a.free(s1000);
    try std.testing.expectEqualStrings("1000", s1000);
}

test "formatTokenCount: above 1000 uses k-suffix with one decimal" {
    const a = std.testing.allocator;
    const s = try formatTokenCount(a, 12345);
    defer a.free(s);
    try std.testing.expectEqualStrings("12.3k", s);
}

test "formatTokenCount: trailing .0 is trimmed" {
    const a = std.testing.allocator;
    const s = try formatTokenCount(a, 200000);
    defer a.free(s);
    try std.testing.expectEqualStrings("200k", s);
}

test "formatTokenCount: 1500 keeps one decimal" {
    const a = std.testing.allocator;
    const s = try formatTokenCount(a, 1500);
    defer a.free(s);
    try std.testing.expectEqualStrings("1.5k", s);
}

test "renderCost: representative amount" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.total_cost_usd = 1.42;
    const out = (try renderCost(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("$1.42", out);
}

test "renderCost: zero still renders, not suppressed" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.total_cost_usd = 0.0;
    const out = (try renderCost(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("$0.00", out);
}

test "renderCost: null hides" {
    const a = std.testing.allocator;
    const sl = baseSl();
    try std.testing.expectEqual(@as(?[]const u8, null), try renderCost(a, sl));
}

test "renderSessionLimit: representative percentage" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.five_hour_used_percentage = 23.0;
    const out = (try renderSessionLimit(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("5h 23%", out);
}

test "renderSessionLimit: null hides" {
    const a = std.testing.allocator;
    const sl = baseSl();
    try std.testing.expectEqual(@as(?[]const u8, null), try renderSessionLimit(a, sl));
}

test "renderWeeklyLimit: representative percentage" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.seven_day_used_percentage = 12.0;
    const out = (try renderWeeklyLimit(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("7d 12%", out);
}

test "renderWeeklyLimit: null hides" {
    const a = std.testing.allocator;
    const sl = baseSl();
    try std.testing.expectEqual(@as(?[]const u8, null), try renderWeeklyLimit(a, sl));
}

test "renderLines: both present" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.total_lines_added = 42;
    sl.total_lines_removed = 7;
    const out = (try renderLines(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("+42/-7", out);
}

test "renderLines: either missing hides" {
    const a = std.testing.allocator;
    var sl1 = baseSl();
    sl1.total_lines_added = 42;
    try std.testing.expectEqual(@as(?[]const u8, null), try renderLines(a, sl1));

    var sl2 = baseSl();
    sl2.total_lines_removed = 7;
    try std.testing.expectEqual(@as(?[]const u8, null), try renderLines(a, sl2));
}

test "renderDuration: null hides" {
    const a = std.testing.allocator;
    const sl = baseSl();
    try std.testing.expectEqual(@as(?[]const u8, null), try renderDuration(a, sl));
}

test "renderDuration: representative seconds band" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.total_duration_ms = 45000;
    const out = (try renderDuration(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("45s", out);
}

test "formatDuration: seconds band" {
    const a = std.testing.allocator;
    const out = try formatDuration(a, 45000);
    defer a.free(out);
    try std.testing.expectEqualStrings("45s", out);
}

test "formatDuration: minutes band" {
    const a = std.testing.allocator;
    const out = try formatDuration(a, 12 * 60 * 1000);
    defer a.free(out);
    try std.testing.expectEqualStrings("12m", out);
}

test "formatDuration: hours band, zero-padded minutes" {
    const a = std.testing.allocator;
    const out = try formatDuration(a, (3600 + 3 * 60) * 1000);
    defer a.free(out);
    try std.testing.expectEqualStrings("1h03m", out);
}

test "renderEffort: representative value" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.effort_level = "high";
    const out = (try renderEffort(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("high", out);
}

test "renderEffort: null or empty hides" {
    const a = std.testing.allocator;
    const sl = baseSl();
    try std.testing.expectEqual(@as(?[]const u8, null), try renderEffort(a, sl));

    var sl2 = baseSl();
    sl2.effort_level = "";
    try std.testing.expectEqual(@as(?[]const u8, null), try renderEffort(a, sl2));
}

test "renderStyle: representative value" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.output_style_name = "explanatory";
    const out = (try renderStyle(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("explanatory", out);
}

test "renderStyle: hidden when null, empty, or 'default'" {
    const a = std.testing.allocator;
    const sl = baseSl();
    try std.testing.expectEqual(@as(?[]const u8, null), try renderStyle(a, sl));

    var sl2 = baseSl();
    sl2.output_style_name = "";
    try std.testing.expectEqual(@as(?[]const u8, null), try renderStyle(a, sl2));

    var sl3 = baseSl();
    sl3.output_style_name = "default";
    try std.testing.expectEqual(@as(?[]const u8, null), try renderStyle(a, sl3));
}

test "renderVersion: representative value" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.version = "1.2.3";
    const out = (try renderVersion(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("1.2.3", out);
}

test "renderVersion: null or empty hides" {
    const a = std.testing.allocator;
    const sl = baseSl();
    try std.testing.expectEqual(@as(?[]const u8, null), try renderVersion(a, sl));

    var sl2 = baseSl();
    sl2.version = "";
    try std.testing.expectEqual(@as(?[]const u8, null), try renderVersion(a, sl2));
}

test "renderFast: true yields 'fast', false or null hides" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.fast_mode = true;
    const out = (try renderFast(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("fast", out);

    sl.fast_mode = false;
    try std.testing.expectEqual(@as(?[]const u8, null), try renderFast(a, sl));

    sl.fast_mode = null;
    try std.testing.expectEqual(@as(?[]const u8, null), try renderFast(a, sl));
}

test "renderThinking: true yields 'think', false or null hides" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.thinking_enabled = true;
    const out = (try renderThinking(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("think", out);

    sl.thinking_enabled = false;
    try std.testing.expectEqual(@as(?[]const u8, null), try renderThinking(a, sl));

    sl.thinking_enabled = null;
    try std.testing.expectEqual(@as(?[]const u8, null), try renderThinking(a, sl));
}

test "renderVim: representative value" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.vim_mode = "NORMAL";
    const out = (try renderVim(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("NORMAL", out);
}

test "renderVim: null or empty hides" {
    const a = std.testing.allocator;
    const sl = baseSl();
    try std.testing.expectEqual(@as(?[]const u8, null), try renderVim(a, sl));

    var sl2 = baseSl();
    sl2.vim_mode = "";
    try std.testing.expectEqual(@as(?[]const u8, null), try renderVim(a, sl2));
}

test "renderPr: number with review state" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.pr_number = 123;
    sl.pr_review_state = "approved";
    const out = (try renderPr(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("PR#123 (approved)", out);
}

test "renderPr: number without review state" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.pr_number = 123;
    const out = (try renderPr(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("PR#123", out);

    sl.pr_review_state = "";
    const out2 = (try renderPr(a, sl)).?;
    defer a.free(out2);
    try std.testing.expectEqualStrings("PR#123", out2);
}

test "renderPr: null number hides" {
    const a = std.testing.allocator;
    const sl = baseSl();
    try std.testing.expectEqual(@as(?[]const u8, null), try renderPr(a, sl));
}

test "renderAgent: representative value" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.agent_name = "reviewer";
    const out = (try renderAgent(a, sl)).?;
    defer a.free(out);
    try std.testing.expectEqualStrings("reviewer", out);
}

test "renderAgent: null or empty hides" {
    const a = std.testing.allocator;
    const sl = baseSl();
    try std.testing.expectEqual(@as(?[]const u8, null), try renderAgent(a, sl));

    var sl2 = baseSl();
    sl2.agent_name = "";
    try std.testing.expectEqual(@as(?[]const u8, null), try renderAgent(a, sl2));
}

fn emptyLine2() Line2 {
    return .{ .color = null, .segments = null, .colors = null, .separator = null };
}

test "renderLine2: default segments with color matches today's exact escape format" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.model_display_name = "Opus 4.8";
    var cfg = emptyLine2();
    cfg.color = 213;

    const out = try renderLine2(a, cfg, sl);
    defer a.free(out);
    try std.testing.expectEqualStrings("\x1b[38;5;213mOpus 4.8\x1b[0m", out);
}

test "renderLine2: default segments with no color is bare model name" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.model_display_name = "Opus 4.8";
    const cfg = emptyLine2();

    const out = try renderLine2(a, cfg, sl);
    defer a.free(out);
    try std.testing.expectEqualStrings("Opus 4.8", out);
}

test "renderLine2: three segments render in order with per-position colors and individual resets" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.model_display_name = "Opus 4.8";
    sl.used_percentage = 45.0;
    sl.total_cost_usd = 1.42;
    var cfg = emptyLine2();
    cfg.segments = &.{ "model", "context", "cost" };
    cfg.colors = &.{ 213, null, 46 };

    const out = try renderLine2(a, cfg, sl);
    defer a.free(out);
    try std.testing.expectEqualStrings(
        "\x1b[38;5;213mOpus 4.8\x1b[0m  45%  \x1b[38;5;46m$1.42\x1b[0m",
        out,
    );
}

test "renderLine2: custom separator is honoured between segments" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.model_display_name = "Opus 4.8";
    sl.total_cost_usd = 1.42;
    var cfg = emptyLine2();
    cfg.segments = &.{ "model", "cost" };
    cfg.separator = " | ";

    const out = try renderLine2(a, cfg, sl);
    defer a.free(out);
    try std.testing.expectEqualStrings("Opus 4.8 | $1.42", out);
}

test "renderLine2: a segment with absent data drops with no doubled separator" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.model_display_name = "Opus 4.8";
    // context left entirely unset -> renderContext hides it.
    sl.total_cost_usd = 1.42;
    var cfg = emptyLine2();
    cfg.segments = &.{ "model", "context", "cost" };

    const out = try renderLine2(a, cfg, sl);
    defer a.free(out);
    try std.testing.expectEqualStrings("Opus 4.8  $1.42", out);
}

test "renderLine2: all segments absent yields an empty string" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.model_display_name = "";
    var cfg = emptyLine2();
    cfg.segments = &.{ "model", "context", "cost" };

    const out = try renderLine2(a, cfg, sl);
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "renderLine2: empty segments list yields an empty string" {
    const a = std.testing.allocator;
    const sl = baseSl();
    var cfg = emptyLine2();
    cfg.segments = &.{};

    const out = try renderLine2(a, cfg, sl);
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "renderLine2: unknown segment name is silently skipped, no gap artifact" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.model_display_name = "Opus 4.8";
    sl.total_cost_usd = 1.42;
    var cfg = emptyLine2();
    cfg.segments = &.{ "model", "bogus", "cost" };

    const out = try renderLine2(a, cfg, sl);
    defer a.free(out);
    try std.testing.expectEqualStrings("Opus 4.8  $1.42", out);
}

test "renderLine2: line2.color fallback colors model even when segments is set, other segments stay unstyled" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.model_display_name = "Opus 4.8";
    sl.total_cost_usd = 1.42;
    var cfg = emptyLine2();
    cfg.segments = &.{ "model", "cost" };
    cfg.color = 213;

    const out = try renderLine2(a, cfg, sl);
    defer a.free(out);
    try std.testing.expectEqualStrings("\x1b[38;5;213mOpus 4.8\x1b[0m  $1.42", out);
}

test "renderLine2: colors array shorter than segments leaves trailing segments unstyled" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.model_display_name = "Opus 4.8";
    sl.total_cost_usd = 1.42;
    var cfg = emptyLine2();
    cfg.segments = &.{ "model", "cost" };
    cfg.colors = &.{213};

    const out = try renderLine2(a, cfg, sl);
    defer a.free(out);
    try std.testing.expectEqualStrings("\x1b[38;5;213mOpus 4.8\x1b[0m  $1.42", out);
}

test "renderLine2: explicit -1 (null) colors entry wins over line2.color fallback, model renders unstyled" {
    const a = std.testing.allocator;
    var sl = baseSl();
    sl.model_display_name = "Opus 4.8";
    sl.total_cost_usd = 1.42;
    var cfg = emptyLine2();
    cfg.segments = &.{ "model", "cost" };
    cfg.colors = &.{ null, 46 };
    cfg.color = 213;

    const out = try renderLine2(a, cfg, sl);
    defer a.free(out);
    try std.testing.expectEqualStrings("Opus 4.8  \x1b[38;5;46m$1.42\x1b[0m", out);
}
