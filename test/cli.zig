//! CLI tests: run the built fb as a child process and check only its documented
//! behavior. Each test gets its own temporary and home directory and a minimal
//! environment. Commands passed to fb call the fixture program found on PATH,
//! so they behave the same in every shell.
const std = @import("std");
const builtin = @import("builtin");
const test_options = @import("test_options");

const t = std.testing;
const io = t.io;

const fixture = test_options.fixture_name;

/// Bytes on fb's standard input that must never reach the command.
const unread_input = "input fb must not pass to the command\n";

/// Variables a Windows shell needs to start and to find the fixture.
const windows_inherited = [_][]const u8{ "SystemRoot", "ComSpec", "PATHEXT" };

const Result = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// Mirrors fb's `--json` output; unknown fields fail the parse.
const Report = struct {
    command: ?[]const u8,
    stdout: Stream,
    stderr: Stream,
    exit_code: ?u8,
    timed_out: bool,
    oversized: ?[]const u8,
    duration_ns: u64,

    const Stream = struct {
        path: []const u8,
        size: u64,
        head: ?[]const u8 = null,
        tail: ?[]const u8 = null,
    };

    /// The run directory holding both output files.
    fn directory(report: Report) []const u8 {
        return std.fs.path.dirname(report.stdout.path).?;
    }
};

const Sandbox = struct {
    arena: std.mem.Allocator,
    tmp: t.TmpDir,
    /// Absolute path of `tmp`, used as the temporary and home directory.
    path: []const u8,
    /// Absolute path of the built fb; the build passes it relative to the build root.
    fb_path: []const u8,
    environ: std.process.Environ.Map,

    fn init(arena: std.mem.Allocator) !Sandbox {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();

        const buffer = try arena.alloc(u8, std.fs.max_path_bytes);
        const path = buffer[0..try tmp.dir.realPath(io, buffer)];
        try tmp.dir.writeFile(io, .{ .sub_path = "stdin", .data = unread_input });

        const cwd = std.Io.Dir.cwd();
        const fb_path = try cwd.realPathFileAlloc(io, test_options.fb_path, arena);
        const fixture_directory = try cwd.realPathFileAlloc(io, test_options.fixture_directory, arena);

        var environ: std.process.Environ.Map = .init(arena);
        const inherited_path = try t.environ.getAlloc(arena, "PATH");
        try environ.put("PATH", try std.fmt.allocPrint(arena, "{s}{c}{s}", .{
            fixture_directory,
            std.fs.path.delimiter,
            inherited_path,
        }));
        for ([_][]const u8{ "TMPDIR", "TMP", "HOME", "USERPROFILE" }) |key| {
            try environ.put(key, path);
        }
        if (builtin.os.tag == .windows) for (windows_inherited) |key| {
            try environ.put(key, try t.environ.getAlloc(arena, key));
        };

        return .{ .arena = arena, .tmp = tmp, .path = path, .fb_path = fb_path, .environ = environ };
    }

    fn deinit(sandbox: *Sandbox) void {
        sandbox.tmp.cleanup();
    }

    /// Runs fb from the sandbox directory with the sandbox environment.
    fn fb(sandbox: *Sandbox, args: []const []const u8) !Result {
        const argv = try std.mem.concat(sandbox.arena, []const u8, &.{ &.{sandbox.fb_path}, args });
        const stdin = try sandbox.tmp.dir.openFile(io, "stdin", .{});
        defer stdin.close(io);

        var child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .dir = sandbox.tmp.dir },
            .environ_map = &sandbox.environ,
            .stdin = .{ .file = stdin },
            .stdout = .pipe,
            .stderr = .pipe,
        });
        defer child.kill(io);

        var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var reader: std.Io.File.MultiReader = undefined;
        reader.init(sandbox.arena, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer reader.deinit();
        while (reader.fill(64, .none)) |_| {} else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
        try reader.checkAnyError();

        const code = switch (try child.wait(io)) {
            .exited => |code| code,
            else => return error.FbDidNotExit,
        };

        return .{
            .code = code,
            .stdout = try reader.toOwnedSlice(0),
            .stderr = try reader.toOwnedSlice(1),
        };
    }

    /// Runs fb with `--json` reporting and parses the report.
    fn json(sandbox: *Sandbox, args: []const []const u8) !struct { Result, Report } {
        const result = try sandbox.fb(args);
        const report = try std.json.parseFromSliceLeaky(Report, sandbox.arena, result.stdout, .{});
        return .{ result, report };
    }

    fn read(sandbox: *Sandbox, path: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(io, path, sandbox.arena, .unlimited);
    }

    /// Replaces the run directory with `<run>` and the duration with `<time>`.
    /// The run directory must lie under the sandbox's temporary directory.
    fn normalize(sandbox: *Sandbox, text: []const u8, run_directory: []const u8) ![]const u8 {
        try t.expect(std.mem.startsWith(u8, run_directory, sandbox.path));
        const prefix = try std.fmt.allocPrint(sandbox.arena, "{s}{c}", .{ run_directory, std.fs.path.sep });
        const paths = try std.mem.replaceOwned(u8, sandbox.arena, text, prefix, "<run>/");
        return sandbox.hide(paths, "time=", "]", "<time>");
    }

    /// Replaces the text between the first `start` and the next `end` with `placeholder`.
    fn hide(sandbox: *Sandbox, text: []const u8, start: []const u8, end: []const u8, placeholder: []const u8) ![]const u8 {
        const from = (std.mem.indexOf(u8, text, start) orelse return text) + start.len;
        const to = std.mem.indexOfPos(u8, text, from, end) orelse return text;
        return std.mem.concat(sandbox.arena, u8, &.{ text[0..from], placeholder, text[to..] });
    }
};

test "fb returns the command's exit code and saves its output" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var sandbox = try Sandbox.init(arena_state.allocator());
    defer sandbox.deinit();

    const result, const report = try sandbox.json(&.{ "run", "--json", fixture ++ " --out hello --err oops --exit 7" });
    try t.expectEqual(7, result.code);
    try t.expectEqualStrings("", result.stderr);
    try t.expectEqual(7, report.exit_code);
    try t.expectEqualStrings("hello\n", try sandbox.read(report.stdout.path));
    try t.expectEqualStrings("oops\n", try sandbox.read(report.stderr.path));
}

test "JSON reports the command, sizes, and completion" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var sandbox = try Sandbox.init(arena_state.allocator());
    defer sandbox.deinit();

    const command = fixture ++ " --out-bytes 2048 --err warning";
    _, const report = try sandbox.json(&.{ "--json", command });
    try t.expectEqualStrings(command, report.command.?);
    try t.expectEqual(2048, report.stdout.size);
    try t.expectEqual(8, report.stderr.size);
    try t.expectEqual(0, report.exit_code);
    try t.expect(!report.timed_out);
    try t.expectEqual(null, report.oversized);
    try t.expect(report.duration_ns > 0);
    try t.expectEqual(null, report.stdout.head);
    try t.expectEqual(null, report.stderr.tail);
    try t.expectEqualStrings(report.directory(), std.fs.path.dirname(report.stderr.path).?);
}

test "text excerpts show the first and last lines of each stream" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var sandbox = try Sandbox.init(arena_state.allocator());
    defer sandbox.deinit();

    const command = fixture ++ " --out one --out two --out three --no-newline --err partial";
    const result = try sandbox.fb(&.{ "run", "-n", "excerpts", "-d", "1", "-l", "2", command });
    _, const report = try sandbox.json(&.{ "print", "--json", "excerpts" });
    try t.expectEqual(0, result.code);
    try t.expectEqualStrings("", result.stderr);
    try t.expectEqualStrings(
        "[fb exit=0 time=<time>]\n" ++
            "command: " ++ command ++ "\n" ++
            \\stdout (14 B): <run>/stdout
            \\stderr (7 B): <run>/stderr
            \\
            \\>>> stdout head 1
            \\one
            \\<<<
            \\
            \\>>> stdout tail 2
            \\two
            \\three
            \\<<<
            \\
            \\>>> stderr head 1
            \\partial
            \\<<<
            \\
            \\>>> stderr tail 2
            \\partial
            \\<<<
            \\
        ,
        try sandbox.normalize(result.stdout, report.directory()),
    );
}

test "text excerpts of an empty stream are empty" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var sandbox = try Sandbox.init(arena_state.allocator());
    defer sandbox.deinit();

    const command = fixture ++ " --out done";
    const result = try sandbox.fb(&.{ "-n", "quiet", "--tail", "3", command });
    _, const report = try sandbox.json(&.{ "print", "--json", "quiet" });
    try t.expectEqualStrings(
        "[fb exit=0 time=<time>]\n" ++
            "command: " ++ command ++ "\n" ++
            \\stdout (5 B): <run>/stdout
            \\stderr (0 B): <run>/stderr
            \\
            \\>>> stdout tail 3
            \\done
            \\<<<
            \\
            \\>>> stderr tail 3
            \\<<<
            \\
        ,
        try sandbox.normalize(result.stdout, report.directory()),
    );
}

test "JSON excerpts follow the per-stream options" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var sandbox = try Sandbox.init(arena_state.allocator());
    defer sandbox.deinit();

    _, const report = try sandbox.json(&.{
        "--json",
        "--out:head",
        "2",
        "-e:l",
        "1",
        fixture ++ " --out one --out two --out three --err first --no-newline --err last",
    });
    try t.expectEqualStrings("one\ntwo\n", report.stdout.head.?);
    try t.expectEqual(null, report.stdout.tail);
    try t.expectEqual(null, report.stderr.head);
    try t.expectEqualStrings("last\n", report.stderr.tail.?);
    try t.expectEqualStrings("first\nlast", try sandbox.read(report.stderr.path));
}

test "a timeout kills the command and exits with 124" {
    // Hangs on Windows until fb kills the whole command tree (#10).
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var sandbox = try Sandbox.init(arena_state.allocator());
    defer sandbox.deinit();

    const command = fixture ++ " --out started --hang";
    const result = try sandbox.fb(&.{ "-n", "slow", "-t", "200ms", command });
    _, const report = try sandbox.json(&.{ "print", "--json", "slow" });
    try t.expectEqual(124, result.code);
    try t.expectEqualStrings("command timed out after 200ms and was killed\n", result.stderr);
    try t.expectEqualStrings(
        "[fb exit=124 timed_out time=<time>]\n" ++
            "command: " ++ command ++ "\n" ++
            \\stdout (8 B): <run>/stdout
            \\stderr (0 B): <run>/stderr
            \\
        ,
        try sandbox.normalize(result.stdout, report.directory()),
    );
    try t.expect(report.timed_out);
    try t.expectEqualStrings("started\n", try sandbox.read(report.stdout.path));
}

test "oversized output kills the command unless the limit is disabled" {
    // Hangs on Windows until fb kills the whole command tree (#10).
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var sandbox = try Sandbox.init(arena_state.allocator());
    defer sandbox.deinit();
    try sandbox.environ.put("FILE_BASH_MAX_SIZE", "1K");

    // The timeout only stops the test from hanging if the limit fails.
    const killed, const killed_report = try sandbox.json(&.{ "--json", "-t", "30s", fixture ++ " --out-bytes 4096 --hang" });
    try t.expectEqual(153, killed.code);
    try t.expectEqualStrings(
        "stdout exceeded the 1.0 KB size limit and the command was killed; raise FILE_BASH_MAX_SIZE or pass --unlimited\n",
        killed.stderr,
    );
    try t.expectEqualStrings("stdout", killed_report.oversized.?);
    try t.expect(!killed_report.timed_out);

    const unlimited, const unlimited_report = try sandbox.json(&.{ "--json", "-u", fixture ++ " --out-bytes 4096" });
    try t.expectEqual(0, unlimited.code);
    try t.expectEqual(null, unlimited_report.oversized);
    try t.expectEqual(4096, unlimited_report.stdout.size);
}

test "named runs overwrite their output unless a lock remains" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var sandbox = try Sandbox.init(arena_state.allocator());
    defer sandbox.deinit();

    _, const first = try sandbox.json(&.{ "--json", "-n", "build", fixture ++ " --out first" });
    _, const second = try sandbox.json(&.{ "--json", "-n", "build", fixture ++ " --out second" });
    try t.expectEqualStrings(first.stdout.path, second.stdout.path);
    try t.expectEqualStrings("second\n", try sandbox.read(second.stdout.path));

    // A lock left by an fb that was killed in 1970.
    const lock_path = try std.fs.path.join(sandbox.arena, &.{ second.directory(), "lock" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lock_path, .data = "0\n" });

    const refused = try sandbox.fb(&.{ "-n", "build", fixture ++ " --out third" });
    try t.expectEqual(1, refused.code);
    try t.expectEqualStrings("", refused.stdout);
    try t.expectEqualStrings(
        \\run 'build' may still be running; its lock file was written <elapsed> ago (1970-01-01 00:00:00 UTC)
        \\wait for it to finish, or pass --overwrite only once you are sure the lock is stale (fb was killed or the process is gone)
        \\
    ,
        try sandbox.hide(refused.stderr, "written ", " ago", "<elapsed>"),
    );
    try t.expectEqualStrings("second\n", try sandbox.read(second.stdout.path));

    const forced, _ = try sandbox.json(&.{ "--json", "--overwrite", "-n", "build", fixture ++ " --out third" });
    try t.expectEqual(0, forced.code);
    try t.expectEqualStrings("third\n", try sandbox.read(second.stdout.path));
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, lock_path, .{}));
}

test "last and print report saved runs until clean removes them" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var sandbox = try Sandbox.init(arena_state.allocator());
    defer sandbox.deinit();

    const named_command = fixture ++ " --out a --exit 3";
    _, const named = try sandbox.json(&.{ "--json", "-n", "first", named_command });
    _, const unnamed = try sandbox.json(&.{ "--json", fixture ++ " --out b" });

    const last, const last_report = try sandbox.json(&.{ "last", "--json" });
    try t.expectEqual(0, last.code);
    try t.expectEqualStrings(unnamed.stdout.path, last_report.stdout.path);

    const printed = try sandbox.fb(&.{ "print", "-l", "1", "first" });
    try t.expectEqual(3, printed.code);
    try t.expectEqualStrings(
        "[fb exit=3 time=<time>]\n" ++
            "command: " ++ named_command ++ "\n" ++
            \\stdout (2 B): <run>/stdout
            \\stderr (0 B): <run>/stderr
            \\
            \\>>> stdout tail 1
            \\a
            \\<<<
            \\
            \\>>> stderr tail 1
            \\<<<
            \\
        ,
        try sandbox.normalize(printed.stdout, named.directory()),
    );

    // print does not change which run last selects.
    _, const still_last = try sandbox.json(&.{ "last", "--json" });
    try t.expectEqualStrings(unnamed.stdout.path, still_last.stdout.path);

    const cleaned = try sandbox.fb(&.{"clean"});
    try t.expectEqual(0, cleaned.code);
    for ([_][]const u8{ named.stdout.path, named.stderr.path, unnamed.stdout.path, unnamed.stderr.path }) |path| {
        try t.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
    }

    const missing_last = try sandbox.fb(&.{"last"});
    try t.expectEqual(1, missing_last.code);
    try t.expectEqualStrings("no saved last run\n", missing_last.stderr);

    const missing_named = try sandbox.fb(&.{ "print", "first" });
    try t.expectEqual(1, missing_named.code);
    try t.expectEqualStrings("no run named 'first'\n", missing_named.stderr);

    const already = try sandbox.fb(&.{"clean"});
    try t.expectEqual(0, already.code);
    try t.expectEqualStrings("fb outputs already cleaned up\n", already.stdout);
}

test "the command reads end-of-file from standard input" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var sandbox = try Sandbox.init(arena_state.allocator());
    defer sandbox.deinit();

    _, const report = try sandbox.json(&.{ "--json", fixture ++ " --stdin" });
    try t.expectEqualStrings("stdin: 0 bytes\n", try sandbox.read(report.stdout.path));
}

test "-C and FILE_BASH_CWD set the working directory" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var sandbox = try Sandbox.init(arena_state.allocator());
    defer sandbox.deinit();
    const arena = sandbox.arena;

    try sandbox.tmp.dir.createDir(io, "work", .default_dir);
    try sandbox.tmp.dir.createDir(io, "other", .default_dir);
    const work = try std.fs.path.join(arena, &.{ sandbox.path, "work" });
    const other = try std.fs.path.join(arena, &.{ sandbox.path, "other" });
    const command = fixture ++ " --cwd";

    // A relative -C resolves from where fb was invoked.
    _, const relative = try sandbox.json(&.{ "--json", "-C", "work", command });
    try t.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{work}), try sandbox.read(relative.stdout.path));

    try sandbox.environ.put("FILE_BASH_CWD", other);
    _, const environment = try sandbox.json(&.{ "--json", command });
    try t.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{other}), try sandbox.read(environment.stdout.path));

    _, const both = try sandbox.json(&.{ "--json", "-C", work, command });
    try t.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{work}), try sandbox.read(both.stdout.path));

    const missing_path = try std.fs.path.join(arena, &.{ sandbox.path, "missing" });
    const missing = try sandbox.fb(&.{ "-C", missing_path, command });
    try t.expectEqual(1, missing.code);
    try t.expectEqualStrings(
        try std.fmt.allocPrint(arena, "working directory '{s}' from '-C': does not exist\n", .{missing_path}),
        missing.stderr,
    );
}

test "invalid arguments report the problem and exit with 2" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var sandbox = try Sandbox.init(arena_state.allocator());
    defer sandbox.deinit();

    const help = try sandbox.fb(&.{ "run", "--help" });
    const unknown = try sandbox.fb(&.{ "run", "--bogus", fixture });
    try t.expectEqual(2, unknown.code);
    try t.expectEqualStrings("", unknown.stdout);
    try t.expectEqualStrings(
        try std.mem.concat(sandbox.arena, u8, &.{ "unknown run option '--bogus'\n", help.stdout }),
        unknown.stderr,
    );

    const unnamed = try sandbox.fb(&.{ "--overwrite", fixture });
    try t.expectEqual(2, unnamed.code);
    try t.expectEqualStrings("--overwrite requires --name; unnamed runs never reuse a directory\n", unnamed.stderr);

    const invalid_name = try sandbox.fb(&.{ "-n", "../escape", fixture });
    try t.expectEqual(2, invalid_name.code);
    try t.expectEqualStrings(
        "invalid run name '../escape'; use 1–64 ASCII letters, digits, hyphens, or underscores; last is reserved" ++
            (if (builtin.os.tag == .windows) "; Windows device names are also reserved" else "") ++ "\n",
        invalid_name.stderr,
    );
}
