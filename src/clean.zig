const std = @import("std");
const dir = @import("dir.zig");

const nothing_to_clean = "fb outputs already cleaned up\n";

const usage =
    \\Usage: fb clean
    \\
    \\Remove all saved runs from your fb output directory, keeping the directory.
    \\Uses the same temporary directory as fb run. Missing output is harmless.
    \\
    \\Options:
    \\  -h, --help  show this help
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

    const outputs = try dir.openOutputs(io, arena, environ, .open) orelse {
        try stdout.writeAll(nothing_to_clean);
        return 0;
    };
    const output_dir = outputs.parent;
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
