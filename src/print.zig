const std = @import("std");
const command = @import("command.zig");
const dir = @import("dir.zig");
const report = @import("report.zig");
const last = @import("last.zig");
const Output = @import("Output.zig");

const usage =
    \\Usage: fb print [options] <id>
    \\
    \\Print a saved run's output again without running the command again.
    \\
    \\Options:
    \\  --json                    print results as JSON
    \\  -d, --head <n>            first n lines of stdout and stderr
    \\  -l, --tail <n>            last n lines of stdout and stderr
    \\  -o:d, --out:head <n>      first n lines of stdout only
    \\  -o:l, --out:tail <n>      last n lines of stdout only
    \\  -e:d, --err:head <n>      first n lines of stderr only
    \\  -e:l, --err:tail <n>      last n lines of stderr only
    \\  -h, --help                show this help
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
    var diagnostic: command.Run.Diagnostic = .{};
    const parsed = command.Run.parse(.print, args, .{ .diagnostic = &diagnostic }) catch |err| {
        try diagnostic.write(err, stderr);
        try stderr.writeAll(usage);
        return 2;
    };
    if (parsed.help) {
        try stdout.writeAll(usage);
        return 0;
    }

    const id = parsed.name.?;
    const outputs = try dir.openOutputs(io, environ) orelse return report.missing(.named, id, stderr);
    defer outputs.parent.close(io);

    return report.write(io, arena, outputs, id, .named, parsed, stdout, stderr);
}

test "print reports an explicit saved ID without changing last" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("TMPDIR", path);
    try environ.put("TMP", path);

    var absent_out: std.Io.Writer.Allocating = .init(arena);
    var absent_err: std.Io.Writer.Allocating = .init(arena);
    try t.expectEqual(1, try execute(io, arena, &.{"absent"}, &environ, &absent_out.writer, &absent_err.writer));
    try t.expectEqualStrings("", absent_out.written());
    try t.expectEqualStrings("no run named 'absent'\n", absent_err.written());

    var parent = try tmp.dir.createDirPathOpen(io, dir.output_dirname, .{});
    defer parent.close(io);
    const selected_id = "selected";
    const last_id = "newest";
    try last.remember(io, parent, last_id);
    var selected = try parent.createDirPathOpen(io, selected_id, .{});
    defer selected.close(io);
    try selected.writeFile(io, .{ .sub_path = "stdout", .data = "first\nsecond\nthird\n" });
    try selected.writeFile(io, .{ .sub_path = "stderr", .data = "warning\n" });
    try (Output.Status{ .exit_code = 7, .timed_out = false }).save(io, selected);

    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    const args: []const [:0]const u8 = &.{ "--json", "--out:tail=2", selected_id };
    try t.expectEqual(7, try execute(io, arena, args, &environ, &out.writer, &err.writer));
    const json = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    try t.expectEqual(7, json.object.get("exit_code").?.integer);
    try t.expectEqualStrings("second\nthird\n", json.object.get("stdout").?.object.get("tail").?.string);
    try t.expectEqualStrings(last_id, try parent.readFileAlloc(io, dir.last_filename, arena, .limited(64)));
    try t.expectEqualStrings("", err.written());

    var missing_out: std.Io.Writer.Allocating = .init(arena);
    var missing_err: std.Io.Writer.Allocating = .init(arena);
    try t.expectEqual(1, try execute(io, arena, &.{"missing"}, &environ, &missing_out.writer, &missing_err.writer));
    try t.expectEqualStrings("", missing_out.written());
    try t.expectEqualStrings("no run named 'missing'\n", missing_err.written());
    try t.expectEqualStrings(last_id, try parent.readFileAlloc(io, dir.last_filename, arena, .limited(64)));

    var incomplete = try parent.createDirPathOpen(io, "incomplete", .{});
    incomplete.close(io);
    var unavailable_out: std.Io.Writer.Allocating = .init(arena);
    var unavailable_err: std.Io.Writer.Allocating = .init(arena);
    try t.expectEqual(1, try execute(io, arena, &.{"incomplete"}, &environ, &unavailable_out.writer, &unavailable_err.writer));
    try t.expectEqualStrings("", unavailable_out.written());
    try t.expectEqualStrings(
        "saved run 'incomplete' output or completion status is unavailable\n",
        unavailable_err.written(),
    );
}
