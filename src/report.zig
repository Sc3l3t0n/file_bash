const std = @import("std");
const dir = @import("dir.zig");
const excerpt = @import("excerpt.zig");
const Output = @import("Output.zig");

pub const Target = union(enum) {
    last: []const u8,
    named: []const u8,

    pub fn id(target: Target) []const u8 {
        return switch (target) {
            .last => |name| name,
            .named => |name| name,
        };
    }
};

pub fn report(
    io: std.Io,
    arena: std.mem.Allocator,
    parent: std.Io.Dir,
    temp_path: []const u8,
    target: Target,
    style: Output.Style,
    stdout_lines: excerpt.Excerpt,
    stderr_lines: excerpt.Excerpt,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const run_id = target.id();
    var directory = parent.openDir(io, run_id, .{}) catch |err| switch (err) {
        error.FileNotFound => return missing(target, stderr),
        else => return err,
    };
    defer directory.close(io);

    const output_path = try std.fs.path.join(arena, &.{ temp_path, dir.output_dirname, run_id });
    const output = Output.read(io, directory, output_path, stdout_lines, stderr_lines) catch |err| switch (err) {
        error.FileNotFound => return unavailable(target, stderr),
        else => return err,
    };
    if (style == .text) try Output.writePaths(output.stdout, output.stderr, stdout);
    try output.writeReport(io, directory, style, stdout);
    return output.exit_code;
}

fn missing(target: Target, stderr: *std.Io.Writer) !u8 {
    switch (target) {
        .last => try stderr.writeAll("last run's output or completion status is unavailable\n"),
        .named => |name| try stderr.print("no run named '{s}'\n", .{name}),
    }
    return 1;
}

fn unavailable(target: Target, stderr: *std.Io.Writer) !u8 {
    switch (target) {
        .last => try stderr.writeAll("last run's output or completion status is unavailable\n"),
        .named => |name| try stderr.print("saved run '{s}' output or completion status is unavailable\n", .{name}),
    }
    return 1;
}

test {
    _ = Output;
    _ = dir;
    _ = excerpt;
}

test "Target.id returns the underlying run id" {
    const t = std.testing;
    const last_target: Target = .{ .last = "run_1" };
    const named_target: Target = .{ .named = "run_2" };
    try t.expectEqualStrings("run_1", last_target.id());
    try t.expectEqualStrings("run_2", named_target.id());
}
