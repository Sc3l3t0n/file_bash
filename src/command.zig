const std = @import("std");
const Excerpt = @import("excerpt.zig").Excerpt;

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
    /// Print the output paths before the command starts instead of after it exits.
    async: bool,
    /// Lines of the stdout file to print after the command exits.
    stdout: Excerpt,
    /// Lines of the stderr file to print after the command exits.
    stderr: Excerpt,

    pub const Error = error{
        MissingCommand,
        MissingValue,
        InvalidTimeout,
        InvalidLineCount,
        ConflictingHeadFlags,
        ConflictingTailFlags,
        UnknownFlag,
        UnexpectedValue,
        UnexpectedArgument,
    };

    const Option = enum {
        timeout,
        async,
        head,
        tail,
        out_head,
        out_tail,
        err_head,
        err_tail,

        const names = std.StaticStringMap(Option).initComptime(.{
            .{ "-t", .timeout },
            .{ "--timeout", .timeout },
            .{ "-a", .async },
            .{ "--async", .async },
            .{ "-h", .head },
            .{ "--head", .head },
            .{ "-l", .tail },
            .{ "--tail", .tail },
            .{ "-o:h", .out_head },
            .{ "--out:head", .out_head },
            .{ "-o:l", .out_tail },
            .{ "--out:tail", .out_tail },
            .{ "-e:h", .err_head },
            .{ "--err:head", .err_head },
            .{ "-e:l", .err_tail },
            .{ "--err:tail", .err_tail },
        });

        fn takesValue(option: Option) bool {
            return option != .async;
        }
    };

    /// Parses `run` arguments: optional options followed by exactly one
    /// command source, borrowing the argument slices.
    pub fn parse(args: []const [:0]const u8) Error!Run {
        var run: Run = .{ .source = "", .timeout = null, .async = false, .stdout = .{}, .stderr = .{} };
        const Scope = enum { none, both, individual };
        var head_scope: Scope = .none;
        var tail_scope: Scope = .none;
        var rest = args;

        while (rest.len > 0 and std.mem.startsWith(u8, rest[0], "-")) {
            const flag = rest[0];
            const separator = std.mem.indexOfScalar(u8, flag, '=');
            const name = flag[0 .. separator orelse flag.len];
            const option = Option.names.get(name) orelse return error.UnknownFlag;

            // The value follows `=` or is the next argument.
            var value: []const u8 = "";
            if (option.takesValue()) {
                if (separator) |index| {
                    value = flag[index + 1 ..];
                    rest = rest[1..];
                } else {
                    if (rest.len < 2) return error.MissingValue;
                    value = rest[1];
                    rest = rest[2..];
                }
            } else {
                if (separator != null) return error.UnexpectedValue;
                rest = rest[1..];
            }

            switch (option) {
                .timeout => run.timeout = try parseTimeout(value),
                .async => run.async = true,
                .head => {
                    if (head_scope == .individual) return error.ConflictingHeadFlags;
                    head_scope = .both;
                    run.stdout.head = try parseLineCount(value);
                    run.stderr.head = run.stdout.head;
                },
                .tail => {
                    if (tail_scope == .individual) return error.ConflictingTailFlags;
                    tail_scope = .both;
                    run.stdout.tail = try parseLineCount(value);
                    run.stderr.tail = run.stdout.tail;
                },
                inline .out_head, .err_head => |selected| {
                    if (head_scope == .both) return error.ConflictingHeadFlags;
                    head_scope = .individual;
                    const stream = if (selected == .out_head) &run.stdout else &run.stderr;
                    stream.head = try parseLineCount(value);
                },
                inline .out_tail, .err_tail => |selected| {
                    if (tail_scope == .both) return error.ConflictingTailFlags;
                    tail_scope = .individual;
                    const stream = if (selected == .out_tail) &run.stdout else &run.stderr;
                    stream.tail = try parseLineCount(value);
                },
            }
        }

        if (rest.len == 0) return error.MissingCommand;
        if (rest.len > 1) return error.UnexpectedArgument;

        run.source = rest[0];
        return run;
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

fn parseLineCount(text: []const u8) Run.Error!u32 {
    const value = std.fmt.parseUnsigned(u32, text, 10) catch return error.InvalidLineCount;
    if (value == 0) return error.InvalidLineCount;

    return value;
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
    try t.expectEqual(false, bare.async);

    inline for (.{ "-a", "--async" }) |flag| {
        const run = try Run.parse(&.{ flag, "-t", "5", "echo hello" });
        try t.expectEqual(true, run.async);
        try t.expectEqual(std.Io.Duration.fromNanoseconds(std.time.ns_per_s * 5), run.timeout.?);
        try t.expectEqualStrings("echo hello", run.source);
    }
    try t.expectError(error.UnexpectedValue, Run.parse(&.{ "--async=1", "echo hello" }));

    const both = try Run.parse(&.{ "-h", "3", "--tail=7", "echo hello" });
    try t.expectEqual(Excerpt{ .head = 3, .tail = 7 }, both.stdout);
    try t.expectEqual(Excerpt{ .head = 3, .tail = 7 }, both.stderr);

    const single = try Run.parse(&.{ "-o:h", "1", "--err:tail", "2", "-e:h=4", "--out:tail=8", "echo hello" });
    try t.expectEqual(Excerpt{ .head = 1, .tail = 8 }, single.stdout);
    try t.expectEqual(Excerpt{ .head = 4, .tail = 2 }, single.stderr);

    try t.expectError(error.MissingValue, Run.parse(&.{"-h"}));
    inline for (.{ "0", "", "-1", "x", "1s" }) |invalid| {
        try t.expectError(error.InvalidLineCount, Run.parse(&.{ "--tail", invalid, "echo hello" }));
    }

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
    try t.expectError(error.MissingValue, Run.parse(&.{"--timeout"}));
    try t.expectError(error.MissingValue, Run.parse(&.{"-t"}));
    try t.expectError(error.UnknownFlag, Run.parse(&.{ "-x", "echo hello" }));
    try t.expectError(error.UnknownFlag, Run.parse(&.{ "--quiet", "echo hello" }));
    try t.expectError(error.UnknownFlag, Run.parse(&.{ "--timeoutish=5", "echo hello" }));
    try t.expectError(error.UnexpectedArgument, Run.parse(&.{ "echo hello", "extra" }));

    inline for (.{ "0", "0s", "", "s", "-5", "5x", "5 s" }) |invalid| {
        try t.expectError(error.InvalidTimeout, Run.parse(&.{ "--timeout", invalid, "echo hello" }));
    }
}

test "head flag scopes are mutually exclusive" {
    const t = std.testing;

    inline for (.{ "--head", "-h" }) |general| {
        const both = try Run.parse(&.{ general, "3", "echo hello" });
        try t.expectEqual(Excerpt{ .head = 3 }, both.stdout);
        try t.expectEqual(Excerpt{ .head = 3 }, both.stderr);

        inline for (.{ "--out:head", "-o:h", "--err:head", "-e:h" }) |specific| {
            try t.expectError(error.ConflictingHeadFlags, Run.parse(&.{ general, "3", specific, "9", "echo hello" }));
            try t.expectError(error.ConflictingHeadFlags, Run.parse(&.{ specific, "9", general, "3", "echo hello" }));
            try t.expectError(error.ConflictingHeadFlags, Run.parse(&.{ general ++ "=3", specific ++ "=9", "echo hello" }));
            try t.expectError(error.ConflictingHeadFlags, Run.parse(&.{ specific ++ "=9", general ++ "=3", "echo hello" }));
        }
    }

    inline for (.{ "--out:head", "-o:h" }) |out| {
        const stdout = try Run.parse(&.{ out, "3", "echo hello" });
        try t.expectEqual(Excerpt{ .head = 3 }, stdout.stdout);
        try t.expectEqual(Excerpt{}, stdout.stderr);

        inline for (.{ "--err:head", "-e:h" }) |err| {
            const stderr = try Run.parse(&.{ err, "9", "echo hello" });
            try t.expectEqual(Excerpt{}, stderr.stdout);
            try t.expectEqual(Excerpt{ .head = 9 }, stderr.stderr);

            const both = try Run.parse(&.{ out, "3", err, "9", "echo hello" });
            const reversed = try Run.parse(&.{ err ++ "=9", out ++ "=3", "echo hello" });
            try t.expectEqual(Excerpt{ .head = 3 }, both.stdout);
            try t.expectEqual(Excerpt{ .head = 9 }, both.stderr);
            try t.expectEqual(both.stdout, reversed.stdout);
            try t.expectEqual(both.stderr, reversed.stderr);
        }
    }
}

test "tail flag scopes are mutually exclusive" {
    const t = std.testing;

    inline for (.{ "--tail", "-l" }) |general| {
        const both = try Run.parse(&.{ general, "3", "echo hello" });
        try t.expectEqual(Excerpt{ .tail = 3 }, both.stdout);
        try t.expectEqual(Excerpt{ .tail = 3 }, both.stderr);

        inline for (.{ "--out:tail", "-o:l", "--err:tail", "-e:l" }) |specific| {
            try t.expectError(error.ConflictingTailFlags, Run.parse(&.{ general, "3", specific, "9", "echo hello" }));
            try t.expectError(error.ConflictingTailFlags, Run.parse(&.{ specific, "9", general, "3", "echo hello" }));
            try t.expectError(error.ConflictingTailFlags, Run.parse(&.{ general ++ "=3", specific ++ "=9", "echo hello" }));
            try t.expectError(error.ConflictingTailFlags, Run.parse(&.{ specific ++ "=9", general ++ "=3", "echo hello" }));
        }
    }

    inline for (.{ "--out:tail", "-o:l" }) |out| {
        const stdout = try Run.parse(&.{ out, "3", "echo hello" });
        try t.expectEqual(Excerpt{ .tail = 3 }, stdout.stdout);
        try t.expectEqual(Excerpt{}, stdout.stderr);

        inline for (.{ "--err:tail", "-e:l" }) |err| {
            const stderr = try Run.parse(&.{ err, "9", "echo hello" });
            try t.expectEqual(Excerpt{}, stderr.stdout);
            try t.expectEqual(Excerpt{ .tail = 9 }, stderr.stderr);

            const both = try Run.parse(&.{ out, "3", err, "9", "echo hello" });
            const reversed = try Run.parse(&.{ err ++ "=9", out ++ "=3", "echo hello" });
            try t.expectEqual(Excerpt{ .tail = 3 }, both.stdout);
            try t.expectEqual(Excerpt{ .tail = 9 }, both.stderr);
            try t.expectEqual(both.stdout, reversed.stdout);
            try t.expectEqual(both.stderr, reversed.stderr);
        }
    }
}

test "repeated flags within a scope use the last count" {
    const t = std.testing;

    const both = try Run.parse(&.{ "--head=1", "-h=2", "--tail=3", "-l=4", "echo hello" });
    try t.expectEqual(Excerpt{ .head = 2, .tail = 4 }, both.stdout);
    try t.expectEqual(both.stdout, both.stderr);

    const individual = try Run.parse(&.{ "--out:head=1", "-o:h=2", "--err:tail=3", "-e:l=4", "echo hello" });
    try t.expectEqual(Excerpt{ .head = 2 }, individual.stdout);
    try t.expectEqual(Excerpt{ .tail = 4 }, individual.stderr);
}

test "head and tail scopes are independent" {
    const t = std.testing;

    const head = try Run.parse(&.{ "--head", "3", "--out:tail", "5", "--err:tail", "7", "echo hello" });
    try t.expectEqual(Excerpt{ .head = 3, .tail = 5 }, head.stdout);
    try t.expectEqual(Excerpt{ .head = 3, .tail = 7 }, head.stderr);

    const tail = try Run.parse(&.{ "--out:head", "5", "--err:head", "7", "--tail", "3", "echo hello" });
    try t.expectEqual(Excerpt{ .head = 5, .tail = 3 }, tail.stdout);
    try t.expectEqual(Excerpt{ .head = 7, .tail = 3 }, tail.stderr);
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
