//! Streams a JSON string, retaining at most one UTF-8 sequence between writes.
//!
//! NOTE: This was AI generated. There might be a lot of performance or correctnes gains here.
const std = @import("std");
const JsonString = @This();

out: *std.Io.Writer,
writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
pending: [4]u8 = undefined,
length: usize = 0,
expected: u8 = 0,

pub fn begin(out: *std.Io.Writer) !JsonString {
    try out.writeByte('"');
    return .{ .out = out };
}

pub fn write(value: []const u8, out: *std.Io.Writer) !void {
    var escaped = try begin(out);
    try escaped.writer.writeAll(value);
    try escaped.finish();
}

/// Completes any truncated sequence and closes the string.
pub fn finish(escaped: *JsonString) !void {
    try escaped.flushPendingEscaped();
    try escaped.out.writeByte('"');
}

fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const escaped: *JsonString = @fieldParentPtr("writer", writer);
    var consumed: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        try escaped.feed(bytes);
        consumed += bytes.len;
    }
    for (0..splat) |_| try escaped.feed(data[data.len - 1]);
    return consumed + data[data.len - 1].len * splat;
}

fn feed(escaped: *JsonString, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (escaped.length > 0) {
            if (byte & 0xc0 != 0x80) {
                try escaped.flushPendingEscaped();
                continue;
            }
            escaped.pending[escaped.length] = byte;
            escaped.length += 1;
            if (escaped.length == escaped.expected) {
                const sequence = escaped.pending[0..escaped.length];
                if (std.unicode.utf8ValidateSlice(sequence)) {
                    try std.json.Stringify.encodeJsonStringChars(sequence, .{}, escaped.out);
                    escaped.length = 0;
                } else try escaped.flushPendingEscaped();
            }
            index += 1;
        } else if (byte < 0x80) {
            const start = index;
            while (index < bytes.len and bytes[index] < 0x80) : (index += 1) {}
            try std.json.Stringify.encodeJsonStringChars(bytes[start..index], .{}, escaped.out);
        } else {
            escaped.expected = std.unicode.utf8ByteSequenceLength(byte) catch 0;
            escaped.pending[0] = byte;
            escaped.length = 1;
            if (escaped.expected == 0) try escaped.flushPendingEscaped();
            index += 1;
        }
    }
}

// Escape every byte of the pending invalid sequence as U+00XX, not just the
// offending byte. This is display text, not a lossless binary encoding.
fn flushPendingEscaped(escaped: *JsonString) !void {
    for (escaped.pending[0..escaped.length]) |byte| try escaped.out.print("\\u00{x:0>2}", .{byte});
    escaped.length = 0;
}

test "escaping is independent of chunk boundaries" {
    const input = "a\"\\\n\x00é€😀\xff\xe2x\xed\xa0\x80\xf0";
    const expected = "\"a\\\"\\\\\\n\\u0000é€😀\\u00ff\\u00e2x\\u00ed\\u00a0\\u0080\\u00f0\"";
    for (0..input.len + 1) |split| {
        var buffer: [256]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        var escaped = try begin(&out);
        try escaped.writer.writeAll(input[0..split]);
        try escaped.writer.writeAll(input[split..]);
        try escaped.finish();
        try std.testing.expectEqualStrings(expected, out.buffered());
    }
}
