//! Run information shared by the text and JSON renderers. Slices live in the run arena.
const std = @import("std");
const excerpt = @import("excerpt.zig");
const JsonString = @import("JsonString.zig");
const Output = @This();

pub const Style = enum { text, json };

pub const stdout_filename = "stdout";
pub const stderr_filename = "stderr";

stdout: Stream,
stderr: Stream,
exit_code: u8,
timed_out: bool = false,

pub const Stream = struct {
    /// Shared output directory path, without a trailing separator.
    path: []const u8,
    filename: []const u8,
    size: u64 = 0,
    lines: excerpt.Excerpt = .{},
};

pub const Status = struct {
    exit_code: u8,
    timed_out: bool,

    pub fn read(io: std.Io, directory: std.Io.Dir) !Status {
        const status_file = try directory.openFile(io, "status", .{});
        defer status_file.close(io);
        var status: [3]u8 = undefined;
        if (try status_file.readPositionalAll(io, &status, 0) != 2 or status[1] > 1) return error.InvalidRunStatus;
        return .{ .exit_code = status[0], .timed_out = status[1] == 1 };
    }

    pub fn save(status: Status, io: std.Io, directory: std.Io.Dir) !void {
        var file = try directory.createFileAtomic(io, "status", .{ .replace = true });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, &.{ status.exit_code, @intFromBool(status.timed_out) });
        try file.replace(io);
    }
};

/// Rebuild the report from the run's files using this invocation's excerpt options.
pub fn read(io: std.Io, directory: std.Io.Dir, path: []const u8, stdout_lines: excerpt.Excerpt, stderr_lines: excerpt.Excerpt) !Output {
    const status = try Status.read(io, directory);
    var output: Output = .{
        .stdout = .{ .path = path, .filename = stdout_filename, .lines = stdout_lines },
        .stderr = .{ .path = path, .filename = stderr_filename, .lines = stderr_lines },
        .exit_code = status.exit_code,
        .timed_out = status.timed_out,
    };
    inline for (.{ "stdout", "stderr" }) |name| {
        const stream = &@field(output, name);
        const file = try directory.openFile(io, stream.filename, .{});
        defer file.close(io);
        stream.size = (try file.stat(io)).size;
    }
    return output;
}

pub fn writePaths(stdout: Stream, stderr: Stream, out: *std.Io.Writer) !void {
    try out.print("stdout: {s}{c}{s}\nstderr: {s}{c}{s}\n", .{
        stdout.path, std.fs.path.sep, stdout.filename,
        stderr.path, std.fs.path.sep, stderr.filename,
    });
}

/// Writes a complete report. Early async paths are printed separately.
pub fn writeReport(output: Output, io: std.Io, directory: std.Io.Dir, style: Style, out: *std.Io.Writer) !void {
    switch (style) {
        .text => try output.writeText(io, directory, out),
        .json => try output.writeJson(io, directory, out),
    }
}

fn writeText(output: Output, io: std.Io, directory: std.Io.Dir, out: *std.Io.Writer) !void {
    try out.print("stdout size: {d} bytes\nstderr size: {d} bytes\n", .{ output.stdout.size, output.stderr.size });
    inline for (.{ "stdout", "stderr" }) |name| {
        const stream = @field(output, name);
        if (!stream.lines.isEmpty()) {
            const file = try directory.openFile(io, stream.filename, .{});
            defer file.close(io);
            try excerpt.write(io, file, stream.lines, stream.filename, out);
        }
    }
    if (!output.stdout.lines.isEmpty() or !output.stderr.lines.isEmpty()) try out.writeAll("--- end ---\n");
    try out.print("exit code: {d}\n", .{output.exit_code});
}

fn writeJson(output: Output, io: std.Io, directory: std.Io.Dir, out: *std.Io.Writer) !void {
    var json: std.json.Stringify = .{ .writer = out };
    try json.beginObject();
    inline for (.{ "stdout", "stderr" }) |name| {
        const stream = @field(output, name);
        try json.objectField(name);
        try json.beginObject();
        try json.objectField("path");
        try json.beginWriteRaw();
        var path = try JsonString.begin(out);
        try path.writer.print("{s}{c}{s}", .{ stream.path, std.fs.path.sep, stream.filename });
        try path.finish();
        json.endWriteRaw();
        try json.objectField("size");
        try json.write(stream.size);
        if (!stream.lines.isEmpty()) {
            const file = try directory.openFile(io, stream.filename, .{});
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
