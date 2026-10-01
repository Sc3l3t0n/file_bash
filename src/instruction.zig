const std = @import("std");
const builtin = @import("builtin");
const dir = @import("dir.zig");

pub const Named = enum {
    agents,
    claude,
    codex,
    antigravity,

    /// Instruction file relative to the home directory.
    fn relative(named: Named) []const u8 {
        return switch (named) {
            .agents => ".agents/AGENTS.md",
            .claude => ".claude/CLAUDE.md",
            .codex => ".codex/AGENTS.md",
            .antigravity => ".gemini/GEMINI.md",
        };
    }
};

pub const Target = union(enum) {
    named: Named,
    /// Borrowed path to the instruction file, resolved relative to the working directory.
    custom: []const u8,

    pub fn parse(args: []const [:0]const u8) ?Target {
        return switch (args.len) {
            0 => .{ .named = .agents },
            1 => .{ .named = std.meta.stringToEnum(Named, args[0]) orelse return null },
            2 => if (std.mem.eql(u8, args[0], "custom") and args[1].len > 0) .{ .custom = args[1] } else null,
            else => null,
        };
    }

    /// Returns the instruction file path; borrows the custom path and allocates named ones.
    pub fn path(target: Target, arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
        return switch (target) {
            .named => |named| std.fs.path.join(arena, &.{ try dir.homePath(environ), named.relative() }),
            .custom => |custom| custom,
        };
    }
};

pub const Result = enum { added, updated, removed, unchanged };

const start = "<!-- fb:begin -->";
const end = "<!-- fb:end -->";
const content =
    \\Run noisy or long shell commands (builds, tests, logs) as `fb run [options] '<command>'`.
    \\Put all fb options before the single-quoted shell command, for example
    \\`fb run -l 20 -t 30s 'zig build'`. fb writes stdout and stderr to files and prints their
    \\paths, sizes, and the exit code; read the files with grep, head, or tail instead of dumping them.
    \\Add `-l <n>` to print the last n lines of each file inline, `-t <duration>` (30s, 5m) to
    \\kill a hanging command (exit 124), `-a` to print the paths before the command starts so
    \\the files can be followed while it runs, and `--json` for a machine-readable report.
    \\A command whose stdout or stderr file exceeds 256M is killed (exit 153); pass `-u` when
    \\huge output is expected and must not be interrupted.
    \\`fb last [options]` and `fb print [options] <id>` re-report a saved run without rerunning it;
    \\`-n <name>` gives a run a stable ID and path. Run `fb run --help`, `fb last --help`, or
    \\`fb print --help` for all options.
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
    path: []const u8,
    install: bool,
) !Result {
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

test "target parsing accepts named targets and a custom path" {
    const t = std.testing;
    try t.expectEqual(Named.agents, Target.parse(&.{}).?.named);

    inline for (.{ "agents", "claude", "codex", "antigravity" }) |name| {
        try t.expectEqual(std.meta.stringToEnum(Named, name).?, Target.parse(&.{name}).?.named);
    }

    try t.expectEqualStrings("notes/RULES.md", Target.parse(&.{ "custom", "notes/RULES.md" }).?.custom);

    try t.expectEqual(null, Target.parse(&.{"gemini"}));
    try t.expectEqual(null, Target.parse(&.{"custom"}));
    try t.expectEqual(null, Target.parse(&.{ "custom", "" }));
    try t.expectEqual(null, Target.parse(&.{ "claude", "extra" }));
    try t.expectEqual(null, Target.parse(&.{ "custom", "a", "b" }));
}

test "named targets resolve under the home directory" {
    const t = std.testing;
    var environ: std.process.Environ.Map = .init(t.allocator);
    defer environ.deinit();

    const key = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = if (builtin.os.tag == .windows) "C:\\Users\\me" else "/home/me";
    try environ.put(key, home);

    const expected = try std.fs.path.join(t.allocator, &.{ home, ".gemini", "GEMINI.md" });
    defer t.allocator.free(expected);

    const resolved = try (Target{ .named = .antigravity }).path(t.allocator, &environ);
    defer t.allocator.free(resolved);
    try t.expectEqualStrings(expected, resolved);

    try t.expectEqualStrings("x/y.md", try (Target{ .custom = "x/y.md" }).path(t.allocator, &environ));
}
