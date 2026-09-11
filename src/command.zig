const std = @import("std");
const builtin = @import("builtin");
const dir = @import("dir.zig");
const excerpt = @import("excerpt.zig");
const Output = @import("Output.zig");
const Excerpt = excerpt.Excerpt;

pub const Command = enum {
    run,
    last,
    print,
    clean,
    install,
    uninstall,

    const names = std.StaticStringMap(Command).initComptime(.{
        .{ "run", .run },
        .{ "last", .last },
        .{ "print", .print },
        .{ "clean", .clean },
        .{ "install", .install },
        .{ "init", .install },
        .{ "uninstall", .uninstall },
    });

    fn acceptsOption(command: Command, option: Run.Option) bool {
        return switch (command) {
            .run => true,
            .last, .print => switch (option) {
                .async, .timeout, .unlimited, .name, .cwd => false,
                else => true,
            },
            .clean, .install, .uninstall => false,
        };
    }
};

pub const BaseOption = enum {
    help,
    version,

    const names = std.StaticStringMap(BaseOption).initComptime(.{
        .{ "--help", .help },
        .{ "-h", .help },
        .{ "--version", .version },
        .{ "-v", .version },
    });
};

pub const Parsed = struct {
    option: ?BaseOption = null,
    command: Command,
    args: []const [:0]const u8,
};

/// Parses arguments after the executable name, borrowing the remaining arguments.
pub fn parse(args: []const [:0]const u8) ?Parsed {
    if (args.len == 0) return null;

    if (BaseOption.names.get(args[0])) |option| {
        return .{ .command = .run, .option = option, .args = args[1..] };
    }
    if (Command.names.get(args[0])) |selected| {
        return .{ .command = selected, .args = args[1..] };
    }

    return .{ .command = .run, .args = args };
}

pub const Run = struct {
    help: bool = false,
    style: Output.Style = .text,
    source: []const u8 = "",
    /// Borrowed output directory name; null generates a random name. Reuse overwrites saved output.
    name: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    timeout: ?std.Io.Duration = null,
    /// Print the output paths before the command starts instead of after it exits.
    async: bool = false,
    /// Never kill the command for oversized output.
    unlimited: bool = false,
    /// Lines of the stdout file to print after the command exits.
    stdout: Excerpt = .{},
    /// Lines of the stderr file to print after the command exits.
    stderr: Excerpt = .{},

    pub const Error = error{
        ConflictingOutputFlags,
        MissingCommand,
        MissingRunId,
        MissingValue,
        InvalidTimeout,
        InvalidName,
        InvalidDirectory,
        InvalidLineCount,
        ConflictingHeadFlags,
        ConflictingTailFlags,
        UnknownFlag,
        UnexpectedValue,
        UnexpectedArgument,
    };

    /// Borrows the arguments involved in a parse failure.
    pub const Diagnostic = struct {
        argument: []const u8 = "",
        value: []const u8 = "",
        conflicting: []const u8 = "",
        command: Command = .run,

        pub fn write(diagnostic: Diagnostic, err: Error, out: *std.Io.Writer) !void {
            switch (err) {
                error.ConflictingOutputFlags => try out.writeAll("--async and --json cannot be used together"),
                error.MissingCommand => try out.writeAll(
                    "missing command; pass one quoted shell command after the options",
                ),
                error.MissingRunId => try out.writeAll("missing run ID; pass one saved run ID after the options"),
                error.MissingValue => try out.print("option '{s}' requires a value", .{diagnostic.argument}),
                error.InvalidName => {
                    try out.print(
                        "invalid run name '{s}'; use 1–64 ASCII letters, digits, hyphens, or underscores; last is reserved",
                        .{diagnostic.value},
                    );
                    if (builtin.os.tag == .windows) try out.writeAll("; Windows device names are also reserved");
                },
                error.InvalidDirectory => try out.writeAll("working directory must not be empty"),
                error.InvalidTimeout => try out.print(
                    "invalid timeout '{s}' for '{s}'; use a positive integer with ms, s, m, or h (for example, 30s); " ++
                        "bare integers mean seconds; maximum count is {d}",
                    .{ diagnostic.value, diagnostic.argument, std.math.maxInt(u32) },
                ),
                error.InvalidLineCount => try out.print(
                    "invalid line count '{s}' for '{s}'; expected an integer from 1 to {d}",
                    .{ diagnostic.value, diagnostic.argument, std.math.maxInt(u32) },
                ),
                inline error.ConflictingHeadFlags, error.ConflictingTailFlags => |conflict| {
                    const kind = if (conflict == error.ConflictingHeadFlags) "head" else "tail";
                    try out.print(
                        "option '{s}' conflicts with '{s}'; use --" ++ kind ++ " for both outputs, " ++
                            "or --out:" ++ kind ++ " and/or --err:" ++ kind ++ " for individual outputs",
                        .{ diagnostic.argument, diagnostic.conflicting },
                    );
                },
                error.UnknownFlag => try out.print(
                    "unknown {s} option '{s}'",
                    .{ @tagName(diagnostic.command), diagnostic.argument },
                ),
                error.UnexpectedValue => try out.print("option '{s}' does not take a value", .{diagnostic.argument}),
                error.UnexpectedArgument => try out.print("unexpected argument '{s}'; {s}", .{
                    diagnostic.argument,
                    switch (diagnostic.command) {
                        .last => "fb last takes only reporting options",
                        .print => "pass exactly one saved run ID, with all fb options before it",
                        else => "pass exactly one quoted shell command, with all fb options before it",
                    },
                }),
            }
            try out.writeByte('\n');
        }
    };

    const Option = enum {
        help,
        timeout,
        name,
        cwd,
        async,
        unlimited,
        json,
        head,
        tail,
        out_head,
        out_tail,
        err_head,
        err_tail,

        const names = std.StaticStringMap(Option).initComptime(.{
            .{ "--name", .name },
            .{ "-n", .name },
            .{ "-C", .cwd },
            .{ "-t", .timeout },
            .{ "--timeout", .timeout },
            .{ "-a", .async },
            .{ "--async", .async },
            .{ "-u", .unlimited },
            .{ "--unlimited", .unlimited },
            .{ "--json", .json },
            .{ "-h", .help },
            .{ "--help", .help },
            .{ "-d", .head },
            .{ "--head", .head },
            .{ "-l", .tail },
            .{ "--tail", .tail },
            .{ "-o:d", .out_head },
            .{ "--out:head", .out_head },
            .{ "-o:l", .out_tail },
            .{ "--out:tail", .out_tail },
            .{ "-e:d", .err_head },
            .{ "--err:head", .err_head },
            .{ "-e:l", .err_tail },
            .{ "--err:tail", .err_tail },
        });

        fn takesValue(option: Option) bool {
            return switch (option) {
                .async, .unlimited, .help, .json => false,
                else => true,
            };
        }

        /// Which excerpt an option sets and for which streams; null for other options.
        fn lines(option: Option) ?Lines {
            return switch (option) {
                .head => .{ .kind = .head, .streams = .both },
                .tail => .{ .kind = .tail, .streams = .both },
                .out_head => .{ .kind = .head, .streams = .stdout },
                .out_tail => .{ .kind = .tail, .streams = .stdout },
                .err_head => .{ .kind = .head, .streams = .stderr },
                .err_tail => .{ .kind = .tail, .streams = .stderr },
                else => null,
            };
        }
    };

    const Lines = struct {
        kind: enum { head, tail },
        streams: Streams,
    };

    const Streams = enum { both, stdout, stderr };

    /// A head or tail count addresses both streams or individual streams, never a mix.
    const Scope = struct {
        streams: ?Streams = null,
        /// The flag that chose the scope, reported when a later flag conflicts with it.
        flag: []const u8 = "",

        fn select(scope: *Scope, streams: Streams, flag: []const u8) bool {
            if (scope.streams) |previous| {
                if ((previous == .both) != (streams == .both)) return false;
            }
            scope.* = .{ .streams = streams, .flag = flag };

            return true;
        }
    };

    pub const ParseOptions = struct {
        diagnostic: ?*Diagnostic = null,
    };

    /// Parses `run` arguments, `last` reporting options without shell source, or
    /// `print` reporting options followed by one saved run ID (stored in `name`).
    /// Argument slices are borrowed; a failure is described in the optional diagnostic.
    pub fn parse(comptime command: Command, args: []const [:0]const u8, opts: ParseOptions) Error!Run {
        comptime std.debug.assert(command == .run or command == .last or command == .print);

        const diag = opts.diagnostic;
        if (diag) |d| d.* = .{ .command = command };

        var run: Run = .{};
        var head_scope: Scope = .{};
        var tail_scope: Scope = .{};
        var rest = args;

        while (rest.len > 0 and std.mem.startsWith(u8, rest[0], "-")) {
            const flag = rest[0];
            const separator = std.mem.indexOfScalar(u8, flag, '=');
            const name = flag[0 .. separator orelse flag.len];
            if (diag) |d| d.* = .{ .argument = name, .command = command };

            const option = Option.names.get(name) orelse return error.UnknownFlag;
            if (!command.acceptsOption(option)) return error.UnknownFlag;

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
            if (diag) |d| d.value = value;

            switch (option) {
                .help => {
                    run.help = true;
                    return run;
                },
                .name => {
                    if (!dir.validRunName(value)) return error.InvalidName;
                    run.name = value;
                },
                .cwd => {
                    if (value.len == 0) return error.InvalidDirectory;
                    run.cwd = value;
                },
                .timeout => run.timeout = try parseTimeout(value),
                .async => run.async = true,
                .unlimited => run.unlimited = true,
                .json => run.style = .json,
                inline .head, .tail, .out_head, .out_tail, .err_head, .err_tail => |selected| {
                    const lines = comptime selected.lines().?;
                    const scope = if (lines.kind == .head) &head_scope else &tail_scope;
                    if (!scope.select(lines.streams, name)) {
                        if (diag) |d| d.conflicting = scope.flag;
                        return switch (lines.kind) {
                            .head => error.ConflictingHeadFlags,
                            .tail => error.ConflictingTailFlags,
                        };
                    }

                    const count = try parsePositive(u32, value, error.InvalidLineCount);
                    if (lines.streams != .stderr) @field(run.stdout, @tagName(lines.kind)) = count;
                    if (lines.streams != .stdout) @field(run.stderr, @tagName(lines.kind)) = count;
                },
            }
        }

        if (run.async and run.style == .json) return error.ConflictingOutputFlags;

        switch (command) {
            .last => {
                if (rest.len != 0) {
                    if (diag) |d| d.argument = rest[0];
                    return error.UnexpectedArgument;
                }
            },
            .print => {
                if (rest.len == 0) return error.MissingRunId;
                if (rest.len > 1) {
                    if (diag) |d| d.argument = rest[1];
                    return error.UnexpectedArgument;
                }
                if (diag) |d| d.value = rest[0];
                if (!dir.validRunName(rest[0])) return error.InvalidName;
                run.name = rest[0];
            },
            else => {
                if (rest.len == 0) return error.MissingCommand;
                if (rest.len > 1) {
                    if (diag) |d| d.argument = rest[1];
                    return error.UnexpectedArgument;
                }
                run.source = rest[0];
            },
        }

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
    const count = try parsePositive(u32, digits, error.InvalidTimeout);

    return .fromNanoseconds(@as(i96, count) * unit.nanoseconds());
}

/// Parses a non-zero decimal integer, reporting `invalid` for anything else.
fn parsePositive(comptime T: type, text: []const u8, comptime invalid: Run.Error) Run.Error!T {
    const value = std.fmt.parseUnsigned(T, text, 10) catch return invalid;
    if (value == 0) return invalid;

    return value;
}

test "run argument parsing" {
    const t = std.testing;

    const bare = try Run.parse(.run, &.{"echo hello"}, .{});
    try t.expectEqualStrings("echo hello", bare.source);
    try t.expectEqual(null, bare.timeout);
    try t.expectEqual(false, bare.async);

    inline for (.{ "-a", "--async" }) |flag| {
        const run = try Run.parse(.run, &.{ flag, "-t", "5", "echo hello" }, .{});
        try t.expectEqual(true, run.async);
        try t.expectEqual(std.Io.Duration.fromNanoseconds(std.time.ns_per_s * 5), run.timeout.?);
        try t.expectEqualStrings("echo hello", run.source);
    }
    try t.expectError(error.UnexpectedValue, Run.parse(.run, &.{ "--async=1", "echo hello" }, .{}));

    const both = try Run.parse(.run, &.{ "--head", "3", "--tail=7", "echo hello" }, .{});
    try t.expectEqual(Excerpt{ .head = 3, .tail = 7 }, both.stdout);
    try t.expectEqual(Excerpt{ .head = 3, .tail = 7 }, both.stderr);

    const single = try Run.parse(.run, &.{ "-o:d", "1", "--err:tail", "2", "-e:d=4", "--out:tail=8", "echo hello" }, .{});
    try t.expectEqual(Excerpt{ .head = 1, .tail = 8 }, single.stdout);
    try t.expectEqual(Excerpt{ .head = 4, .tail = 2 }, single.stderr);

    try t.expectError(error.MissingValue, Run.parse(.run, &.{"-d"}, .{}));
    inline for (.{ "0", "", "-1", "x", "1s" }) |invalid| {
        try t.expectError(error.InvalidLineCount, Run.parse(.run, &.{ "--tail", invalid, "echo hello" }, .{}));
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
            const separate = try Run.parse(.run, &.{ flag, case[0], "echo hello" }, .{});
            const joined = try Run.parse(.run, &.{ flag ++ "=" ++ case[0], "echo hello" }, .{});

            try t.expectEqual(expected, separate.timeout.?);
            try t.expectEqual(expected, joined.timeout.?);
            try t.expectEqualStrings("echo hello", separate.source);
            try t.expectEqualStrings("echo hello", joined.source);
        }
    }

    try t.expectError(error.MissingCommand, Run.parse(.run, &.{}, .{}));
    try t.expectError(error.MissingCommand, Run.parse(.run, &.{ "--timeout", "5" }, .{}));
    try t.expectError(error.MissingValue, Run.parse(.run, &.{"--timeout"}, .{}));
    try t.expectError(error.MissingValue, Run.parse(.run, &.{"-t"}, .{}));
    try t.expectError(error.UnknownFlag, Run.parse(.run, &.{ "-x", "echo hello" }, .{}));
    try t.expectError(error.UnknownFlag, Run.parse(.run, &.{ "--quiet", "echo hello" }, .{}));
    try t.expectError(error.UnknownFlag, Run.parse(.run, &.{ "--timeoutish=5", "echo hello" }, .{}));
    try t.expectError(error.UnexpectedArgument, Run.parse(.run, &.{ "echo hello", "extra" }, .{}));

    inline for (.{ "0", "0s", "", "s", "-5", "5x", "5 s" }) |invalid| {
        try t.expectError(error.InvalidTimeout, Run.parse(.run, &.{ "--timeout", invalid, "echo hello" }, .{}));
    }
}

test "head flag scopes are mutually exclusive" {
    const t = std.testing;

    inline for (.{ "--head", "-d" }) |general| {
        const both = try Run.parse(.run, &.{ general, "3", "echo hello" }, .{});
        try t.expectEqual(Excerpt{ .head = 3 }, both.stdout);
        try t.expectEqual(Excerpt{ .head = 3 }, both.stderr);

        inline for (.{ "--out:head", "-o:d", "--err:head", "-e:d" }) |specific| {
            try t.expectError(error.ConflictingHeadFlags, Run.parse(.run, &.{ general, "3", specific, "9", "echo hello" }, .{}));
            try t.expectError(error.ConflictingHeadFlags, Run.parse(.run, &.{ specific, "9", general, "3", "echo hello" }, .{}));
            try t.expectError(error.ConflictingHeadFlags, Run.parse(.run, &.{ general ++ "=3", specific ++ "=9", "echo hello" }, .{}));
            try t.expectError(error.ConflictingHeadFlags, Run.parse(.run, &.{ specific ++ "=9", general ++ "=3", "echo hello" }, .{}));
        }
    }

    inline for (.{ "--out:head", "-o:d" }) |out| {
        const stdout = try Run.parse(.run, &.{ out, "3", "echo hello" }, .{});
        try t.expectEqual(Excerpt{ .head = 3 }, stdout.stdout);
        try t.expectEqual(Excerpt{}, stdout.stderr);

        inline for (.{ "--err:head", "-e:d" }) |err| {
            const stderr = try Run.parse(.run, &.{ err, "9", "echo hello" }, .{});
            try t.expectEqual(Excerpt{}, stderr.stdout);
            try t.expectEqual(Excerpt{ .head = 9 }, stderr.stderr);

            const both = try Run.parse(.run, &.{ out, "3", err, "9", "echo hello" }, .{});
            const reversed = try Run.parse(.run, &.{ err ++ "=9", out ++ "=3", "echo hello" }, .{});
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
        const both = try Run.parse(.run, &.{ general, "3", "echo hello" }, .{});
        try t.expectEqual(Excerpt{ .tail = 3 }, both.stdout);
        try t.expectEqual(Excerpt{ .tail = 3 }, both.stderr);

        inline for (.{ "--out:tail", "-o:l", "--err:tail", "-e:l" }) |specific| {
            try t.expectError(error.ConflictingTailFlags, Run.parse(.run, &.{ general, "3", specific, "9", "echo hello" }, .{}));
            try t.expectError(error.ConflictingTailFlags, Run.parse(.run, &.{ specific, "9", general, "3", "echo hello" }, .{}));
            try t.expectError(error.ConflictingTailFlags, Run.parse(.run, &.{ general ++ "=3", specific ++ "=9", "echo hello" }, .{}));
            try t.expectError(error.ConflictingTailFlags, Run.parse(.run, &.{ specific ++ "=9", general ++ "=3", "echo hello" }, .{}));
        }
    }

    inline for (.{ "--out:tail", "-o:l" }) |out| {
        const stdout = try Run.parse(.run, &.{ out, "3", "echo hello" }, .{});
        try t.expectEqual(Excerpt{ .tail = 3 }, stdout.stdout);
        try t.expectEqual(Excerpt{}, stdout.stderr);

        inline for (.{ "--err:tail", "-e:l" }) |err| {
            const stderr = try Run.parse(.run, &.{ err, "9", "echo hello" }, .{});
            try t.expectEqual(Excerpt{}, stderr.stdout);
            try t.expectEqual(Excerpt{ .tail = 9 }, stderr.stderr);

            const both = try Run.parse(.run, &.{ out, "3", err, "9", "echo hello" }, .{});
            const reversed = try Run.parse(.run, &.{ err ++ "=9", out ++ "=3", "echo hello" }, .{});
            try t.expectEqual(Excerpt{ .tail = 3 }, both.stdout);
            try t.expectEqual(Excerpt{ .tail = 9 }, both.stderr);
            try t.expectEqual(both.stdout, reversed.stdout);
            try t.expectEqual(both.stderr, reversed.stderr);
        }
    }
}

test "repeated flags within a scope use the last count" {
    const t = std.testing;

    const both = try Run.parse(.run, &.{ "--head=1", "-d=2", "--tail=3", "-l=4", "echo hello" }, .{});
    try t.expectEqual(Excerpt{ .head = 2, .tail = 4 }, both.stdout);
    try t.expectEqual(both.stdout, both.stderr);

    const individual = try Run.parse(.run, &.{ "--out:head=1", "-o:d=2", "--err:tail=3", "-e:l=4", "echo hello" }, .{});
    try t.expectEqual(Excerpt{ .head = 2 }, individual.stdout);
    try t.expectEqual(Excerpt{ .tail = 4 }, individual.stderr);
}

test "head and tail scopes are independent" {
    const t = std.testing;

    const head = try Run.parse(.run, &.{ "--head", "3", "--out:tail", "5", "--err:tail", "7", "echo hello" }, .{});
    try t.expectEqual(Excerpt{ .head = 3, .tail = 5 }, head.stdout);
    try t.expectEqual(Excerpt{ .head = 3, .tail = 7 }, head.stderr);

    const tail = try Run.parse(.run, &.{ "--out:head", "5", "--err:head", "7", "--tail", "3", "echo hello" }, .{});
    try t.expectEqual(Excerpt{ .head = 5, .tail = 3 }, tail.stdout);
    try t.expectEqual(Excerpt{ .head = 7, .tail = 3 }, tail.stderr);
}

test "run diagnostics identify the offending arguments" {
    const t = std.testing;
    const cases = .{
        .{ &.{ "--head=1", "--out:head=2", "echo hello" }, error.ConflictingHeadFlags, "option '--out:head' conflicts with '--head'" },
        .{ &.{ "-e:l=2", "--tail", "1", "echo hello" }, error.ConflictingTailFlags, "option '--tail' conflicts with '-e:l'" },
        .{ &.{ "--head", "0", "echo hello" }, error.InvalidLineCount, "invalid line count '0' for '--head'" },
        .{ &.{ "-t=bad", "echo hello" }, error.InvalidTimeout, "invalid timeout 'bad' for '-t'" },
        .{ &.{ "echo hello", "extra" }, error.UnexpectedArgument, "unexpected argument 'extra'" },
    };
    inline for (cases) |case| {
        var diagnostic: Run.Diagnostic = .{};
        try t.expectError(case[1], Run.parse(.run, case[0], .{ .diagnostic = &diagnostic }));

        var out: std.Io.Writer.Allocating = .init(t.allocator);
        defer out.deinit();
        try diagnostic.write(case[1], &out.writer);
        try t.expect(std.mem.startsWith(u8, out.written(), case[2]));
    }
}

test "command parsing" {
    const t = std.testing;

    try t.expectEqual(null, parse(&.{}));

    inline for (.{ "-h", "--help" }) |name| {
        const help = parse(&.{name}).?;
        try t.expectEqual(BaseOption.help, help.option.?);
        try t.expectEqual(@as(usize, 0), help.args.len);

        const run_help = parse(&.{ "run", name }).?;
        try t.expectEqual(Command.run, run_help.command);
        try t.expectEqual(null, run_help.option);
        try t.expect((try Run.parse(.run, run_help.args, .{})).help);
        try t.expectError(error.UnexpectedValue, Run.parse(.run, &.{name ++ "=1"}, .{}));
    }

    const run_parsed = parse(&.{"echo hello"}).?;
    try t.expectEqual(Command.run, run_parsed.command);
    try t.expectEqualStrings("echo hello", run_parsed.args[0]);

    const run_explicit = parse(&.{ "run", "echo hello" }).?;
    try t.expectEqual(Command.run, run_explicit.command);
    try t.expectEqualStrings("echo hello", run_explicit.args[0]);

    inline for (.{ "--version", "-v" }) |name| {
        const v = parse(&.{name}).?;
        try t.expectEqual(BaseOption.version, v.option.?);
        try t.expectEqual(@as(usize, 0), v.args.len);

        const run_version = parse(&.{ "run", name }).?;
        try t.expectEqual(null, run_version.option);
        try t.expectError(error.UnknownFlag, Run.parse(.run, run_version.args, .{}));
    }

    inline for (&.{ "install", "init" }) |name| {
        const inst = parse(&.{ name, "claude" }).?;
        try t.expectEqual(Command.install, inst.command);
        try t.expectEqualStrings("claude", inst.args[0]);
    }

    const uninst = parse(&.{ "uninstall", "agents" }).?;
    try t.expectEqual(Command.uninstall, uninst.command);
    try t.expectEqualStrings("agents", uninst.args[0]);
}

test "json output option" {
    const t = std.testing;

    try t.expectEqual(.text, (try Run.parse(.run, &.{"true"}, .{})).style);
    try t.expectEqual(.json, (try Run.parse(.run, &.{ "--json", "true" }, .{})).style);
    try t.expectError(error.UnexpectedValue, Run.parse(.run, &.{ "--json=true", "true" }, .{}));
}

test "async and json are mutually exclusive" {
    const t = std.testing;

    try t.expectError(error.ConflictingOutputFlags, Run.parse(.run, &.{ "--async", "--json", "true" }, .{}));
    try t.expectError(error.ConflictingOutputFlags, Run.parse(.run, &.{ "--json", "--async", "true" }, .{}));
}

test "last accepts reporting options without shell source" {
    const t = std.testing;
    try t.expectEqual(Command.last, parse(&.{"last"}).?.command);
    const defaults = try Run.parse(.last, &.{}, .{});
    try t.expectEqual(Excerpt{}, defaults.stdout);
    try t.expectEqual(Output.Style.text, defaults.style);

    inline for (.{ "--head", "-d", "--tail", "-l", "--out:head", "-o:d", "--out:tail", "-o:l", "--err:head", "-e:d", "--err:tail", "-e:l" }) |flag| {
        const run = try Run.parse(.run, &.{ "--json", flag, "3", "echo hello" }, .{});
        const last = try Run.parse(.last, &.{ "--json", flag ++ "=3" }, .{});
        try t.expectEqual(run.stdout, last.stdout);
        try t.expectEqual(run.stderr, last.stderr);
        try t.expectEqual(run.style, last.style);
    }
    try t.expectError(error.UnknownFlag, Run.parse(.last, &.{"--async"}, .{}));
    try t.expectError(error.UnknownFlag, Run.parse(.last, &.{ "--timeout", "5s" }, .{}));
    try t.expectError(error.UnexpectedArgument, Run.parse(.last, &.{"echo hello"}, .{}));
    try t.expectError(error.MissingValue, Run.parse(.last, &.{"--head"}, .{}));
    try t.expectError(error.InvalidLineCount, Run.parse(.last, &.{"--tail=0"}, .{}));
    try t.expectError(error.ConflictingHeadFlags, Run.parse(.last, &.{ "--head=1", "--out:head=2" }, .{}));
    try t.expectError(error.ConflictingTailFlags, Run.parse(.last, &.{ "--err:tail=1", "--tail=2" }, .{}));
}

test "print accepts reporting options followed by one valid run ID" {
    const t = std.testing;
    try t.expectEqual(Command.print, parse(&.{ "print", "build_1" }).?.command);

    const parsed = try Run.parse(.print, &.{ "--json", "--out:tail=3", "build_1" }, .{});
    try t.expectEqual(Output.Style.json, parsed.style);
    try t.expectEqual(3, parsed.stdout.tail);
    try t.expectEqualStrings("build_1", parsed.name.?);

    try t.expectError(error.MissingRunId, Run.parse(.print, &.{}, .{}));
    try t.expectError(error.InvalidName, Run.parse(.print, &.{"../build"}, .{}));
    try t.expectError(error.UnexpectedArgument, Run.parse(.print, &.{ "build", "extra" }, .{}));
    try t.expectError(error.UnknownFlag, Run.parse(.print, &.{ "--name", "build", "saved" }, .{}));
}

test "named runs accept portable names and reject paths and reserved names" {
    const t = std.testing;
    inline for (.{ "--name", "-n" }) |flag| {
        try t.expectEqualStrings("build_1-debug", (try Run.parse(.run, &.{ flag, "build_1-debug", "true" }, .{})).name.?);
        try t.expectEqualStrings("build", (try Run.parse(.run, &.{ flag ++ "=build", "true" }, .{})).name.?);
        try t.expectError(error.MissingValue, Run.parse(.run, &.{flag}, .{}));
        try t.expectError(error.UnknownFlag, Run.parse(.last, &.{ flag, "build" }, .{}));
    }
    inline for (.{ "", ".", "..", "../build", "a/b", "a\\b", "C:build", "last", "LAST", "build.", "two words", "x" ** 65 }) |name| {
        try t.expectError(error.InvalidName, Run.parse(.run, &.{ "--name", name, "true" }, .{}));
    }
    inline for (.{ "CON", "NUL", "com1", "LPT9" }) |name| {
        if (builtin.os.tag == .windows) {
            try t.expectError(error.InvalidName, Run.parse(.run, &.{ "--name", name, "true" }, .{}));
        } else {
            try t.expectEqualStrings(name, (try Run.parse(.run, &.{ "--name", name, "true" }, .{})).name.?);
        }
    }
    try t.expectEqual(null, (try Run.parse(.run, &.{"true"}, .{})).name);
}

test "working directory arguments" {
    const t = std.testing;
    const parsed = try Run.parse(.run, &.{ "-C", ".", "pwd" }, .{});
    try t.expectEqualStrings(".", parsed.cwd.?);
    const equals = try Run.parse(.run, &.{ "-C=.", "pwd" }, .{});
    try t.expectEqualStrings(".", equals.cwd.?);
    try t.expectEqual(null, (try Run.parse(.run, &.{"pwd"}, .{})).cwd);
    try t.expectError(error.MissingValue, Run.parse(.run, &.{"-C"}, .{}));
    try t.expectError(error.InvalidDirectory, Run.parse(.run, &.{ "-C=", "pwd" }, .{}));
    try t.expectError(error.UnknownFlag, Run.parse(.last, &.{ "-C", "relative" }, .{}));
}

test "unlimited output size flag" {
    const t = std.testing;

    try t.expectEqual(false, (try Run.parse(.run, &.{"true"}, .{})).unlimited);
    inline for (.{ "-u", "--unlimited" }) |flag| {
        try t.expectEqual(true, (try Run.parse(.run, &.{ flag, "true" }, .{})).unlimited);
        try t.expectError(error.UnexpectedValue, Run.parse(.run, &.{ flag ++ "=1", "true" }, .{}));
        try t.expectError(error.UnknownFlag, Run.parse(.last, &.{flag}, .{}));
        try t.expectError(error.UnknownFlag, Run.parse(.print, &.{ flag, "build" }, .{}));
    }
}
