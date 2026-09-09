const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const dir = @import("dir.zig");
const shell = @import("shell.zig");
const command = @import("command.zig");
const instruction = @import("instruction.zig");
const Child = @import("Child.zig");

const usage =
    \\Usage: fb [run] [-t|--timeout <duration>] '<command>'
    \\       fb install|init|uninstall [agents|claude]
    \\       fb version
    \\
;

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
        stderr.print("fb: command failed: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };

    stdout.flush() catch |err| {
        stderr.print("fb: failed to write command results to stdout: {s}\n", .{@errorName(err)}) catch {};
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
        try stderr.writeAll(usage);
        return 2;
    };

    return switch (parsed.command) {
        .version => {
            if (parsed.args.len > 0) {
                try stderr.writeAll(usage);
                return 2;
            }

            try stdout.print("{s}\n", .{build_options.version});
            return 0;
        },
        .run => run(io, arena, parsed.args, environ, stdout, stderr),
        .install, .uninstall => blk: {
            const target = instruction.Target.parse(parsed.args) orelse {
                try stderr.writeAll(usage);
                break :blk 2;
            };

            const result = try instruction.update(io, arena, environ, target, parsed.command == .install);
            const message = switch (result) {
                .added => "Added fb instructions to",
                .updated => "Updated fb instructions in",
                .removed => "Removed fb instructions from",
                .unchanged => "No changes to fb instructions in",
            };

            try stdout.print("{s} {s}\n", .{ message, target.filename() });

            break :blk 0;
        },
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
    const parsed = command.Run.parse(args) catch |err| {
        try stderr.print("fb: invalid run arguments: {s}\n", .{@errorName(err)});
        try stderr.writeAll(usage);
        return 2;
    };

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

    // Report the paths before spawning so a caller can follow the output while
    // the command is still running.
    try stdout.print("stdout: {s}{c}{s}\nstderr: {s}{c}{s}\n", .{
        directory,
        std.fs.path.sep,
        stdout_filename,
        directory,
        std.fs.path.sep,
        stderr_filename,
    });
    try stdout.flush();

    const shell_argv = try shell.command(environ, parsed.source);
    var child = try Child.spawn(io, arena, .{
        .argv = shell_argv.slice(),
        .environ = environ,
        .stdout = stdout_file,
        .stderr = stderr_file,
        .timeout = parsed.timeout,
    });

    const status = try child.wait(io);
    if (status.timed_out) {
        try stderr.print("fb: command timed out after {f} and was killed\n", .{parsed.timeout.?});
    }

    try stdout.print("exit code: {d}\n", .{status.code});
    return status.code;
}

test {
    _ = command;
    _ = Child;
    _ = dir;
    _ = shell;
    _ = instruction;
}
