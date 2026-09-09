//! Run information shared by the text and JSON renderers. Slices live in the run arena.
const std = @import("std");
const excerpt = @import("excerpt.zig");
const JsonString = @import("JsonString.zig");
const Output = @This();

pub const Style = enum { text, json };

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
