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

pub const Run = struct {
    source: []const u8,
    timeout: ?std.Io.Duration,

    pub const Error = error{
        MissingCommand,
        MissingTimeoutValue,
        InvalidTimeout,
        UnknownFlag,
        UnexpectedArgument,
    };

    const Option = enum {
        timeout,

        const names = std.StaticStringMap(Option).initComptime(.{
            .{ "-t", .timeout },
            .{ "--timeout", .timeout },
        });
    };

    /// Parses `run` arguments: optional options followed by exactly one
    /// command source, borrowing the argument slices.
    pub fn parse(args: []const [:0]const u8) Error!Run {
        var timeout: ?std.Io.Duration = null;
        var rest = args;

        while (rest.len > 0 and std.mem.startsWith(u8, rest[0], "-")) {
            const flag = rest[0];
            const separator = std.mem.indexOfScalar(u8, flag, '=');
            const name = flag[0 .. separator orelse flag.len];

            switch (Option.names.get(name) orelse return error.UnknownFlag) {
                .timeout => if (separator) |index| {
                    timeout = try parseTimeout(flag[index + 1 ..]);
                    rest = rest[1..];
                } else {
                    if (rest.len < 2) return error.MissingTimeoutValue;
                    timeout = try parseTimeout(rest[1]);
                    rest = rest[2..];
                },
            }
        }

        if (rest.len == 0) return error.MissingCommand;
        if (rest.len > 1) return error.UnexpectedArgument;

        return .{ .source = rest[0], .timeout = timeout };
    }
};

const Unit = enum {
    milliseconds,
    seconds,
    minutes,
    hours,

    /// Every letter a suffix is spelled with; anything else is invalid.
    const suffix_letters = "msh";

    const suffixes = std.StaticStringMap(Unit).initComptime(.{
        .{ "ms", .milliseconds },
        .{ "s", .seconds },
        .{ "m", .minutes },
        .{ "h", .hours },
    });

    fn nanoseconds(unit: Unit) i96 {
        return switch (unit) {
            .milliseconds => std.time.ns_per_ms,
            .seconds => std.time.ns_per_s,
            .minutes => std.time.ns_per_min,
            .hours => std.time.ns_per_hour,
        };
    }
};

/// Accepts a positive count with a `Unit` suffix; a bare count is seconds.
fn parseTimeout(text: []const u8) Run.Error!std.Io.Duration {
    const digits = std.mem.trimEnd(u8, text, Unit.suffix_letters);
    const suffix = text[digits.len..];
    const unit: Unit = if (suffix.len == 0)
        .seconds
    else
        Unit.suffixes.get(suffix) orelse return error.InvalidTimeout;

    return .fromNanoseconds(try amount(digits) * unit.nanoseconds());
}

fn amount(text: []const u8) Run.Error!i96 {
    const value = std.fmt.parseUnsigned(u32, text, 10) catch return error.InvalidTimeout;
    if (value == 0) return error.InvalidTimeout;

    return value;
}

test "run argument parsing" {
    const t = std.testing;

    const bare = try Run.parse(&.{"echo hello"});
    try t.expectEqualStrings("echo hello", bare.source);
    try t.expectEqual(null, bare.timeout);

    const cases = .{
        .{ "30", std.time.ns_per_s * 30 },
        .{ "30s", std.time.ns_per_s * 30 },
        .{ "500ms", std.time.ns_per_ms * 500 },
        .{ "5m", std.time.ns_per_min * 5 },
        .{ "2h", std.time.ns_per_hour * 2 },
    };
    inline for (cases) |case| {
        const expected: std.Io.Duration = .fromNanoseconds(case[1]);

        inline for (.{ "-t", "--timeout" }) |flag| {
            const separate = try Run.parse(&.{ flag, case[0], "echo hello" });
            const joined = try Run.parse(&.{ flag ++ "=" ++ case[0], "echo hello" });

            try t.expectEqual(expected, separate.timeout.?);
            try t.expectEqual(expected, joined.timeout.?);
            try t.expectEqualStrings("echo hello", separate.source);
            try t.expectEqualStrings("echo hello", joined.source);
        }
    }

    try t.expectError(error.MissingCommand, Run.parse(&.{}));
    try t.expectError(error.MissingCommand, Run.parse(&.{ "--timeout", "5" }));
    try t.expectError(error.MissingTimeoutValue, Run.parse(&.{"--timeout"}));
    try t.expectError(error.MissingTimeoutValue, Run.parse(&.{"-t"}));
    try t.expectError(error.UnknownFlag, Run.parse(&.{ "-x", "echo hello" }));
    try t.expectError(error.UnknownFlag, Run.parse(&.{ "--quiet", "echo hello" }));
    try t.expectError(error.UnknownFlag, Run.parse(&.{ "--timeoutish=5", "echo hello" }));
    try t.expectError(error.UnexpectedArgument, Run.parse(&.{ "echo hello", "extra" }));

    inline for (.{ "0", "0s", "", "s", "-5", "5x", "5 s" }) |invalid| {
        try t.expectError(error.InvalidTimeout, Run.parse(&.{ "--timeout", invalid, "echo hello" }));
    }
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
