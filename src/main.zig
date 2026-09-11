const std = @import("std");
const build_options = @import("build_options");
const command = @import("command.zig");
const run = @import("run.zig");
const last = @import("last.zig");
const print = @import("print.zig");
const report = @import("report.zig");
const clean = @import("clean.zig");
const instruction = @import("instruction.zig");

const usage =
    \\Usage: fb [run] [options] '<command>'
    \\       fb last [options]
    \\       fb print [options] <id>
    \\       fb clean
    \\       fb install|init|uninstall [agents|claude]
    \\
    \\Commands:
    \\  run        run a shell command and save stdout and stderr to files (default)
    \\  last       print saved output again without rerunning the command
    \\  print      print a saved run by ID without rerunning the command
    \\  clean      remove all saved output from the temporary file_bash directory
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

pub fn main(init: std.process.Init) void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const arena = init.arena.allocator();

    const code = dispatch(init.io, arena, init.minimal.args, init.environ_map, stdout, stderr) catch |err| {
        stderr.print("command failed: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };

    stdout.flush() catch |err| {
        stderr.print("failed to write command results to stdout: {s}\n", .{@errorName(err)}) catch {};
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
        .run => run.execute(io, arena, parsed.args, environ, stdout, stderr),
        .last => last.execute(io, arena, parsed.args, environ, stdout, stderr),
        .print => print.execute(io, arena, parsed.args, environ, stdout, stderr),
        .clean => clean.execute(io, parsed.args, environ, stdout, stderr),
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

test {
    _ = run;
    _ = command;
    _ = clean;
    _ = last;
    _ = print;
    _ = report;
    _ = instruction;
}
