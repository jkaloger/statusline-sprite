const std = @import("std");

/// Flattened view of the fields we care about from Claude's statusline JSON.
/// String fields borrow from the owning `ParsedStatusline` arena.
pub const Statusline = struct {
    model_display_name: []const u8,
    total_input_tokens: ?u64,
    used_percentage: ?f64,
    context_window_size: ?u64,
    total_cost_usd: ?f64 = null,
    total_lines_added: ?u64 = null,
    total_lines_removed: ?u64 = null,
    total_duration_ms: ?u64 = null,
    five_hour_used_percentage: ?f64 = null,
    seven_day_used_percentage: ?f64 = null,
    effort_level: ?[]const u8 = null,
    output_style_name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    fast_mode: ?bool = null,
    thinking_enabled: ?bool = null,
    vim_mode: ?[]const u8 = null,
    pr_number: ?u64 = null,
    pr_review_state: ?[]const u8 = null,
    agent_name: ?[]const u8 = null,
};

/// Owns the arena backing `value`. Caller must `deinit()` when done.
pub const ParsedStatusline = struct {
    parsed: std.json.Parsed(Raw),
    value: Statusline,

    pub fn deinit(self: ParsedStatusline) void {
        self.parsed.deinit();
    }
};

const Model = struct {
    display_name: []const u8 = "unknown",
};

const ContextWindow = struct {
    total_input_tokens: ?u64 = null,
    used_percentage: ?f64 = null,
    context_window_size: ?u64 = null,
};

const Cost = struct {
    total_cost_usd: ?f64 = null,
    total_lines_added: ?u64 = null,
    total_lines_removed: ?u64 = null,
    total_duration_ms: ?u64 = null,
};

/// One rolling rate-limit window (5h or 7d). `resets_at` is parsed for a later
/// task; v1 does not render it.
const RateWindow = struct {
    used_percentage: ?f64 = null,
    resets_at: ?i64 = null,
};

const RateLimits = struct {
    five_hour: RateWindow = .{},
    seven_day: RateWindow = .{},
};

const Effort = struct {
    level: ?[]const u8 = null,
};

const OutputStyle = struct {
    name: ?[]const u8 = null,
};

const Thinking = struct {
    enabled: ?bool = null,
};

const Vim = struct {
    mode: ?[]const u8 = null,
};

const Pr = struct {
    number: ?u64 = null,
    review_state: ?[]const u8 = null,
};

const AgentInfo = struct {
    name: ?[]const u8 = null,
};

const Raw = struct {
    model: Model = .{},
    context_window: ContextWindow = .{},
    cost: Cost = .{},
    rate_limits: RateLimits = .{},
    effort: Effort = .{},
    output_style: OutputStyle = .{},
    version: ?[]const u8 = null,
    fast_mode: ?bool = null,
    thinking: Thinking = .{},
    vim: Vim = .{},
    pr: Pr = .{},
    agent: AgentInfo = .{},
};

pub fn parse(allocator: std.mem.Allocator, json_bytes: []const u8) !ParsedStatusline {
    // .alloc_always so strings are copied into the arena and the result is
    // self-contained regardless of the lifetime of json_bytes.
    const parsed = try std.json.parseFromSlice(Raw, allocator, json_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return .{
        .parsed = parsed,
        .value = .{
            .model_display_name = parsed.value.model.display_name,
            .total_input_tokens = parsed.value.context_window.total_input_tokens,
            .used_percentage = parsed.value.context_window.used_percentage,
            .context_window_size = parsed.value.context_window.context_window_size,
            .total_cost_usd = parsed.value.cost.total_cost_usd,
            .total_lines_added = parsed.value.cost.total_lines_added,
            .total_lines_removed = parsed.value.cost.total_lines_removed,
            .total_duration_ms = parsed.value.cost.total_duration_ms,
            .five_hour_used_percentage = parsed.value.rate_limits.five_hour.used_percentage,
            .seven_day_used_percentage = parsed.value.rate_limits.seven_day.used_percentage,
            .effort_level = parsed.value.effort.level,
            .output_style_name = parsed.value.output_style.name,
            .version = parsed.value.version,
            .fast_mode = parsed.value.fast_mode,
            .thinking_enabled = parsed.value.thinking.enabled,
            .vim_mode = parsed.value.vim.mode,
            .pr_number = parsed.value.pr.number,
            .pr_review_state = parsed.value.pr.review_state,
            .agent_name = parsed.value.agent.name,
        },
    };
}

test "extracts nested model.display_name and ignores unrelated fields" {
    const json =
        \\{
        \\  "session_id": "abc-123",
        \\  "cwd": "/Users/dev/project",
        \\  "version": "1.2.3",
        \\  "workspace": { "current_dir": "/Users/dev/project", "project_dir": "/Users/dev" },
        \\  "model": { "id": "claude-opus-4", "display_name": "Opus 4.8" }
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqualStrings("Opus 4.8", result.value.model_display_name);
}

test "populates token optionals from nested context_window" {
    const json =
        \\{
        \\  "model": { "display_name": "Sonnet" },
        \\  "context_window": {
        \\    "total_input_tokens": 12345,
        \\    "total_output_tokens": 678,
        \\    "used_percentage": 42.5,
        \\    "context_window_size": 200000
        \\  }
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(?u64, 12345), result.value.total_input_tokens);
    try std.testing.expectEqual(@as(?f64, 42.5), result.value.used_percentage);
    try std.testing.expectEqual(@as(?u64, 200000), result.value.context_window_size);
}

test "integer used_percentage parses into f64" {
    const json =
        \\{
        \\  "model": { "display_name": "Sonnet" },
        \\  "context_window": { "used_percentage": 8, "context_window_size": 200000 }
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(?f64, 8.0), result.value.used_percentage);
}

test "top-level token fields are ignored, not picked up" {
    const json =
        \\{
        \\  "model": { "display_name": "Sonnet" },
        \\  "total_input_tokens": 12345,
        \\  "used_percentage": 42.5,
        \\  "context_window_size": 200000
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(?u64, null), result.value.total_input_tokens);
    try std.testing.expectEqual(@as(?f64, null), result.value.used_percentage);
    try std.testing.expectEqual(@as(?u64, null), result.value.context_window_size);
}

test "missing context_window yields null, not an error" {
    const json =
        \\{
        \\  "session_id": "xyz",
        \\  "model": { "display_name": "Haiku" }
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(?u64, null), result.value.total_input_tokens);
    try std.testing.expectEqual(@as(?f64, null), result.value.used_percentage);
    try std.testing.expectEqual(@as(?u64, null), result.value.context_window_size);
    try std.testing.expectEqualStrings("Haiku", result.value.model_display_name);
}

test "absent model uses default display name" {
    const json =
        \\{ "session_id": "no-model" }
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqualStrings("unknown", result.value.model_display_name);
}

test "populates cost fields from nested cost object" {
    const json =
        \\{
        \\  "model": { "display_name": "Sonnet" },
        \\  "cost": {
        \\    "total_cost_usd": 1.42,
        \\    "total_lines_added": 120,
        \\    "total_lines_removed": 45,
        \\    "total_duration_ms": 500000
        \\  }
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(?f64, 1.42), result.value.total_cost_usd);
    try std.testing.expectEqual(@as(?u64, 120), result.value.total_lines_added);
    try std.testing.expectEqual(@as(?u64, 45), result.value.total_lines_removed);
    try std.testing.expectEqual(@as(?u64, 500000), result.value.total_duration_ms);
}

test "top-level cost look-alike fields are ignored, not picked up" {
    const json =
        \\{
        \\  "model": { "display_name": "Sonnet" },
        \\  "total_cost_usd": 1.42,
        \\  "total_lines_added": 120,
        \\  "total_lines_removed": 45,
        \\  "total_duration_ms": 500000
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(?f64, null), result.value.total_cost_usd);
    try std.testing.expectEqual(@as(?u64, null), result.value.total_lines_added);
    try std.testing.expectEqual(@as(?u64, null), result.value.total_lines_removed);
    try std.testing.expectEqual(@as(?u64, null), result.value.total_duration_ms);
}

test "populates rate_limits fields from nested five_hour/seven_day windows" {
    const json =
        \\{
        \\  "model": { "display_name": "Sonnet" },
        \\  "rate_limits": {
        \\    "five_hour": { "used_percentage": 23.5, "resets_at": 1700000000 },
        \\    "seven_day": { "used_percentage": 61.0, "resets_at": 1700600000 }
        \\  }
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(?f64, 23.5), result.value.five_hour_used_percentage);
    try std.testing.expectEqual(@as(?f64, 61.0), result.value.seven_day_used_percentage);
}

test "populates effort, output_style, version, fast_mode, thinking, vim, pr, agent fields" {
    const json =
        \\{
        \\  "model": { "display_name": "Sonnet" },
        \\  "effort": { "level": "high" },
        \\  "output_style": { "name": "explanatory" },
        \\  "version": "1.2.3",
        \\  "fast_mode": true,
        \\  "thinking": { "enabled": true },
        \\  "vim": { "mode": "NORMAL" },
        \\  "pr": { "number": 42, "review_state": "approved" },
        \\  "agent": { "name": "reviewer" }
        \\}
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqualStrings("high", result.value.effort_level.?);
    try std.testing.expectEqualStrings("explanatory", result.value.output_style_name.?);
    try std.testing.expectEqualStrings("1.2.3", result.value.version.?);
    try std.testing.expectEqual(@as(?bool, true), result.value.fast_mode);
    try std.testing.expectEqual(@as(?bool, true), result.value.thinking_enabled);
    try std.testing.expectEqualStrings("NORMAL", result.value.vim_mode.?);
    try std.testing.expectEqual(@as(?u64, 42), result.value.pr_number);
    try std.testing.expectEqualStrings("approved", result.value.pr_review_state.?);
    try std.testing.expectEqualStrings("reviewer", result.value.agent_name.?);
}

test "new segment-data fields are null when their parent objects are absent" {
    const json =
        \\{ "model": { "display_name": "Sonnet" } }
    ;
    const result = try parse(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(?f64, null), result.value.total_cost_usd);
    try std.testing.expectEqual(@as(?u64, null), result.value.total_lines_added);
    try std.testing.expectEqual(@as(?u64, null), result.value.total_lines_removed);
    try std.testing.expectEqual(@as(?u64, null), result.value.total_duration_ms);
    try std.testing.expectEqual(@as(?f64, null), result.value.five_hour_used_percentage);
    try std.testing.expectEqual(@as(?f64, null), result.value.seven_day_used_percentage);
    try std.testing.expectEqual(@as(?[]const u8, null), result.value.effort_level);
    try std.testing.expectEqual(@as(?[]const u8, null), result.value.output_style_name);
    try std.testing.expectEqual(@as(?[]const u8, null), result.value.version);
    try std.testing.expectEqual(@as(?bool, null), result.value.fast_mode);
    try std.testing.expectEqual(@as(?bool, null), result.value.thinking_enabled);
    try std.testing.expectEqual(@as(?[]const u8, null), result.value.vim_mode);
    try std.testing.expectEqual(@as(?u64, null), result.value.pr_number);
    try std.testing.expectEqual(@as(?[]const u8, null), result.value.pr_review_state);
    try std.testing.expectEqual(@as(?[]const u8, null), result.value.agent_name);
}
