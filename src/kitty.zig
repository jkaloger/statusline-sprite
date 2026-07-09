const std = @import("std");

/// U+10EEEE — the Unicode placeholder codepoint kitty renders image cells into.
const placeholder_codepoint: u21 = 0x10EEEE;

/// Base64 characters per transmit chunk. Kitty requires <= 4096.
const default_chunk_size: usize = 4096;

/// kitty's rowcolumn-diacritics table (leading entries). Index = 0-based
/// row/column number; the codepoint is appended after the placeholder char.
const rowcolumn_diacritics = [_]u21{
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346,
    0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363,
    0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369, 0x036A, 0x036B, 0x036C,
    0x036D, 0x036E, 0x036F, 0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592,
    0x0593, 0x0594, 0x0595, 0x0597, 0x0598, 0x0599, 0x059C, 0x059D, 0x059E,
    0x059F, 0x05A0, 0x05A1, 0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4,
};

pub const TransmitOptions = struct {
    /// Base64 chars per APC chunk. Defaults to the protocol max (4096).
    chunk_size: usize = default_chunk_size,
};

fn appendApc(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    control: []const u8,
    payload: []const u8,
) !void {
    try out.appendSlice(allocator, "\x1b_G");
    try out.appendSlice(allocator, control);
    try out.append(allocator, ';');
    try out.appendSlice(allocator, payload);
    try out.appendSlice(allocator, "\x1b\\");
}

fn appendCodepoint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &buf);
    try out.appendSlice(allocator, buf[0..n]);
}

/// Transmit a PNG for `image_id` as one or more graphics APCs.
/// First chunk carries `a=t,f=100,i=<id>`; subsequent chunks carry only `m`.
pub fn transmit(
    allocator: std.mem.Allocator,
    image_id: u32,
    png_bytes: []const u8,
    opts: TransmitOptions,
) ![]u8 {
    const Encoder = std.base64.standard.Encoder;
    const b64 = try allocator.alloc(u8, Encoder.calcSize(png_bytes.len));
    defer allocator.free(b64);
    _ = Encoder.encode(b64, png_bytes);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var offset: usize = 0;
    var first = true;
    while (true) {
        const end = @min(offset + opts.chunk_size, b64.len);
        const chunk = b64[offset..end];
        const more = end < b64.len;

        const control = if (first)
            try std.fmt.allocPrint(allocator, "a=t,f=100,i={d},q=2,m={d}", .{ image_id, @intFromBool(more) })
        else
            try std.fmt.allocPrint(allocator, "m={d}", .{@intFromBool(more)});
        defer allocator.free(control);
        try appendApc(&out, allocator, control, chunk);

        first = false;
        offset = end;
        if (!more) break;
    }

    return out.toOwnedSlice(allocator);
}

/// Delete image `image_id` and its placements: `a=d,d=i,i=<id>`. No payload.
/// `q=2` suppresses the terminal's OK/error ACK (which would otherwise leak
/// onto the tty and corrupt the shell).
pub fn delete(allocator: std.mem.Allocator, image_id: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b_Ga=d,d=i,i={d},q=2\x1b\\", .{image_id});
}

/// Unicode-placeholder virtual placement: `a=p,U=1,i=<id>,c=<cols>,r=<rows>`.
pub fn virtualPlacement(
    allocator: std.mem.Allocator,
    image_id: u32,
    rows: u32,
    cols: u32,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "\x1b_Ga=p,U=1,i={d},c={d},r={d},q=2\x1b\\",
        .{ image_id, cols, rows },
    );
}

/// Build the printable placeholder-cell grid. Each cell is U+10EEEE followed by
/// the row then column diacritic. The image id travels via a 256-color fg SGR
/// (`38;5;<id>`) set at the start of each row and reset (`0m`) at its end. Rows
/// are separated by a single '\n' with NO trailing newline.
///
/// 256-color (not truecolor) because Claude Code's statusline renderer does not
/// preserve a `38;2;r;g;b` SGR intact, which corrupts the id kitty reads from
/// the cell -- so `image_id` must be <= 255.
pub fn placeholderGrid(
    allocator: std.mem.Allocator,
    image_id: u32,
    rows: u32,
    cols: u32,
) ![]u8 {
    if (rows > rowcolumn_diacritics.len or cols > rowcolumn_diacritics.len)
        return error.DiacriticIndexOutOfRange;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        if (r > 0) try out.append(allocator, '\n');

        const fg = try std.fmt.allocPrint(allocator, "\x1b[38;5;{d}m", .{image_id & 0xFF});
        defer allocator.free(fg);
        try out.appendSlice(allocator, fg);

        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            try appendCodepoint(&out, allocator, placeholder_codepoint);
            try appendCodepoint(&out, allocator, rowcolumn_diacritics[r]);
            try appendCodepoint(&out, allocator, rowcolumn_diacritics[c]);
        }

        try out.appendSlice(allocator, "\x1b[0m");
    }

    return out.toOwnedSlice(allocator);
}

/// Wrap a graphics APC payload for tmux passthrough: prefix `ESC P tmux ;`,
/// double every ESC byte in `payload`, suffix `ESC \`.
pub fn wrapTmux(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\x1bPtmux;");
    for (payload) |b| {
        if (b == 0x1b) try out.append(allocator, 0x1b);
        try out.append(allocator, b);
    }
    try out.appendSlice(allocator, "\x1b\\");

    return out.toOwnedSlice(allocator);
}

test "transmit: single small payload is one APC with a=t,f=100,i,m=0" {
    const a = std.testing.allocator;
    const out = try transmit(a, 42, "hi", .{});
    defer a.free(out);

    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b_G"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b\\"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b_G"));
    try std.testing.expect(std.mem.indexOf(u8, out, "a=t") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "f=100") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "i=42") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "m=0") != null);
    // base64 of "hi" is "aGk="
    try std.testing.expect(std.mem.indexOf(u8, out, "aGk=") != null);
}

test "transmit: large payload chunks, flags m, and round-trips" {
    const a = std.testing.allocator;
    var png: [5000]u8 = undefined;
    for (&png, 0..) |*b, i| b.* = @intCast(i % 251);

    const out = try transmit(a, 7, &png, .{});
    defer a.free(out);

    var payloads: std.ArrayList(u8) = .empty;
    defer payloads.deinit(a);

    var count: usize = 0;
    var first_control: []const u8 = "";
    var last_control: []const u8 = "";
    var it = std.mem.splitSequence(u8, out, "\x1b_G");
    _ = it.next(); // leading empty segment
    while (it.next()) |seg| {
        count += 1;
        const body = seg[0 .. seg.len - 2]; // strip trailing ESC \
        const semi = std.mem.indexOfScalar(u8, body, ';').?;
        const control = body[0..semi];
        if (count == 1) first_control = control;
        last_control = control;
        try payloads.appendSlice(a, body[semi + 1 ..]);
    }

    try std.testing.expect(count >= 2);
    try std.testing.expect(std.mem.indexOf(u8, first_control, "m=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_control, "a=t") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_control, "f=100") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_control, "i=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, last_control, "m=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, last_control, "a=t") == null);

    const Decoder = std.base64.standard.Decoder;
    const decoded = try a.alloc(u8, try Decoder.calcSizeForSlice(payloads.items));
    defer a.free(decoded);
    try Decoder.decode(decoded, payloads.items);
    try std.testing.expectEqualSlices(u8, &png, decoded);
}

test "delete: contains a=d,d=i,i" {
    const a = std.testing.allocator;
    const out = try delete(a, 9);
    defer a.free(out);

    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b_G"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b\\"));
    try std.testing.expect(std.mem.indexOf(u8, out, "a=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "d=i") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "i=9") != null);
}

test "virtualPlacement: contains a=p,U=1,i,c,r" {
    const a = std.testing.allocator;
    const out = try virtualPlacement(a, 3, 3, 6);
    defer a.free(out);

    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b_G"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b\\"));
    inline for (.{ "a=p", "U=1", "i=3", "c=6", "r=3" }) |k|
        try std.testing.expect(std.mem.indexOf(u8, out, k) != null);
}

test "placeholderGrid: cell count, diacritics, fg SGR, separators" {
    const a = std.testing.allocator;
    const id: u32 = 103;
    const out = try placeholderGrid(a, id, 3, 6);
    defer a.free(out);

    var ph: [4]u8 = undefined;
    const phn = try std.unicode.utf8Encode(placeholder_codepoint, &ph);
    try std.testing.expectEqual(@as(usize, 18), std.mem.count(u8, out, ph[0..phn]));

    // 3 rows -> 2 separators, no trailing newline
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));

    // fg = 256-color id, plus full reset
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;5;103m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[0m") != null);

    // row0 col0 -> diacritics 0x0305, 0x0305
    const cell00 = try cellSlice(a, 0x0305, 0x0305);
    defer a.free(cell00);
    try std.testing.expect(std.mem.indexOf(u8, out, cell00) != null);
    // row1 col2 -> diacritics 0x030D, 0x030E
    const cell12 = try cellSlice(a, 0x030D, 0x030E);
    defer a.free(cell12);
    try std.testing.expect(std.mem.indexOf(u8, out, cell12) != null);
}

fn cellSlice(a: std.mem.Allocator, row_cp: u21, col_cp: u21) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try appendCodepoint(&out, a, placeholder_codepoint);
    try appendCodepoint(&out, a, row_cp);
    try appendCodepoint(&out, a, col_cp);
    return out.toOwnedSlice(a);
}

test "placeholderGrid: index beyond table errors" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.DiacriticIndexOutOfRange, placeholderGrid(a, 1, 1, rowcolumn_diacritics.len + 1));
}

test "wrapTmux: prefixes passthrough and doubles ESC" {
    const a = std.testing.allocator;
    const payload = "\x1b_Ga=t;x\x1b\\";
    const out = try wrapTmux(a, payload);
    defer a.free(out);

    try std.testing.expect(std.mem.startsWith(u8, out, "\x1bPtmux;"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b\\"));

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(a);
    try expected.appendSlice(a, "\x1bPtmux;");
    for (payload) |b| {
        if (b == 0x1b) try expected.append(a, 0x1b);
        try expected.append(a, b);
    }
    try expected.appendSlice(a, "\x1b\\");
    try std.testing.expectEqualSlices(u8, expected.items, out);
}
