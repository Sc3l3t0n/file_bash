const std = @import("std");

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

    const code = run(init.io, arena, init.minimal.args, stdout, stderr) catch |err| {
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

fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    process_args: std.process.Args,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const args = try process_args.toSlice(arena);
    if (args.len < 2) {
        try stderr.writeAll("Usage: file_bash '<command>'\n");
        return 2;
    }

    // Keep each run's files together and leave them available after exit.
    var random: [16]u8 = undefined;
    io.random(&random);

    const directory = try std.fmt.allocPrint(arena, "/tmp/file_bash-{s}", .{std.fmt.bytesToHex(random, .lower)});
    try std.Io.Dir.createDirAbsolute(io, directory, .fromMode(0o700));
    var output_dir = try std.Io.Dir.openDirAbsolute(io, directory, .{});
    defer output_dir.close(io);

    const stdout_file = try output_dir.createFile(io, stdout_filename, .{ .exclusive = true });
    defer stdout_file.close(io);
    const stderr_file = try output_dir.createFile(io, stderr_filename, .{ .exclusive = true });
    defer stderr_file.close(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", args[1] },
        .stdout = .{ .file = stdout_file },
        .stderr = .{ .file = stderr_file },
    });
    const term = try child.wait(io);
    const code: u8 = switch (term) {
        .exited => |code| code,
        .signal, .stopped => |signal| @intCast(@min(255, 128 + @as(u32, @intFromEnum(signal)))),
        .unknown => 1,
    };

    try stdout.print("exit code: {d}\nstdout: {s}/{s}\nstderr: {s}/{s}\n", .{
        code,
        directory,
        stdout_filename,
        directory,
        stderr_filename,
    });
    return code;
}
