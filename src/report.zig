//! Prints the report for a run that has already been saved.
const std = @import("std");
const dir = @import("dir.zig");
const command = @import("command.zig");
const Output = @import("Output.zig");

/// How the run was chosen; only changes the wording of failures.
pub const Selection = enum { last, named };

const Failure = enum { missing, unavailable };

/// Reads the run directory `id` under `outputs` and writes its report using the
/// style and excerpt options in `options`. Returns the saved exit code.
pub fn write(
    io: std.Io,
    arena: std.mem.Allocator,
    outputs: dir.Outputs,
    id: []const u8,
    selection: Selection,
    options: command.Run,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var directory = outputs.parent.openDir(io, id, .{}) catch |err| switch (err) {
        error.FileNotFound => return fail(selection, id, .missing, stderr),
        else => return err,
    };
    defer directory.close(io);

    const path = try std.fs.path.join(arena, &.{ outputs.temp_path, dir.output_dirname, id });
    const output = Output.read(io, directory, path, options.stdout, options.stderr) catch |err| switch (err) {
        error.FileNotFound => return fail(selection, id, .unavailable, stderr),
        else => return err,
    };

    if (options.style == .text) try Output.writePaths(path, stdout);
    try output.writeReport(io, directory, options.style, stdout);

    return output.exit_code;
}

/// Reports a run that cannot be found; returns the failure exit code.
pub fn missing(selection: Selection, id: []const u8, stderr: *std.Io.Writer) !u8 {
    return fail(selection, id, .missing, stderr);
}

fn fail(selection: Selection, id: []const u8, failure: Failure, stderr: *std.Io.Writer) !u8 {
    switch (selection) {
        .last => try stderr.writeAll("last run's output or completion status is unavailable\n"),
        .named => switch (failure) {
            .missing => try stderr.print("no run named '{s}'\n", .{id}),
            .unavailable => try stderr.print("saved run '{s}' output or completion status is unavailable\n", .{id}),
        },
    }

    return 1;
}
