const std = @import("std");
const builtin = @import("builtin");
const dir = @import("dir.zig");
const shell = @import("shell.zig");
const Child = @import("Child.zig");
const excerpt = @import("excerpt.zig");
const Output = @import("Output.zig");
const command = @import("command.zig");
const last = @import("last.zig");

const usage =
    \\Usage: fb [run] [options] '<command>'
    \\
    \\Save stdout and stderr to files; report paths, sizes, and exit code on completion.
    \\
    \\Options:
    \\  -n, --name <name>        save under this name, overwriting previous output
    \\  --json                   print results as JSON (cannot be used with --async)
    \\  -a, --async               print the output paths before the command starts
    \\  -t, --timeout <duration>  kill the command after the duration (30s, 5m, 2h)
    \\  -d, --head <n>            print the first n lines of stdout and stderr afterwards
    \\  -l, --tail <n>            print the last n lines of stdout and stderr afterwards
    \\  -o:h, --out:head <n>      first n lines of stdout only
    \\  -o:l, --out:tail <n>      last n lines of stdout only
    \\  -e:h, --err:head <n>      first n lines of stderr only
    \\  -e:l, --err:tail <n>      last n lines of stderr only
    \\  -h, --help                show this help
    \\
    \\Examples:
    \\  fb 'echo hello'
    \\  fb run --tail 20 'zig build test'
    \\  fb run --timeout 30s 'zig build'
    \\
;

pub fn execute(
    io: std.Io,
    arena: std.mem.Allocator,
    args: []const [:0]const u8,
    environ: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len == 0) {
        try stdout.writeAll(usage);
        return 0;
    }

    var diagnostic: command.Run.Diagnostic = .{};
    const parsed = command.Run.parse(args, .{ .diagnostic = &diagnostic }) catch |err| {
        try diagnostic.write(err, stderr);
        switch (err) {
            error.MissingCommand, error.UnknownFlag => try stderr.writeAll(usage),
            else => {},
        }
        return 2;
    };

    if (parsed.help) {
        try stdout.writeAll(usage);
        return 0;
    }

    // Keep each run's files together and leave them available after exit.
    var random_name: [32]u8 = undefined;
    const name = if (parsed.name) |name| name else name: {
        var random: [16]u8 = undefined;
        io.random(&random);
        random_name = std.fmt.bytesToHex(random, .lower);
        break :name &random_name;
    };

    const temp_path = try dir.tempPath(environ);
    const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);

    var temp_dir = try std.Io.Dir.openDirAbsolute(io, temp_path, .{});
    defer temp_dir.close(io);

    // All runs share one parent directory; it may already exist from earlier runs.
    var parent_dir = try temp_dir.createDirPathOpen(io, dir.output_dirname, .{ .permissions = permissions });
    defer parent_dir.close(io);

    parent_dir.createDir(io, name, permissions) catch |err| switch (err) {
        error.PathAlreadyExists => if (parsed.name == null) return err,
        else => return err,
    };
    var output_dir = try parent_dir.openDir(io, name, .{ .follow_symlinks = false });
    defer output_dir.close(io);

    // Clear the previous completion status before starting another run.
    const status_file = try output_dir.createFile(io, "status", .{});
    status_file.close(io);

    const stdout_file = try output_dir.createFile(io, Output.stdout_filename, .{});
    defer stdout_file.close(io);
    const stderr_file = try output_dir.createFile(io, Output.stderr_filename, .{});
    defer stderr_file.close(io);

    // With --async the paths are reported before spawning so a caller can follow
    // the output while the command is still running.
    const output_path = try std.fs.path.join(arena, &.{ temp_path, dir.output_dirname, name });
    const output_stdout: Output.Stream = .{
        .path = output_path,
        .filename = Output.stdout_filename,
        .lines = parsed.stdout,
    };
    const output_stderr: Output.Stream = .{
        .path = output_path,
        .filename = Output.stderr_filename,
        .lines = parsed.stderr,
    };
    const shell_argv = try shell.command(environ, parsed.source);

    if (parsed.async) {
        try Output.writePaths(output_stdout, output_stderr, stdout);
        try stdout.flush();
    }

    var child = try Child.spawn(io, arena, .{
        .argv = shell_argv.slice(),
        .environ = environ,
        .stdout = stdout_file,
        .stderr = stderr_file,
        .timeout = parsed.timeout,
    });

    last.remember(io, parent_dir, name) catch |err| {
        // The shell has started; reap it even if saving the pointer fails.
        _ = child.wait(io) catch {};
        return err;
    };

    const status = try child.wait(io);
    if (status.timed_out) {
        try stderr.print("command timed out after {f} and was killed\n", .{parsed.timeout.?});
    }

    try (Output.Status{ .exit_code = status.code, .timed_out = status.timed_out }).save(io, output_dir);
    const output = try Output.read(io, output_dir, output_path, parsed.stdout, parsed.stderr);
    if (parsed.style == .text and !parsed.async) try Output.writePaths(output_stdout, output_stderr, stdout);
    try output.writeReport(io, output_dir, parsed.style, stdout);
    return status.code;
}

test {
    _ = excerpt;
    _ = Output;
    _ = Child;
    _ = dir;
    _ = shell;
}
