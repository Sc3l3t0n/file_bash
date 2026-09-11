const std = @import("std");
const builtin = @import("builtin");
const dir = @import("dir.zig");
const shell = @import("shell.zig");
const Child = @import("Child.zig");
const Output = @import("Output.zig");
const command = @import("command.zig");
const last = @import("last.zig");

const usage =
    \\Usage: fb [run] [options] '<command>'
    \\
    \\Save stdout and stderr to files; report paths, sizes, and exit code on completion.
    \\
    \\Options:
    \\  -n, --name <name>         save under this name, overwriting previous output
    \\  --json                    print results as JSON (cannot be used with --async)
    \\  -a, --async               print the output paths before the command starts
    \\  -C <dir>                  working directory (default: FILE_BASH_CWD or current directory)
    \\  -t, --timeout <duration>  kill the command after the duration (30s, 5m, 2h)
    \\  -d, --head <n>            print the first n lines of stdout and stderr afterwards
    \\  -l, --tail <n>            print the last n lines of stdout and stderr afterwards
    \\  -o:d, --out:head <n>      first n lines of stdout only
    \\  -o:l, --out:tail <n>      last n lines of stdout only
    \\  -e:d, --err:head <n>      first n lines of stderr only
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
    const parsed = command.Run.parse(.run, args, .{ .diagnostic = &diagnostic }) catch |err| {
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

    var cwd: ?std.Io.Dir = null;
    if (dir.workingPath(parsed.cwd, environ)) |path| {
        cwd = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| {
            try stderr.print("working directory '{s}' from '{s}': {s}\n", .{
                path,
                if (parsed.cwd != null) "-C" else "FILE_BASH_CWD",
                if (err == error.FileNotFound) "does not exist" else @errorName(err),
            });
            return 1;
        };
    }
    defer if (cwd) |opened| opened.close(io);

    // Keep each run's files together and leave them available after exit.
    var random_name: [32]u8 = undefined;
    const name = parsed.name orelse name: {
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

    // A named run reuses its directory; a random name must be fresh.
    parent_dir.createDir(io, name, permissions) catch |err| {
        if (err != error.PathAlreadyExists or parsed.name == null) return err;
    };
    var output_dir = try parent_dir.openDir(io, name, .{ .follow_symlinks = false });
    defer output_dir.close(io);

    try Output.Status.clear(io, output_dir);
    const stdout_file = try output_dir.createFile(io, "stdout", .{});
    defer stdout_file.close(io);
    const stderr_file = try output_dir.createFile(io, "stderr", .{});
    defer stderr_file.close(io);

    const output_path = try std.fs.path.join(arena, &.{ temp_path, dir.output_dirname, name });
    const shell_argv = try shell.command(environ, parsed.source);

    // With --async the paths are reported before spawning so a caller can follow
    // the output while the command is still running.
    if (parsed.async) {
        try Output.writePaths(output_path, stdout);
        try stdout.flush();
    }

    var child = try Child.spawn(io, arena, .{
        .argv = shell_argv.slice(),
        .cwd = cwd,
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

    try (Output.Status{
        .exit_code = status.code,
        .timed_out = status.timed_out,
        .duration = status.duration,
    }).save(io, output_dir);
    const output = try Output.read(io, output_dir, output_path, parsed.stdout, parsed.stderr);
    try output.writeReport(io, output_dir, parsed.style, stdout);

    return status.code;
}

test {
    _ = Child;
    _ = dir;
    _ = shell;
}
