//! Run information shared by the text and JSON renderers. Slices live in the run arena.
const std = @import("std");
const excerpt = @import("excerpt.zig");
const JsonString = @import("JsonString.zig");
const Output = @This();

pub const Style = enum { text, json };

/// Output file names; each matches the `Output` field describing it.
pub const stream_names = [_][]const u8{ "stdout", "stderr" };

/// Absolute run directory path, without a trailing separator.
path: []const u8,
stdout: Stream,
stderr: Stream,
exit_code: u8,
timed_out: bool = false,

pub const Stream = struct {
    size: u64 = 0,
    lines: excerpt.Excerpt = .{},
};

pub const Status = struct {
    exit_code: u8,
    timed_out: bool,

    const filename = "status";

    pub fn read(io: std.Io, directory: std.Io.Dir) !Status {
        const file = try directory.openFile(io, filename, .{});
        defer file.close(io);

        var bytes: [3]u8 = undefined;
        const length = try file.readPositionalAll(io, &bytes, 0);
        if (length != 2 or bytes[1] > 1) return error.InvalidRunStatus;

        return .{ .exit_code = bytes[0], .timed_out = bytes[1] == 1 };
    }

    pub fn save(status: Status, io: std.Io, directory: std.Io.Dir) !void {
        var file = try directory.createFileAtomic(io, filename, .{ .replace = true });
        defer file.deinit(io);

        try file.file.writeStreamingAll(io, &.{ status.exit_code, @intFromBool(status.timed_out) });
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

/// Writes a complete report. Early async paths are printed separately.
pub fn writeReport(output: Output, io: std.Io, directory: std.Io.Dir, style: Style, out: *std.Io.Writer) !void {
    switch (style) {
        .text => try output.writeText(io, directory, out),
        .json => try output.writeJson(io, directory, out),
    }
}

fn hasExcerpt(output: Output) bool {
    return !output.stdout.lines.isEmpty() or !output.stderr.lines.isEmpty();
}

fn writeText(output: Output, io: std.Io, directory: std.Io.Dir, out: *std.Io.Writer) !void {
    inline for (stream_names) |name| {
        try out.print(name ++ " size: {d} bytes\n", .{@field(output, name).size});
    }

    inline for (stream_names) |name| {
        const stream = @field(output, name);
        if (!stream.lines.isEmpty()) {
            const file = try directory.openFile(io, name, .{});
            defer file.close(io);

            try excerpt.write(io, file, stream.lines, name, out);
        }
    }
    if (output.hasExcerpt()) try out.writeAll("--- end ---\n");

    try out.print("exit code: {d}\n", .{output.exit_code});
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
    try json.endObject();
    try out.writeByte('\n');
}

test {
    _ = excerpt;
    _ = JsonString;
}
