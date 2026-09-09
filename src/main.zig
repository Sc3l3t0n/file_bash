const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const dir = @import("dir.zig");
const shell = @import("shell.zig");
const command = @import("command.zig");
const instruction = @import("instruction.zig");
const Child = @import("Child.zig");
const excerpt = @import("excerpt.zig");
const Output = @import("Output.zig");

const usage =
    \\Usage: fb [run] [options] '<command>'
    \\       fb install|init|uninstall [agents|claude]
    \\
    \\Commands:
    \\  run        run a shell command and save stdout and stderr to files (default)
    \\  install    install global fb instructions (alias: init)
    \\  uninstall  remove global fb instructions
    \\
    \\Options:
    \\  -h, --help     show this help
    \\  -v, --version  print the version
    \\
    \\Use 'fb run --help' for run options and examples.
    \\
;

const run_usage =
    \\Usage: fb [run] [options] '<command>'
    \\
    \\Save stdout and stderr to files; report paths, sizes, and exit code on completion.
    \\
    \\Options:
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

const parent_dirname = "file_bash";
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
        try stdout.writeAll(usage);
        return 0;
    };

    if (parsed.option) |option| switch (option) {
        .help => {
            if (parsed.args.len > 0) {
                try stderr.writeAll(usage);
                return 2;
            }
            try stdout.writeAll(usage);
            return 0;
        },
        .version => {
            if (parsed.args.len > 0) {
                try stderr.writeAll(usage);
                return 2;
            }

            try stdout.print("{s}\n", .{build_options.version});
            return 0;
        },
    };

    return switch (parsed.command) {
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
    if (args.len == 0) {
        try stdout.writeAll(run_usage);
        return 0;
    }

    var diagnostic: command.Run.Diagnostic = .{};
    const parsed = command.Run.parse(args, .{ .diagnostic = &diagnostic }) catch |err| {
        try diagnostic.write(err, stderr);
        switch (err) {
            error.MissingCommand, error.UnknownFlag => try stderr.writeAll(run_usage),
            else => {},
        }
        return 2;
    };

    if (parsed.help) {
        try stdout.writeAll(run_usage);
        return 0;
    }

    // Keep each run's files together and leave them available after exit.
    var random: [16]u8 = undefined;
    io.random(&random);

    const temp_path = try dir.tempPath(environ);
    const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);

    var temp_dir = try std.Io.Dir.openDirAbsolute(io, temp_path, .{});
    defer temp_dir.close(io);

    // All runs share one parent directory; it may already exist from earlier runs.
    var parent_dir = try temp_dir.createDirPathOpen(io, parent_dirname, .{ .permissions = permissions });
    defer parent_dir.close(io);

    const name = std.fmt.bytesToHex(random, .lower);
    // NOTE: not createDirPathOpen; an existing dir must fail (future named paths).
    try parent_dir.createDir(io, &name, permissions);
    var output_dir = try parent_dir.openDir(io, &name, .{});
    defer output_dir.close(io);

    const stdout_file = try output_dir.createFile(io, stdout_filename, .{ .exclusive = true });
    defer stdout_file.close(io);
    const stderr_file = try output_dir.createFile(io, stderr_filename, .{ .exclusive = true });
    defer stderr_file.close(io);

    // With --async the paths are reported before spawning so a caller can follow
    // the output while the command is still running.
    const output_path = try std.fs.path.join(arena, &.{ temp_path, parent_dirname, &name });
    var output_stdout: Output.Stream = .{
        .path = output_path,
        .filename = stdout_filename,
        .lines = parsed.stdout,
    };
    var output_stderr: Output.Stream = .{
        .path = output_path,
        .filename = stderr_filename,
        .lines = parsed.stderr,
    };
    if (parsed.async) {
        try Output.writePaths(output_stdout, output_stderr, stdout);
        try stdout.flush();
    }

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

    output_stdout.size = (try stdout_file.stat(io)).size;
    output_stderr.size = (try stderr_file.stat(io)).size;
    const output: Output = .{
        .stdout = output_stdout,
        .stderr = output_stderr,
        .exit_code = status.code,
        .timed_out = status.timed_out,
    };
    if (parsed.style == .text and !parsed.async) try Output.writePaths(output_stdout, output_stderr, stdout);
    try output.writeReport(io, output_dir, parsed.style, stdout);
    return status.code;
}

test {
    _ = command;
    _ = excerpt;
    _ = Output;
    _ = Child;
    _ = dir;
    _ = shell;
    _ = instruction;
}
