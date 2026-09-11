const std = @import("std");
const dir = @import("dir.zig");

pub const Target = enum {
    agents,
    claude,

    pub fn parse(args: []const [:0]const u8) ?Target {
        if (args.len == 0) return .agents;
        if (args.len != 1) return null;

        return std.meta.stringToEnum(Target, args[0]);
    }

    pub fn filename(target: Target) []const u8 {
        return switch (target) {
            .agents => "AGENTS.md",
            .claude => "CLAUDE.md",
        };
    }

    /// Directory under the home directory holding the instruction file.
    fn folder(target: Target) []const u8 {
        return switch (target) {
            .agents => ".agents",
            .claude => ".claude",
        };
    }
};

pub const Result = enum { added, updated, removed, unchanged };

const start = "<!-- fb:begin -->";
const end = "<!-- fb:end -->";
const content =
    \\Use `fb run '<command>'` for shell commands with verbose output (such as builds and tests).
    \\Quote the entire command. fb prints the stdout/stderr file paths and the exit code
    \\when the command finishes; inspect those files with targeted searches or bounded
    \\reads. Add `-a` to print the paths before the command starts, so the files can be
    \\followed while it is still running.
    \\The files remain available after the command exits.
    \\Add `-t <duration>` (such as `30s` or `5m`) to kill a command that may hang;
    \\a timed-out run exits with code 124. Add `-l <n>` (or `-d <n>`) to print the last
    \\(or first) n lines of both files after the command; `-o:l`/`-e:l` and `-o:h`/`-e:h`
    \\do the same for only stdout or only stderr.
;

const block = start ++ "\n" ++ content ++ "\n" ++ end;

const Section = struct { start: usize, end: usize };

fn section(text: []const u8) !?Section {
    const first = std.mem.indexOf(u8, text, start);
    const last = std.mem.indexOf(u8, text, end);

    if (first == null and last == null) return null;

    const begin = first orelse return error.InvalidInstructionMarkers;
    const finish = last orelse return error.InvalidInstructionMarkers;

    if (finish < begin + start.len or
        std.mem.indexOfPos(u8, text, begin + start.len, start) != null or
        std.mem.indexOfPos(u8, text, finish + end.len, end) != null)
        return error.InvalidInstructionMarkers;

    return .{ .start = begin, .end = finish + end.len };
}

pub fn update(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    selected: Target,
    install: bool,
) !Result {
    const home = try dir.homePath(environ);
    const path = try std.fs.path.join(arena, &.{ home, selected.folder(), selected.filename() });

    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => if (install) "" else return .unchanged,
        else => return err,
    };

    const existing = try section(text);
    if (!install and existing == null) return .unchanged;
    if (install) if (existing) |range| {
        if (std.mem.eql(u8, text[range.start..range.end], block)) return .unchanged;
    };

    var file = try cwd.createFileAtomic(io, path, .{ .replace = true, .make_path = install });
    defer file.deinit(io);

    var buffer: [1024]u8 = undefined;
    var writer_instance = file.file.writer(io, &buffer);
    const writer = &writer_instance.interface;

    if (existing) |range| {
        try writer.writeAll(text[0..range.start]);
        if (install) try writer.writeAll(block);
        try writer.writeAll(text[range.end..]);
    } else {
        try writer.writeAll(text);
        if (text.len > 0 and text[text.len - 1] != '\n') try writer.writeByte('\n');
        try writer.writeAll(block);
        try writer.writeByte('\n');
    }

    try writer.flush();
    try file.replace(io);

    return if (!install) .removed else if (existing != null) .updated else .added;
}

test "instruction markers delimit only fb content and reject malformed sections" {
    const t = std.testing;
    const text = "before\n" ++ block ++ "\nafter";
    const range = (try section(text)).?;
    try t.expectEqualStrings(block, text[range.start..range.end]);
    try t.expectEqual(null, try section("unrelated instructions"));

    for ([_][]const u8{ start, end, end ++ start, block ++ block, start ++ start ++ end }) |invalid| {
        try t.expectError(error.InvalidInstructionMarkers, section(invalid));
    }
}
