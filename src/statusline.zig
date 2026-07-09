const std = @import("std");

/// Flattened view of the fields we care about from Claude's statusline JSON.
/// String fields borrow from the owning `ParsedStatusline` arena.
pub const Statusline = struct {
    model_display_name: []const u8,
    total_input_tokens: ?u64,
    used_percentage: ?f64,
    context_window_size: ?u64,
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

const Raw = struct {
    model: Model = .{},
    total_input_tokens: ?u64 = null,
    used_percentage: ?f64 = null,
    context_window_size: ?u64 = null,
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
            .total_input_tokens = parsed.value.total_input_tokens,
            .used_percentage = parsed.value.used_percentage,
            .context_window_size = parsed.value.context_window_size,
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

test "populates token optionals when present" {
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

    try std.testing.expectEqual(@as(?u64, 12345), result.value.total_input_tokens);
    try std.testing.expectEqual(@as(?f64, 42.5), result.value.used_percentage);
    try std.testing.expectEqual(@as(?u64, 200000), result.value.context_window_size);
}

test "missing token fields yield null, not an error" {
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
