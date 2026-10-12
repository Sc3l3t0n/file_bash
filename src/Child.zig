const std = @import("std");
const builtin = @import("builtin");
const Output = @import("Output.zig");

const windows = std.os.windows;

const Child = @This();

process: std.process.Child,
/// Job holding a bounded command and its descendants on Windows, so a kill
/// reaches the whole command tree; null for an unbounded run.
job: Job,
timeout: ?std.Io.Duration,
max_size: ?u64,
/// Borrowed file receiving the command's stdout; measured while the command runs.
stdout: std.Io.File,
/// Borrowed file receiving the command's stderr; measured while the command runs.
stderr: std.Io.File,
/// Monotonic time taken right after the process started.
started: std.Io.Timestamp,

pub const Options = struct {
    argv: []const []const u8,
    /// Borrowed directory handle; the caller retains ownership.
    cwd: ?std.Io.Dir = null,
    /// Inherited by the child after the non-interactive overrides are applied.
    environ: *const std.process.Environ.Map,
    stdout: std.Io.File,
    stderr: std.Io.File,
    /// Kills the command once the duration elapses; unbounded when null.
    timeout: ?std.Io.Duration,
    /// Kills the command once either output file exceeds this many bytes; unbounded when null.
    max_size: ?u64,
};

/// Spawns the command with its output streams redirected to the given files.
/// The child environment is allocated in `arena`.
pub fn spawn(io: std.Io, arena: std.mem.Allocator, options: Options) !Child {
    var environ = try nonInteractive(arena, options.environ);
    const bounded = options.timeout != null or options.max_size != null;
    const job: Job = if (builtin.os.tag == .windows and bounded) try createJob() else null;
    errdefer closeJob(job);

    var process = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = if (options.cwd) |cwd| .{ .dir = cwd } else .inherit,
        .environ_map = &environ,
        .stdout = .{ .file = options.stdout },
        .stderr = .{ .file = options.stderr },
        // The null device gives commands that read stdin end-of-file.
        .stdin = .ignore,
        // A bounded run leads its own process group so a kill reaches the
        // whole command tree; without a bound, signals keep reaching the
        // child.
        .pgid = if (builtin.os.tag == .windows or !bounded) null else 0,
        // On Windows the command joins its job before it can start descendants.
        .start_suspended = job != null,
    });
    if (job) |handle| try joinJob(io, handle, &process);

    return .{
        .process = process,
        .job = job,
        .timeout = options.timeout,
        .max_size = options.max_size,
        .stdout = options.stdout,
        .stderr = options.stderr,
        .started = clock.now(io),
    };
}

/// Measures how long the command ran; unaffected by wall-clock adjustments.
const clock: std.Io.Clock = .awake;

/// How often the output files are measured against the size limit.
const poll_interval: std.Io.Duration = .fromMilliseconds(20);

pub const Status = struct {
    code: u8,
    timed_out: bool = false,
    /// The stream whose file outgrew the size limit, when the command was killed for it.
    oversized: ?Output.StreamType = null,
    /// Time from spawn until the child was reaped.
    duration: std.Io.Duration = .zero,

    /// Exit codes reported when fb kills the command.
    pub const KillCode = enum(u8) {
        /// Matches the exit code `timeout(1)` reports for an expired command.
        timeout = 124,
        /// Matches the code a shell reports for `SIGXFSZ`, the file size limit signal.
        oversized = 153,
    };

    fn fromTerm(term: std.process.Child.Term) Status {
        return .{
            .code = switch (term) {
                .exited => |code| code,
                .signal, .stopped => |signal| @intCast(@min(255, 128 + @as(u32, @backingInt(signal)))),
                .unknown => 1,
            },
        };
    }

    fn fromKill(kill: Kill) Status {
        return switch (kill) {
            .timeout => .{ .code = @backingInt(KillCode.timeout), .timed_out = true },
            .oversized => |stream| .{ .code = @backingInt(KillCode.oversized), .oversized = stream },
        };
    }
};

/// Why fb terminated the command before it exited on its own.
const Kill = union(enum) {
    timeout,
    oversized: Output.StreamType,
};

/// Waits for the command, terminating it when its timeout elapses or an output
/// file outgrows the size limit first. The child is reaped in either case.
/// Call once per spawned child.
pub fn wait(child: *Child, io: std.Io) !Status {
    defer closeJob(child.job);

    var status: Status = if (child.timeout != null or child.max_size != null)
        try child.waitBounded(io)
    else
        .fromTerm(try child.process.wait(io));
    status.duration = child.started.durationTo(clock.now(io));

    return status;
}

const Waited = std.process.Child.WaitError!std.process.Child.Term;

const Event = union(enum) {
    finished: Waited,
    expired: std.Io.Cancelable!void,
    oversized: std.Io.File.StatError!?Output.StreamType,
};

fn waitProcess(io: std.Io, process: *std.process.Child) Waited {
    return process.wait(io);
}

fn expire(io: std.Io, timeout: std.Io.Duration) std.Io.Cancelable!void {
    return io.sleep(timeout, .awake);
}

/// Polls both files until one exceeds `max_size` and names it. Cancellation
/// ends here with null; it only happens once the select no longer awaits.
fn watchSize(
    io: std.Io,
    stdout: std.Io.File,
    stderr: std.Io.File,
    max_size: u64,
) std.Io.File.StatError!?Output.StreamType {
    const files = [_]std.Io.File{ stdout, stderr };
    const names = [_]Output.StreamType{ .stdout, .stderr };

    while (true) {
        io.sleep(poll_interval, .awake) catch return null;
        for (files, names) |file, name| {
            if ((try file.stat(io)).size > max_size) return name;
        }
    }
}

fn waitBounded(child: *Child, io: std.Io) !Status {
    // The identifier is still set because the child was spawned and has not
    // been waited on yet. Terminating uses it directly because only the
    // pending wait may reap the child. On Windows the job stands in for the
    // process group.
    const id = if (builtin.os.tag == .windows) child.job.? else child.process.id.?;

    var events: [3]Event = undefined;
    var select: std.Io.Select(Event) = .init(io, &events);
    defer select.cancelDiscard();

    try select.concurrent(.finished, waitProcess, .{ io, &child.process });
    if (child.timeout) |timeout| select.async(.expired, expire, .{ io, timeout });
    if (child.max_size) |max_size| {
        try select.concurrent(.oversized, watchSize, .{ io, child.stdout, child.stderr, max_size });
    }

    // Both bounds may fire before the reap completes; only the first one kills.
    var kill: ?Kill = null;
    while (true) {
        const reason: Kill = switch (try select.await()) {
            .finished => |result| {
                const status: Status = .fromTerm(try result);
                return if (kill) |first| .fromKill(first) else status;
            },
            .expired => |result| expired: {
                try result;
                break :expired .timeout;
            },
            .oversized => |result| .{ .oversized = (try result) orelse continue },
        };
        if (kill == null) {
            kill = reason;
            try terminate(id);
        }
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

/// Exit code reported for a command that fb terminated on Windows.
const terminated_exit_code: windows.UINT = 1;

/// Requests immediate termination without reaping the child. On POSIX the
/// child's whole process group is signalled; on Windows the whole job is
/// terminated. Either way descendants die with the child.
fn terminate(id: std.process.Child.Id) !void {
    switch (builtin.os.tag) {
        .windows => if (!job_api.TerminateJobObject(id, terminated_exit_code).toBool()) {
            return windows.unexpectedError(windows.GetLastError());
        },
        else => try std.posix.kill(-id, .KILL),
    }
}

const Job = ?windows.HANDLE;

/// Job object functions that `std.os.windows` does not declare.
const job_api = struct {
    extern "kernel32" fn CreateJobObjectW(
        lpJobAttributes: ?*windows.SECURITY_ATTRIBUTES,
        lpName: ?[*:0]const u16,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(
        hJob: windows.HANDLE,
        hProcess: windows.HANDLE,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateJobObject(
        hJob: windows.HANDLE,
        uExitCode: windows.UINT,
    ) callconv(.winapi) windows.BOOL;
};

fn createJob() !windows.HANDLE {
    return job_api.CreateJobObjectW(null, null) orelse windows.unexpectedError(windows.GetLastError());
}

/// Assigns the suspended process to the job and resumes it. A process that
/// cannot join is killed and reaped, because fb could not stop its descendants.
fn joinJob(io: std.Io, job: windows.HANDLE, process: *std.process.Child) !void {
    if (!job_api.AssignProcessToJobObject(job, process.id.?).toBool()) {
        const err = windows.GetLastError();
        process.kill(io);
        return windows.unexpectedError(err);
    }
    switch (windows.ntdll.NtResumeThread(process.thread_handle, null)) {
        .SUCCESS => {},
        else => |status| {
            process.kill(io);
            return windows.unexpectedStatus(status);
        },
    }
}

fn closeJob(job: Job) void {
    if (builtin.os.tag != .windows) return;
    if (job) |handle| windows.CloseHandle(handle);
}

test "child environment is non-interactive" {
    const t = std.testing;
    var parent: std.process.Environ.Map = .init(t.allocator);
    defer parent.deinit();

    try parent.put("PATH", "/usr/bin");
    try parent.put("NO_COLOR", "0");

    var child_environ = try nonInteractive(t.allocator, &parent);
    defer child_environ.deinit();

    try t.expectEqualStrings("/usr/bin", child_environ.get("PATH").?);
    // Only `PATH` is inherited; `NO_COLOR` is replaced rather than duplicated.
    try t.expectEqual(overrides.len + 1, child_environ.count());
    for (overrides) |override| {
        try t.expectEqualStrings(override.value, child_environ.get(override.key).?);
    }
}

test "child reads end-of-file from standard input" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stdout = try tmp.dir.createFile(io, "stdout", .{});
    defer stdout.close(io);
    const stderr = try tmp.dir.createFile(io, "stderr", .{});
    defer stderr.close(io);
    const environ: std.process.Environ.Map = .init(arena);

    // `read` reports a bad descriptor on stderr when stdin is closed.
    var child = try spawn(io, arena, .{
        .argv = &.{ "/bin/sh", "-c", "read -r line" },
        .environ = &environ,
        .stdout = stdout,
        .stderr = stderr,
        .timeout = null,
        .max_size = null,
    });
    const status = try child.wait(io);

    try t.expectEqual(1, status.code);
    try t.expectEqual(0, (try stderr.stat(io)).size);
}
