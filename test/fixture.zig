//! Command run by the CLI tests through fb, so every shell sees the same
//! behavior. Flags run in order:
//!
//!   --out <line>       write the line to stdout
//!   --err <line>       write the line to stderr
//!   --out-bytes <n>    write n bytes to stdout
//!   --no-newline       end later --out and --err lines without a newline
//!   --stdin            write "stdin: <n> bytes" for the bytes read from stdin
//!   --cwd              write the working directory
//!   --hang             sleep until killed
//!   --exit <code>      exit with the code
const std = @import("std");

const Flag = enum {
    @"--out",
    @"--err",
    @"--out-bytes",
    @"--no-newline",
    @"--stdin",
    @"--cwd",
    @"--hang",
    @"--exit",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    var newline = true;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const flag = std.meta.stringToEnum(Flag, args[index]) orelse return error.UnknownFlag;
        switch (flag) {
            .@"--out", .@"--err", .@"--out-bytes", .@"--exit" => {
                index += 1;
                if (index == args.len) return error.MissingValue;
            },
            else => {},
        }
        const value = args[index];

        switch (flag) {
            inline .@"--out", .@"--err" => |stream| {
                const out = if (stream == .@"--out") stdout else stderr;
                try out.writeAll(value);
                if (newline) try out.writeByte('\n');
            },
            .@"--out-bytes" => try stdout.splatByteAll('x', try std.fmt.parseUnsigned(usize, value, 10)),
            .@"--no-newline" => newline = false,
            .@"--stdin" => {
                var buffer: [4096]u8 = undefined;
                var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
                try stdout.print("stdin: {d} bytes\n", .{try reader.interface.discardRemaining()});
            },
            .@"--cwd" => try stdout.print("{s}\n", .{try std.process.currentPathAlloc(io, arena)}),
            .@"--hang", .@"--exit" => {
                // Output must reach the files before the fixture hangs or exits.
                try stdout.flush();
                try stderr.flush();
                if (flag == .@"--hang") while (true) try io.sleep(.fromSeconds(60), .awake);
                std.process.exit(try std.fmt.parseUnsigned(u8, value, 10));
            },
        }
    }

    try stdout.flush();
    try stderr.flush();
}
