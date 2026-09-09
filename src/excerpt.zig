//! Prints the first or last lines of an output file after the command exits.
const std = @import("std");

pub const Excerpt = struct {
    head: ?u32 = null,
    tail: ?u32 = null,

    pub fn isEmpty(excerpt: Excerpt) bool {
        return excerpt.head == null and excerpt.tail == null;
    }
};

const chunk_size = 4096;

/// Writes the requested head and tail of `file`, each under a labeled marker.
pub fn write(io: std.Io, file: std.Io.File, excerpt: Excerpt, label: []const u8, out: *std.Io.Writer) !void {
    if (excerpt.head) |count| {
        try out.print("--- {s} head (n = {d}) ---\n", .{ label, count });
        try head(io, file, count, out);
    }
    if (excerpt.tail) |count| {
        try out.print("--- {s} tail (n = {d}) ---\n", .{ label, count });
        try tail(io, file, count, out);
    }
}

fn head(io: std.Io, file: std.Io.File, count: u32, out: *std.Io.Writer) !void {
    var buffer: [chunk_size]u8 = undefined;
    var offset: u64 = 0;
    var remaining = count;
    var last: u8 = '\n';

    while (remaining > 0) {
        const read = try file.readPositionalAll(io, &buffer, offset);
        if (read == 0) break;
        const chunk = buffer[0..read];

        var written: usize = 0;
        while (remaining > 0) {
            const newline = std.mem.indexOfScalarPos(u8, chunk, written, '\n') orelse break;
            written = newline + 1;
            remaining -= 1;
        }
        if (remaining > 0) written = chunk.len;

        try out.writeAll(chunk[0..written]);
        last = chunk[written - 1];
        offset += written;
    }
    if (last != '\n') try out.writeByte('\n');
}

fn tail(io: std.Io, file: std.Io.File, count: u32, out: *std.Io.Writer) !void {
    var buffer: [chunk_size]u8 = undefined;
    const size = (try file.stat(io)).size;
    if (size == 0) return;

    // Scan backwards for the newline preceding the last `count` lines. A final
    // newline only terminates the last line and is not counted.
    var end = size;
    var remaining: u64 = count;
    var start: u64 = 0;
    scan: while (end > 0) {
        const length: usize = @intCast(@min(end, chunk_size));
        end -= length;
        const read = try file.readPositionalAll(io, buffer[0..length], end);
        std.debug.assert(read == length);

        var index = length;
        while (index > 0) {
            index -= 1;
            if (buffer[index] != '\n') continue;
            if (end + index + 1 == size) continue;
            remaining -= 1;
            if (remaining == 0) {
                start = end + index + 1;
                break :scan;
            }
        }
    }

    var last: u8 = '\n';
    var offset = start;
    while (offset < size) {
        const read = try file.readPositionalAll(io, &buffer, offset);
        if (read == 0) break;
        try out.writeAll(buffer[0..read]);
        last = buffer[read - 1];
        offset += read;
    }
    if (last != '\n') try out.writeByte('\n');
}

fn expect(data: []const u8, excerpt: Excerpt, expected: []const u8) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = data });
    const file = try tmp.dir.openFile(io, "f", .{});
    defer file.close(io);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(io, file, excerpt, "x", &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "head" {
    try expect("a\nb\nc\n", .{ .head = 2 }, "--- x head (n = 2) ---\na\nb\n");
    try expect("a\nb\nc\n", .{ .head = 5 }, "--- x head (n = 5) ---\na\nb\nc\n");
    try expect("a\nb", .{ .head = 5 }, "--- x head (n = 5) ---\na\nb\n");
    try expect("", .{ .head = 1 }, "--- x head (n = 1) ---\n");
}

test "tail" {
    try expect("a\nb\nc\n", .{ .tail = 2 }, "--- x tail (n = 2) ---\nb\nc\n");
    try expect("a\nb\nc", .{ .tail = 2 }, "--- x tail (n = 2) ---\nb\nc\n");
    try expect("a\nb\nc\n", .{ .tail = 5 }, "--- x tail (n = 5) ---\na\nb\nc\n");
    try expect("", .{ .tail = 1 }, "--- x tail (n = 1) ---\n");
    try expect("a\nb\nc\n", .{ .head = 1, .tail = 1 }, "--- x head (n = 1) ---\na\n--- x tail (n = 1) ---\nc\n");
}

test "tail across chunks" {
    const line = "0123456789" ** 10 ++ "\n";
    const data = line ** 100;
    try expect(data, .{ .tail = 3 }, "--- x tail (n = 3) ---\n" ++ line ** 3);
    try expect(data, .{ .head = 3 }, "--- x head (n = 3) ---\n" ++ line ** 3);
}
