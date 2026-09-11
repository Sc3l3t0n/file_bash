const std = @import("std");
const dir = @import("dir.zig");
const command = @import("command.zig");
const clean = @import("clean.zig");
const report = @import("report.zig");
const Output = @import("Output.zig");

const usage =
    \\Usage: fb last [options]
    \\
    \\Print the last run's saved output again without running the command again.
    \\The run ID is stored in file_bash/last under the temporary directory.
    \\
    \\Options:
    \\  --json                   print results as JSON
    \\  -d, --head <n>            first n lines of stdout and stderr
    \\  -l, --tail <n>            last n lines of stdout and stderr
    \\  -o:h, --out:head <n>      first n lines of stdout only
    \\  -o:l, --out:tail <n>      last n lines of stdout only
    \\  -e:h, --err:head <n>      first n lines of stderr only
    \\  -e:l, --err:tail <n>      last n lines of stderr only
    \\  -h, --help                show this help
    \\
;

pub fn remember(io: std.Io, parent: std.Io.Dir, id: []const u8) !void {
    var atomic_file = try parent.createFileAtomic(io, dir.last_filename, .{ .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, id);
    try atomic_file.replace(io);
}

pub fn execute(
    io: std.Io,
    arena: std.mem.Allocator,
    args: []const [:0]const u8,
    environ: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var diagnostic: command.Run.Diagnostic = .{};
    const parsed = command.Run.parseLast(args, .{ .diagnostic = &diagnostic }) catch |err| {
        try diagnostic.write(err, stderr);
        try stderr.writeAll(usage);
        return 2;
    };
    if (parsed.help) {
        try stdout.writeAll(usage);
        return 0;
    }

    const temp_path = try dir.tempPath(environ);
    var temp = try std.Io.Dir.openDirAbsolute(io, temp_path, .{});
    defer temp.close(io);
    var parent = temp.openDir(io, dir.output_dirname, .{}) catch |err| switch (err) {
        error.FileNotFound => return missing(stderr),
        else => return err,
    };
    defer parent.close(io);
    const id = parent.readFileAlloc(io, dir.last_filename, arena, .limited(64)) catch |err| switch (err) {
        error.FileNotFound => return missing(stderr),
        else => return err,
    };
    if (!dir.validRunName(id)) return error.InvalidLastRunId;
    return report.report(io, arena, parent, temp_path, .{ .last = id }, parsed.style, parsed.stdout, parsed.stderr, stdout, stderr);
}

fn missing(stderr: *std.Io.Writer) !u8 {
    try stderr.writeAll("no saved last run\n");
    return 1;
}

test "last reads output with new excerpt options and clean removes the last pointer" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var environ = std.process.Environ.Map.init(arena);
    try environ.put("TMPDIR", path);
    try environ.put("TMP", path);
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    try t.expectEqual(1, try execute(io, arena, &.{}, &environ, &out.writer, &err.writer));

    var parent = try tmp.dir.createDirPathOpen(io, dir.output_dirname, .{});
    defer parent.close(io);
    const id = "0123456789abcdef0123456789abcdef";
    try remember(io, parent, id);
    var missing_out: std.Io.Writer.Allocating = .init(arena);
    var missing_err: std.Io.Writer.Allocating = .init(arena);
    try t.expectEqual(1, try execute(io, arena, &.{}, &environ, &missing_out.writer, &missing_err.writer));
    try t.expectEqualStrings("last run's output or completion status is unavailable\n", missing_err.written());
    try t.expectEqualStrings("", missing_out.written());

    var directory = try parent.createDirPathOpen(io, id, .{});
    defer directory.close(io);
    try directory.writeFile(io, .{ .sub_path = "stdout", .data = "hello\n" });
    try directory.writeFile(io, .{ .sub_path = "stderr", .data = "" });
    const output_path = try std.fs.path.join(arena, &.{ path, dir.output_dirname, id });
    const output: Output = .{
        .stdout = .{ .path = output_path, .filename = "stdout", .size = 6, .lines = .{ .head = 1 } },
        .stderr = .{ .path = output_path, .filename = "stderr", .lines = .{ .head = 1 } },
        .exit_code = 124,
        .timed_out = true,
    };
    try remember(io, parent, id);
    try t.expectEqualStrings(id, try parent.readFileAlloc(io, dir.last_filename, arena, .limited(33)));
    try t.expectEqual(1, try execute(io, arena, &.{}, &environ, &out.writer, &err.writer));
    try (Output.Status{ .exit_code = output.exit_code, .timed_out = output.timed_out }).save(io, directory);
    inline for (.{ Output.Style.text, Output.Style.json }) |style| {
        var expected: std.Io.Writer.Allocating = .init(arena);
        var actual: std.Io.Writer.Allocating = .init(arena);
        if (style == .text) try Output.writePaths(output.stdout, output.stderr, &expected.writer);
        try output.writeReport(io, directory, style, &expected.writer);
        const args: []const [:0]const u8 = if (style == .json) &.{ "--json", "--head", "1" } else &.{ "--head", "1" };
        try t.expectEqual(124, try execute(io, arena, args, &environ, &actual.writer, &err.writer));
        try t.expectEqualStrings(expected.written(), actual.written());
    }
    try directory.writeFile(io, .{ .sub_path = "stdout", .data = "first\nsecond\nthird\n" });
    var fresh: std.Io.Writer.Allocating = .init(arena);
    try t.expectEqual(124, try execute(io, arena, &.{ "--json", "--out:tail=2" }, &environ, &fresh.writer, &err.writer));
    const json = try std.json.parseFromSliceLeaky(std.json.Value, arena, fresh.written(), .{});
    const stream = json.object.get("stdout").?.object;
    try t.expectEqual(19, stream.get("size").?.integer);
    try t.expectEqualStrings("second\nthird\n", stream.get("tail").?.string);
    try t.expect(stream.get("head") == null);
    try t.expectEqual(0, try clean.execute(io, &.{}, &environ, &out.writer, &err.writer));
    try t.expectError(error.FileNotFound, parent.openFile(io, dir.last_filename, .{}));
    try t.expectEqual(1, try execute(io, arena, &.{}, &environ, &out.writer, &err.writer));
}
