//! Run information shared by the text and JSON renderers. Slices live in the run arena.
const std = @import("std");
const excerpt = @import("excerpt.zig");
const JsonString = @import("JsonString.zig");
const Output = @This();

pub const Style = enum { text, json };

/// Output file names; each matches the `Output` field describing it.
pub const stream_names = [_][]const u8{ "stdout", "stderr" };

/// Identifies one of the output files; the saved status stores it as the tag plus one.
pub const StreamType = enum(u8) { stdout, stderr };

/// Absolute run directory path, without a trailing separator.
path: []const u8,
stdout: Stream,
stderr: Stream,
exit_code: u8,
timed_out: bool = false,
/// The file whose size limit killed the command, if any.
oversized: ?StreamType = null,
/// Time from spawn until the command was reaped.
duration: std.Io.Duration = .zero,

pub const Stream = struct {
    size: u64 = 0,
    lines: excerpt.Excerpt = .{},
};

/// Saved as the exit code, the timeout flag, the oversized stream (zero for
/// none), and the duration in nanoseconds as a little-endian `u64`.
pub const Status = struct {
    exit_code: u8,
    timed_out: bool,
    oversized: ?StreamType = null,
    duration: std.Io.Duration = .zero,

    const filename = "status";
    const size = 3 + @sizeOf(u64);
    const stream_count = @typeInfo(StreamType).@"enum".fields.len;

    pub fn read(io: std.Io, directory: std.Io.Dir) !Status {
        const file = try directory.openFile(io, filename, .{});
        defer file.close(io);

        var bytes: [size + 1]u8 = undefined;
        const length = try file.readPositionalAll(io, &bytes, 0);
        if (length != size or bytes[1] > 1 or bytes[2] > stream_count) return error.InvalidRunStatus;

        return .{
            .exit_code = bytes[0],
            .timed_out = bytes[1] == 1,
            .oversized = if (bytes[2] == 0) null else @enumFromInt(bytes[2] - 1),
            .duration = .fromNanoseconds(std.mem.readInt(u64, bytes[3..size], .little)),
        };
    }

    pub fn save(status: Status, io: std.Io, directory: std.Io.Dir) !void {
        var file = try directory.createFileAtomic(io, filename, .{ .replace = true });
        defer file.deinit(io);

        var bytes: [size]u8 = undefined;
        bytes[0] = status.exit_code;
        bytes[1] = @intFromBool(status.timed_out);
        bytes[2] = if (status.oversized) |stream| @intFromEnum(stream) + 1 else 0;
        // A negative duration cannot occur with a monotonic clock; clamp defensively.
        const nanoseconds: u64 = @intCast(std.math.clamp(status.duration.toNanoseconds(), 0, std.math.maxInt(u64)));
        std.mem.writeInt(u64, bytes[3..size], nanoseconds, .little);
        try file.file.writeStreamingAll(io, &bytes);
        try file.replace(io);
    }

    /// Truncates any previous status so an interrupted run is not mistaken for a finished one.
    pub fn clear(io: std.Io, directory: std.Io.Dir) !void {
        const file = try directory.createFile(io, filename, .{});
        file.close(io);
    }
};

/// Rebuild the report from the run's files using this invocation's excerpt options.
pub fn read(
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
    stdout_lines: excerpt.Excerpt,
    stderr_lines: excerpt.Excerpt,
) !Output {
    const status = try Status.read(io, directory);
    var output: Output = .{
        .path = path,
        .stdout = .{ .lines = stdout_lines },
        .stderr = .{ .lines = stderr_lines },
        .exit_code = status.exit_code,
        .timed_out = status.timed_out,
        .oversized = status.oversized,
        .duration = status.duration,
    };

    inline for (stream_names) |name| {
        const file = try directory.openFile(io, name, .{});
        defer file.close(io);

        @field(output, name).size = (try file.stat(io)).size;
    }

    return output;
}

pub fn writePaths(path: []const u8, out: *std.Io.Writer) !void {
    inline for (stream_names) |name| {
        try out.print(name ++ ": {s}{c}" ++ name ++ "\n", .{ path, std.fs.path.sep });
    }
}

pub fn writeSize(size: u64, out: *std.Io.Writer) !void {
    if (size < 1024) return out.print("{d} B", .{size});

    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    var unit_idx: usize = 0;
    var n = size;
    while (unit_idx + 1 < units.len and n >= 1024 * 1024) : (unit_idx += 1) {
        n /= 1024;
    }
    const rem = (n % 1024) * 10 / 1024;
    return out.print("{d}.{d} {s}", .{ n / 1024, rem, units[unit_idx] });
}

/// Writes a complete report. Early async paths are printed separately.
pub fn writeReport(output: Output, io: std.Io, directory: std.Io.Dir, style: Style, out: *std.Io.Writer) !void {
    switch (style) {
        .text => try output.writeText(io, directory, out),
        .json => try output.writeJson(io, directory, out),
    }
}

fn writeText(output: Output, io: std.Io, directory: std.Io.Dir, out: *std.Io.Writer) !void {
    try out.print("[fb exit={d}", .{output.exit_code});
    if (output.timed_out) try out.writeAll(" timed_out");
    if (output.oversized) |stream| try out.print(" oversized={s}", .{@tagName(stream)});
    if (output.duration.toNanoseconds() > 0) try out.print(" time={f}", .{output.duration});
    try out.writeAll("]\n");

    inline for (stream_names) |name| {
        const stream = @field(output, name);
        try out.print(name ++ " (", .{});
        try writeSize(stream.size, out);
        try out.print("): {s}{c}" ++ name ++ "\n", .{ output.path, std.fs.path.sep });
    }

    inline for (stream_names) |name| {
        const stream = @field(output, name);
        if (!stream.lines.isEmpty()) {
            const file = try directory.openFile(io, name, .{});
            defer file.close(io);

            try excerpt.write(io, file, stream.lines, name, out);
        }
    }
}

fn writeJson(output: Output, io: std.Io, directory: std.Io.Dir, out: *std.Io.Writer) !void {
    var json: std.json.Stringify = .{ .writer = out };
    try json.beginObject();

    inline for (stream_names) |name| {
        const stream = @field(output, name);
        try json.objectField(name);
        try json.beginObject();

        try json.objectField("path");
        try json.beginWriteRaw();
        var path = try JsonString.begin(out);
        try path.writer.print("{s}{c}" ++ name, .{ output.path, std.fs.path.sep });
        try path.finish();
        json.endWriteRaw();

        try json.objectField("size");
        try json.write(stream.size);

        if (!stream.lines.isEmpty()) {
            const file = try directory.openFile(io, name, .{});
            defer file.close(io);

            inline for (.{ "head", "tail" }) |kind| {
                if (@field(stream.lines, kind)) |count| {
                    try json.objectField(kind);
                    try json.beginWriteRaw();
                    var escaped = try JsonString.begin(out);
                    try @field(excerpt, kind)(io, file, count, &escaped.writer);
                    try escaped.finish();
                    json.endWriteRaw();
                }
            }
        }

        try json.endObject();
    }

    try json.objectField("exit_code");
    try json.write(output.exit_code);
    try json.objectField("timed_out");
    try json.write(output.timed_out);
    try json.objectField("oversized");
    try json.write(if (output.oversized) |stream| @tagName(stream) else null);
    try json.objectField("duration_ns");
    try json.write(output.duration.toNanoseconds());
    try json.endObject();
    try out.writeByte('\n');
}

test "writeSize" {
    const t = std.testing;
    const cases = [_]struct { size: u64, expected: []const u8 }{
        .{ .size = 0, .expected = "0 B" },
        .{ .size = 1, .expected = "1 B" },
        .{ .size = 340, .expected = "340 B" },
        .{ .size = 1023, .expected = "1023 B" },
        .{ .size = 1024, .expected = "1.0 KB" },
        .{ .size = 1536, .expected = "1.5 KB" },
        .{ .size = 4520, .expected = "4.4 KB" },
        .{ .size = 1048575, .expected = "1023.9 KB" },
        .{ .size = 1048576, .expected = "1.0 MB" },
        .{ .size = 1572864, .expected = "1.5 MB" },
    };

    for (cases) |c| {
        var out: std.Io.Writer.Allocating = .init(t.allocator);
        defer out.deinit();
        try writeSize(c.size, &out.writer);
        try t.expectEqualStrings(c.expected, out.written());
    }
}

test "writeText formatting" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "stdout", .data = "line 1\nline 2\nline 3\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stderr", .data = "warn 1\n" });

    const output: Output = .{
        .path = "/test/run",
        .stdout = .{ .size = 21, .lines = .{ .tail = 2 } },
        .stderr = .{ .size = 7, .lines = .{ .tail = 1 } },
        .exit_code = 0,
        .timed_out = false,
        .duration = .fromNanoseconds(std.time.ns_per_s + 234 * std.time.ns_per_ms),
    };

    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try output.writeText(io, tmp.dir, &out.writer);

    var expected_buf: [512]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf,
        \\[fb exit=0 time=1.234s]
        \\stdout (21 B): /test/run{c}stdout
        \\stderr (7 B): /test/run{c}stderr
        \\
        \\>>> stdout tail 2
        \\line 2
        \\line 3
        \\<<<
        \\
        \\>>> stderr tail 1
        \\warn 1
        \\<<<
        \\
    , .{ std.fs.path.sep, std.fs.path.sep });
    try t.expectEqualStrings(expected, out.written());
}

test "writeText with timeout" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "stdout", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stderr", .data = "" });

    const output: Output = .{
        .path = "/test/run",
        .stdout = .{ .size = 0 },
        .stderr = .{ .size = 0 },
        .exit_code = 124,
        .timed_out = true,
        .duration = .fromNanoseconds(30 * std.time.ns_per_s),
    };

    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try output.writeText(io, tmp.dir, &out.writer);

    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf,
        \\[fb exit=124 timed_out time=30s]
        \\stdout (0 B): /test/run{c}stdout
        \\stderr (0 B): /test/run{c}stderr
        \\
    , .{ std.fs.path.sep, std.fs.path.sep });
    try t.expectEqualStrings(expected, out.written());
}

test {
    _ = excerpt;
    _ = JsonString;
}

test "writeText with oversized output" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "stdout", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stderr", .data = "" });

    const output: Output = .{
        .path = "/test/run",
        .stdout = .{ .size = 268435457 },
        .stderr = .{ .size = 0 },
        .exit_code = 153,
        .oversized = .stdout,
        .duration = .fromNanoseconds(2 * std.time.ns_per_s),
    };

    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try output.writeText(io, tmp.dir, &out.writer);

    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf,
        \\[fb exit=153 oversized=stdout time=2s]
        \\stdout (256.0 MB): /test/run{c}stdout
        \\stderr (0 B): /test/run{c}stderr
        \\
    , .{ std.fs.path.sep, std.fs.path.sep });
    try t.expectEqualStrings(expected, out.written());
}

test "status round-trips the oversized stream" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]?StreamType{ null, .stdout, .stderr };
    for (cases) |oversized| {
        const saved: Status = .{ .exit_code = 153, .timed_out = false, .oversized = oversized };
        try saved.save(io, tmp.dir);
        try t.expectEqual(saved, try Status.read(io, tmp.dir));
    }

    try tmp.dir.writeFile(io, .{ .sub_path = "status", .data = &([_]u8{ 0, 0, 3 } ++ [_]u8{0} ** 8) });
    try t.expectError(error.InvalidRunStatus, Status.read(io, tmp.dir));
}
