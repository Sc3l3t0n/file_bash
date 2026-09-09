const std = @import("std");
const builtin = @import("builtin");

const Child = @This();

process: std.process.Child,
timeout: ?std.Io.Duration,

pub const Options = struct {
    argv: []const []const u8,
    /// Inherited by the child after the non-interactive overrides are applied.
    environ: *const std.process.Environ.Map,
    stdout: std.Io.File,
    stderr: std.Io.File,
    /// Kills the command once the duration elapses; unbounded when null.
    timeout: ?std.Io.Duration,
};

/// Spawns the command with its output streams redirected to the given files.
/// The child environment is allocated in `arena`.
pub fn spawn(io: std.Io, arena: std.mem.Allocator, options: Options) !Child {
    var environ = try nonInteractive(arena, options.environ);

    return .{
        .process = try std.process.spawn(io, .{
            .argv = options.argv,
            .environ_map = &environ,
            .stdout = .{ .file = options.stdout },
            .stderr = .{ .file = options.stderr },
            // A timed run leads its own process group so a timeout can kill
            // the whole command tree; without one, signals keep reaching the
            // child.
            .pgid = if (options.timeout == null) null else 0,
        }),
        .timeout = options.timeout,
    };
}

pub const Status = struct {
    code: u8,
    timed_out: bool,

    /// Matches the exit code `timeout(1)` reports for an expired command.
    pub const timeout_code: u8 = 124;

    fn fromTerm(term: std.process.Child.Term) Status {
        return .{
            .code = switch (term) {
                .exited => |code| code,
                .signal, .stopped => |signal| @intCast(@min(255, 128 + @as(u32, @intFromEnum(signal)))),
                .unknown => 1,
            },
            .timed_out = false,
        };
    }
};

/// Waits for the command, terminating it when its timeout elapses first. The
/// child is reaped in either case. Call once per spawned child.
pub fn wait(child: *Child, io: std.Io) !Status {
    if (child.timeout) |timeout| return child.waitTimeout(io, timeout);

    return .fromTerm(try child.process.wait(io));
}

fn waitTimeout(child: *Child, io: std.Io, timeout: std.Io.Duration) !Status {
    // The identifier is still set because the child was spawned and has not
    // been waited on yet. Terminating uses it directly because only the
    // pending wait may reap the child.
    const id = child.process.id.?;

    var events: [2]Event = undefined;
    var select: std.Io.Select(Event) = .init(io, &events);
    defer select.cancelDiscard();

    try select.concurrent(.finished, waitProcess, .{ io, &child.process });
    select.async(.expired, expire, .{ io, timeout });

    switch (try select.await()) {
        .finished => |result| return .fromTerm(try result),
        .expired => |result| {
            try result;
            try terminate(id);

            return switch (try select.await()) {
                .finished => |result_after_kill| {
                    _ = try result_after_kill;
                    return .{ .code = Status.timeout_code, .timed_out = true };
                },
                .expired => unreachable,
            };
        },
    }
}

const Override = struct { key: []const u8, value: []const u8 };

/// Nothing is attached to a terminal and no prompt can be answered, so tell
/// commands that up front instead of letting them wait for input or emit
/// escape sequences into the output files.
const shared_overrides = [_]Override{
    .{ .key = "NO_COLOR", .value = "1" },
    .{ .key = "CLICOLOR", .value = "0" },
    .{ .key = "GIT_TERMINAL_PROMPT", .value = "0" },
};

const unix_overrides = shared_overrides ++ [_]Override{
    .{ .key = "TERM", .value = "dumb" },
    .{ .key = "PAGER", .value = "cat" },
    .{ .key = "GIT_PAGER", .value = "cat" },
};

const linux_overrides = unix_overrides ++ [_]Override{
    .{ .key = "DEBIAN_FRONTEND", .value = "noninteractive" },
};

const overrides: []const Override = switch (builtin.os.tag) {
    .linux => &linux_overrides,
    .macos => &unix_overrides,
    // `cmd.exe` and PowerShell have no `TERM` or pager conventions.
    .windows => &shared_overrides,
    else => &shared_overrides,
};

/// Copies `parent` and applies the overrides, which always win over inherited
/// values.
fn nonInteractive(
    arena: std.mem.Allocator,
    parent: *const std.process.Environ.Map,
) !std.process.Environ.Map {
    var map = try parent.clone(arena);
    for (overrides) |override| try map.put(override.key, override.value);

    return map;
}

test "child environment is non-interactive" {
    var parent: std.process.Environ.Map = .init(std.testing.allocator);
    defer parent.deinit();

    try parent.put("PATH", "/usr/bin");
    try parent.put("NO_COLOR", "0");

    var child_environ = try nonInteractive(std.testing.allocator, &parent);
    defer child_environ.deinit();

    try std.testing.expectEqualStrings("/usr/bin", child_environ.get("PATH").?);
    // Only `PATH` is inherited; `NO_COLOR` is replaced rather than duplicated.
    try std.testing.expectEqual(overrides.len + 1, child_environ.count());
    for (overrides) |override| {
        try std.testing.expectEqualStrings(override.value, child_environ.get(override.key).?);
    }
}

const Waited = std.process.Child.WaitError!std.process.Child.Term;

const Event = union(enum) {
    finished: Waited,
    expired: std.Io.Cancelable!void,
};

fn waitProcess(io: std.Io, process: *std.process.Child) Waited {
    return process.wait(io);
}

fn expire(io: std.Io, timeout: std.Io.Duration) std.Io.Cancelable!void {
    return io.sleep(timeout, .awake);
}

/// Exit status reported for a child that fb terminated on Windows.
const terminated_exit_status: std.os.windows.NTSTATUS = @enumFromInt(1);

/// Requests immediate termination without reaping the child. On POSIX the
/// child's whole process group is signalled, so descendants die with it.
fn terminate(id: std.process.Child.Id) !void {
    switch (builtin.os.tag) {
        .windows => switch (std.os.windows.ntdll.NtTerminateProcess(id, terminated_exit_status)) {
            .SUCCESS, .PROCESS_IS_TERMINATING => {},
            else => |status| return std.os.windows.unexpectedStatus(status),
        },
        else => try std.posix.kill(-id, .KILL),
    }
}
