const std = @import("std");

pub const Command = enum {
    run,
    install,
    uninstall,
    version,

    const names = std.StaticStringMap(Command).initComptime(.{
        .{ "run", .run },
        .{ "install", .install },
        .{ "init", .install },
        .{ "uninstall", .uninstall },
        .{ "version", .version },
    });
};

pub const Parsed = struct {
    command: Command,
    args: []const [:0]const u8,
};

/// Parses arguments after the executable name, borrowing the remaining arguments.
pub fn parse(args: []const [:0]const u8) ?Parsed {
    if (args.len == 0) return null;

    if (Command.names.get(args[0])) |selected| {
        return .{ .command = selected, .args = args[1..] };
    }
    return .{ .command = .run, .args = args };
}

test "command parsing" {
    const t = std.testing;

    try t.expectEqual(null, parse(&.{}));

    const run_parsed = parse(&.{"echo hello"}).?;
    try t.expectEqual(Command.run, run_parsed.command);
    try t.expectEqualStrings("echo hello", run_parsed.args[0]);

    const run_explicit = parse(&.{ "run", "echo hello" }).?;
    try t.expectEqual(Command.run, run_explicit.command);
    try t.expectEqualStrings("echo hello", run_explicit.args[0]);

    const v = parse(&.{"version"}).?;
    try t.expectEqual(Command.version, v.command);
    try t.expectEqual(@as(usize, 0), v.args.len);

    inline for (&.{ "install", "init" }) |name| {
        const inst = parse(&.{ name, "claude" }).?;
        try t.expectEqual(Command.install, inst.command);
        try t.expectEqualStrings("claude", inst.args[0]);
    }

    const uninst = parse(&.{ "uninstall", "agents" }).?;
    try t.expectEqual(Command.uninstall, uninst.command);
    try t.expectEqualStrings("agents", uninst.args[0]);
}
