//! Marks a run directory as in use while its command runs, so a named rerun
//! can warn before it overwrites output that may still be written to.
const std = @import("std");

pub const filename = "lock";

/// Wall-clock start time; the lock file stores it as decimal Unix seconds.
const clock: std.Io.Clock = .real;

/// Written when a run starts and removed when it finishes. A lock left behind
/// means the command is still running or `fb` was killed before it could finish.
pub const Lock = struct {
    /// Unix seconds when the run started.
    started: i64,

    /// Returns the lock in `directory`, or null when no run holds it.
    pub fn read(io: std.Io, directory: std.Io.Dir) !?Lock {
        const file = directory.openFile(io, filename, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);

        var bytes: [24]u8 = undefined;
        const length = try file.readPositionalAll(io, &bytes, 0);
        const text = std.mem.trimEnd(u8, bytes[0..length], "\r\n");

        return .{ .started = std.fmt.parseInt(i64, text, 10) catch return error.InvalidRunLock };
    }

    /// Records the current wall-clock time; replaces any stale lock.
    pub fn write(io: std.Io, directory: std.Io.Dir) !void {
        var file = try directory.createFileAtomic(io, filename, .{ .replace = true });
        defer file.deinit(io);

        var bytes: [24]u8 = undefined;
        const text = try std.fmt.bufPrint(&bytes, "{d}\n", .{clock.now(io).toSeconds()});
        try file.file.writeStreamingAll(io, text);
        try file.replace(io);
    }

    /// Removes the lock; a missing file is not an error.
    pub fn remove(io: std.Io, directory: std.Io.Dir) !void {
        directory.deleteFile(io, filename) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Explains why the named run was refused and how to force it.
    pub fn writeConflict(lock: Lock, io: std.Io, name: []const u8, out: *std.Io.Writer) !void {
        try lock.writeConflictAt(clock.now(io).toSeconds(), name, out);
    }

    fn writeConflictAt(lock: Lock, now: i64, name: []const u8, out: *std.Io.Writer) !void {
        try out.print("run '{s}' may still be running; its lock file was written ", .{name});
        if (now == lock.started) {
            try out.writeAll("less than a second ago");
        } else if (now > lock.started) {
            try out.print("{f} ago", .{std.Io.Duration.fromSeconds(now - lock.started)});
        } else {
            try out.print("{f} in the future", .{std.Io.Duration.fromSeconds(lock.started - now)});
        }
        try out.writeAll(" (");
        try writeUtc(lock.started, out);
        try out.writeAll(")\n");
        try out.writeAll("wait for it to finish, or pass --overwrite only once you are sure the lock is stale (fb was killed or the process is gone)\n");
    }
};

/// Writes `YYYY-MM-DD HH:MM:SS UTC`; times before 1970 print the raw Unix seconds.
fn writeUtc(seconds: i64, out: *std.Io.Writer) !void {
    if (seconds < 0) return out.print("Unix {d}", .{seconds});

    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();

    try out.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

test "lock round trip, removal, and invalid content" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    try t.expectEqual(null, try Lock.read(io, tmp.dir));
    try Lock.remove(io, tmp.dir);

    try Lock.write(io, tmp.dir);
    const lock = (try Lock.read(io, tmp.dir)).?;
    const now = clock.now(io).toSeconds();
    try t.expect(lock.started <= now and lock.started + 60 > now);

    try Lock.remove(io, tmp.dir);
    try t.expectEqual(null, try Lock.read(io, tmp.dir));

    try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = "soon\n" });
    try t.expectError(error.InvalidRunLock, Lock.read(io, tmp.dir));

    try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = "1700000000\r\n" });
    try t.expectEqual(1700000000, (try Lock.read(io, tmp.dir)).?.started);
}

test "conflict message reports elapsed time, UTC date, and the overwrite flag" {
    const t = std.testing;
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();

    const lock: Lock = .{ .started = 1757584800 };
    try lock.writeConflictAt(1757584800 + 133, "build", &out.writer);
    try t.expectEqualStrings(
        "run 'build' may still be running; its lock file was written 2m13s ago (2025-09-11 10:00:00 UTC)\n" ++
            "wait for it to finish, or pass --overwrite only once you are sure the lock is stale (fb was killed or the process is gone)\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try lock.writeConflictAt(1757584800, "build", &out.writer);
    try t.expect(std.mem.startsWith(u8, out.written(), "run 'build' may still be running; its lock file was written less than a second ago ("));

    out.clearRetainingCapacity();
    try lock.writeConflictAt(1757584800 - 5, "build", &out.writer);
    try t.expect(std.mem.indexOf(u8, out.written(), "5s in the future") != null);
}
