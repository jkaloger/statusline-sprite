const std = @import("std");
const Statusline = @import("statusline.zig").Statusline;

/// Maps a token count to a damage-tier index in `[0, tiers-1]`.
/// Formula: floor(tokens / scale_tokens * tiers), clamped to the top tier.
/// Integer math avoids float precision loss; the product is widened to u128
/// so `tokens * tiers` cannot overflow.
pub fn selectTier(tokens: u64, scale_tokens: u64, tiers: u32) u32 {
    if (tiers == 0) return 0;
    if (scale_tokens == 0) return tiers - 1;

    const product: u128 = @as(u128, tokens) * @as(u128, tiers);
    const raw: u128 = product / @as(u128, scale_tokens);
    return @intCast(@min(raw, tiers - 1));
}

/// Derives the token count from a Statusline, preferring the reported total and
/// falling back to percentage x window when the total is absent.
pub fn tokensFrom(sl: Statusline) u64 {
    if (sl.total_input_tokens) |total| return total;

    if (sl.used_percentage) |pct| {
        if (sl.context_window_size) |window| {
            const tokens = pct / 100.0 * @as(f64, @floatFromInt(window));
            if (tokens <= 0) return 0;
            return @intFromFloat(@round(tokens));
        }
    }

    return 0;
}

test "selectTier: zero tokens maps to tier 0" {
    try std.testing.expectEqual(@as(u32, 0), selectTier(0, 200000, 5));
}

test "selectTier: tokens at or above scale map to top tier" {
    try std.testing.expectEqual(@as(u32, 4), selectTier(200000, 200000, 5));
    try std.testing.expectEqual(@as(u32, 4), selectTier(500000, 200000, 5));
}

test "selectTier: boundary crossing increments the tier" {
    // scale 200000, 5 tiers => each tier spans 40000 tokens.
    try std.testing.expectEqual(@as(u32, 0), selectTier(39999, 200000, 5));
    try std.testing.expectEqual(@as(u32, 1), selectTier(40000, 200000, 5));
    try std.testing.expectEqual(@as(u32, 1), selectTier(40001, 200000, 5));
    try std.testing.expectEqual(@as(u32, 4), selectTier(160000, 200000, 5));
    try std.testing.expectEqual(@as(u32, 4), selectTier(199999, 200000, 5));
}

test "selectTier: guard inputs do not crash" {
    try std.testing.expectEqual(@as(u32, 0), selectTier(123456, 200000, 0));
    try std.testing.expectEqual(@as(u32, 4), selectTier(123456, 0, 5));
    try std.testing.expectEqual(@as(u32, 0), selectTier(0, 0, 0));
}

test "tokensFrom: prefers total_input_tokens" {
    const sl = Statusline{
        .model_display_name = "x",
        .total_input_tokens = 12345,
        .used_percentage = 90.0,
        .context_window_size = 200000,
    };
    try std.testing.expectEqual(@as(u64, 12345), tokensFrom(sl));
}

test "tokensFrom: falls back to percentage x window" {
    const sl = Statusline{
        .model_display_name = "x",
        .total_input_tokens = null,
        .used_percentage = 50.0,
        .context_window_size = 200000,
    };
    try std.testing.expectEqual(@as(u64, 100000), tokensFrom(sl));
}

test "tokensFrom: all null yields 0" {
    const sl = Statusline{
        .model_display_name = "x",
        .total_input_tokens = null,
        .used_percentage = null,
        .context_window_size = null,
    };
    try std.testing.expectEqual(@as(u64, 0), tokensFrom(sl));
}
