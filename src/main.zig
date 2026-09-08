const std = @import("std");
const builtin = @import("builtin");
const dir = @import("dir.zig");
const shell = @import("shell.zig");
const command = @import("command.zig");

const stdout_filename = "stdout";
const stderr_filename = "stderr";

pub fn main(init: std.process.Init) void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const arena = init.arena.allocator();

    const code = dispatch(init.io, arena, init.minimal.args, init.environ_map, stdout, stderr) catch |err| {
        stderr.print("file_bash: failed to run command and report its output: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };

    stdout.flush() catch |err| {
        stderr.print("file_bash: failed to write command results to stdout: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
    stderr.flush() catch {
        std.process.exit(1);
    };

    std.process.exit(code);
}

fn dispatch(
    io: std.Io,
    arena: std.mem.Allocator,
    process_args: std.process.Args,
    environ: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = command.parse((try process_args.toSlice(arena))[1..]) orelse {
        try stderr.writeAll("Usage: fb [run] '<command>'\n");
        return 2;
    };

    return switch (parsed.command) {
        .run => run(io, arena, parsed.args, environ, stdout, stderr),
    };
}

fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    args: []const [:0]const u8,
    environ: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len == 0) {
        try stderr.writeAll("Usage: fb [run] '<command>'\n");
        return 2;
    }

    // Keep each run's files together and leave them available after exit.
    var random: [16]u8 = undefined;
    io.random(&random);

    const temp_path = try dir.tempPath(environ);
    const name = "file_bash-" ++ std.fmt.bytesToHex(random, .lower);
    const directory = try std.fs.path.join(arena, &.{ temp_path, name });
    const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
    try std.Io.Dir.createDirAbsolute(io, directory, permissions);
    var output_dir = try std.Io.Dir.openDirAbsolute(io, directory, .{});
    defer output_dir.close(io);

    const stdout_file = try output_dir.createFile(io, stdout_filename, .{ .exclusive = true });
    defer stdout_file.close(io);
    const stderr_file = try output_dir.createFile(io, stderr_filename, .{ .exclusive = true });
    defer stderr_file.close(io);

    const shell_argv = try shell.command(environ, args[0]);
    var child = try std.process.spawn(io, .{
        .argv = shell_argv.slice(),
        .stdout = .{ .file = stdout_file },
        .stderr = .{ .file = stderr_file },
    });
    const term = try child.wait(io);
    const code: u8 = switch (term) {
        .exited => |code| code,
        .signal, .stopped => |signal| @intCast(@min(255, 128 + @as(u32, @intFromEnum(signal)))),
        .unknown => 1,
    };

    try stdout.print("exit code: {d}\nstdout: {s}{c}{s}\nstderr: {s}{c}{s}\n", .{
        code,
        directory,
        std.fs.path.sep,
        stdout_filename,
        directory,
        std.fs.path.sep,
        stderr_filename,
    });
    return code;
}

test {
    _ = dir;
    _ = shell;
}
