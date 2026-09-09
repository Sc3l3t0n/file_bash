const std = @import("std");
const builtin = @import("builtin");

const Child = @This();

process: std.process.Child,
timeout: ?std.Io.Duration,

pub const Options = struct {
    argv: []const []const u8,
    stdout: std.Io.File,
    stderr: std.Io.File,
    /// Kills the command once the duration elapses; unbounded when null.
    timeout: ?std.Io.Duration,
};

/// Spawns the command with its output streams redirected to the given files.
pub fn spawn(io: std.Io, options: Options) !Child {
    return .{
        .process = try std.process.spawn(io, .{
            .argv = options.argv,
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
