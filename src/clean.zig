const std = @import("std");
const dir = @import("dir.zig");

const nothing_to_clean = "fb outputs already cleaned up\n";

const usage =
    \\Usage: fb clean
    \\
    \\Remove all children of the temporary file_bash directory, keeping the directory.
    \\Uses the same temporary directory as fb run. Missing output is harmless.
    \\
    \\Options:
    \\  -h, --help  show this help
    \\
;

pub fn execute(
    io: std.Io,
    args: []const [:0]const u8,
    environ: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len == 1 and
        (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")))
    {
        try stdout.writeAll(usage);
        return 0;
    }
    if (args.len != 0) {
        try stderr.print("Unexpected argument '{s}'\n", .{args[0]});
        try stderr.writeAll(usage);
        return 2;
    }

    var temp_dir = try std.Io.Dir.openDirAbsolute(io, try dir.tempPath(environ), .{});
    defer temp_dir.close(io);

    var output_dir = temp_dir.openDir(io, dir.output_dirname, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try stdout.writeAll(nothing_to_clean);
            return 0;
        },
        else => return err,
    };
    defer output_dir.close(io);

    var children = output_dir.iterate();
    var deleted: usize = 0;
    while (try children.next(io)) |child| {
        try output_dir.deleteTree(io, child.name);
        deleted += 1;
    }
    if (deleted == 0) {
        try stdout.writeAll(nothing_to_clean);
    } else {
        try stdout.print("cleaned up {d} fb outputs\n", .{deleted});
    }

    return 0;
}
