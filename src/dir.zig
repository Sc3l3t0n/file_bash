const std = @import("std");
const builtin = @import("builtin");

pub const last_filename = "last";

const output_dirname = "file_bash";

/// Returns a borrowed absolute path; does not allocate or create the directory.
/// The environment map must remain alive while the returned path is in use.
pub fn tempPath(environ: *const std.process.Environ.Map) ![]const u8 {
    const keys: []const []const u8 = switch (builtin.os.tag) {
        .linux, .macos => &.{"TMPDIR"},
        .windows => &.{ "TMP", "TEMP" },
        else => return error.UnsupportedOperatingSystem,
    };

    for (keys) |key| {
        const path = environ.get(key) orelse continue;
        if (path.len == 0) continue;
        if (!std.fs.path.isAbsolute(path)) return error.TemporaryDirectoryMustBeAbsolute;

        return path;
    }

    return if (builtin.os.tag == .windows) error.TemporaryDirectoryNotFound else "/tmp";
}

test "Unix temporary directory override, empty value, fallback, and relative path" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const t = std.testing;
    var environ: std.process.Environ.Map = .init(t.allocator);
    defer environ.deinit();

    try environ.put("TMPDIR", "");
    try t.expectEqualStrings("/tmp", try tempPath(&environ));

    try environ.put("TMPDIR", "/custom temp/");
    try t.expectEqualStrings("/custom temp/", try tempPath(&environ));

    try environ.put("TMPDIR", "relative");
    try t.expectError(error.TemporaryDirectoryMustBeAbsolute, tempPath(&environ));
}

test "Windows temporary directory precedence and missing environment" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const t = std.testing;
    var environ: std.process.Environ.Map = .init(t.allocator);
    defer environ.deinit();

    try t.expectError(error.TemporaryDirectoryNotFound, tempPath(&environ));

    try environ.put("USERPROFILE", "C:\\Users\\user");
    try environ.put("SystemRoot", "C:\\Windows");
    try t.expectError(error.TemporaryDirectoryNotFound, tempPath(&environ));

    const keys = [_][]const u8{ "TEMP", "TMP" };
    const paths = [_][]const u8{ "C:\\temp", "D:\\tmp" };
    for (keys, paths) |key, path| {
        try environ.put(key, path);
        try t.expectEqualStrings(path, try tempPath(&environ));
    }

    try environ.put("TMP", "");
    try t.expectEqualStrings("C:\\temp", try tempPath(&environ));

    try environ.put("TMP", "relative");
    try t.expectError(error.TemporaryDirectoryMustBeAbsolute, tempPath(&environ));
}

/// Run directories are private to the user who started fb.
pub const private_permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);

/// The shared parent of every run directory.
pub const Outputs = struct {
    /// Absolute path of `parent`.
    path: []const u8,
    parent: std.Io.Dir,
};

pub const Access = enum { open, create };

/// Opens this user's output directory under the temporary directory, creating it
/// for `.create`. Returns null for `.open` when no run has created it yet.
/// Unix names include the effective user ID because temporary directories such as
/// /tmp are shared; Windows %TMP% is already per user.
pub fn openOutputs(
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    access: Access,
) !?Outputs {
    const temp_path = try tempPath(environ);
    var temp = try std.Io.Dir.openDirAbsolute(io, temp_path, .{});
    defer temp.close(io);

    const name = switch (builtin.os.tag) {
        .windows => output_dirname,
        else => try std.fmt.allocPrint(arena, output_dirname ++ "-{d}", .{std.posix.system.geteuid()}),
    };
    if (access == .create) temp.createDir(io, name, private_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // A symlink or file in place of the directory was not created by fb.
    var parent = temp.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.SymLinkLoop, error.NotDir => return error.OutputDirectoryNotPrivate,
        else => return err,
    };
    errdefer parent.close(io);
    try checkPrivate(parent);

    return .{ .path = try std.fs.path.join(arena, &.{ temp_path, name }), .parent = parent };
}

/// Rejects a directory that another user owns or can access, such as one created
/// in advance under a shared /tmp. Windows relies on the per-user %TMP% ACL.
fn checkPrivate(directory: std.Io.Dir) !void {
    const uid, const mode = switch (builtin.os.tag) {
        .linux => stat: {
            const linux = std.os.linux;
            var stat: linux.Statx = undefined;
            const rc = linux.statx(directory.handle, "", linux.AT.EMPTY_PATH, .{ .UID = true, .MODE = true }, &stat);
            switch (linux.errno(rc)) {
                .SUCCESS => break :stat .{ stat.uid, stat.mode },
                else => |err| return std.posix.unexpectedErrno(err),
            }
        },
        .macos => stat: {
            var stat: std.c.Stat = undefined;
            switch (std.c.errno(std.c.fstat(directory.handle, &stat))) {
                .SUCCESS => break :stat .{ stat.uid, stat.mode },
                else => |err| return std.posix.unexpectedErrno(err),
            }
        },
        .windows => return,
        else => return error.UnsupportedOperatingSystem,
    };

    if (uid != std.posix.system.geteuid() or mode & 0o077 != 0) return error.OutputDirectoryNotPrivate;
}

test "output directory is per user and must stay private" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("TMPDIR", path);

    const name = try std.fmt.allocPrint(arena, output_dirname ++ "-{d}", .{std.posix.system.geteuid()});
    try t.expectEqual(null, try openOutputs(io, arena, &environ, .open));

    const created = (try openOutputs(io, arena, &environ, .create)).?;
    created.parent.close(io);
    try t.expectEqualStrings(try std.fs.path.join(arena, &.{ path, name }), created.path);
    const reopened = (try openOutputs(io, arena, &environ, .open)).?;
    reopened.parent.close(io);

    try tmp.dir.setFilePermissions(io, name, .fromMode(0o755), .{});
    try t.expectError(error.OutputDirectoryNotPrivate, openOutputs(io, arena, &environ, .create));

    try tmp.dir.deleteDir(io, name);
    try tmp.dir.symLink(io, ".", name, .{ .is_directory = true });
    try t.expectError(error.OutputDirectoryNotPrivate, openOutputs(io, arena, &environ, .open));

    try tmp.dir.deleteFile(io, name);
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    try t.expectError(error.OutputDirectoryNotPrivate, openOutputs(io, arena, &environ, .create));
}

/// Returns a borrowed absolute home path without allocating.
pub fn homePath(environ: *const std.process.Environ.Map) ![]const u8 {
    const key = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const path = environ.get(key) orelse return error.HomeDirectoryNotFound;

    if (path.len == 0) return error.HomeDirectoryNotFound;
    if (!std.fs.path.isAbsolute(path)) return error.HomeDirectoryMustBeAbsolute;

    return path;
}

test "home directory must be present and absolute" {
    const t = std.testing;
    var environ: std.process.Environ.Map = .init(t.allocator);
    defer environ.deinit();

    const key = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    try t.expectError(error.HomeDirectoryNotFound, homePath(&environ));

    try environ.put(key, "");
    try t.expectError(error.HomeDirectoryNotFound, homePath(&environ));

    try environ.put(key, "relative");
    try t.expectError(error.HomeDirectoryMustBeAbsolute, homePath(&environ));

    const path = if (builtin.os.tag == .windows) "C:\\Users\\test" else "/home/test";
    try environ.put(key, path);
    try t.expectEqualStrings(path, try homePath(&environ));
}

/// Portable single-component run names, excluding internal and Windows device names.
pub fn validRunName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    }
    if (std.ascii.eqlIgnoreCase(name, last_filename)) return false;

    if (builtin.os.tag == .windows) {
        inline for (.{ "CON", "PRN", "AUX", "NUL", "CONIN", "CONOUT" }) |reserved| {
            if (std.ascii.eqlIgnoreCase(name, reserved)) return false;
        }
        if (name.len == 4 and name[3] >= '1' and name[3] <= '9') {
            inline for (.{ "COM", "LPT" }) |device| {
                if (std.ascii.eqlIgnoreCase(name[0..3], device)) return false;
            }
        }
    }
    return true;
}

/// Borrows the CLI override or environment default; relative paths use fb's cwd.
pub fn workingPath(override: ?[]const u8, environ: *const std.process.Environ.Map) ?[]const u8 {
    if (override) |path| return path;
    const path = environ.get("FILE_BASH_CWD") orelse return null;
    return if (path.len == 0) null else path;
}

test "working directory environment and CLI precedence" {
    const t = std.testing;
    var environ: std.process.Environ.Map = .init(t.allocator);
    defer environ.deinit();

    try t.expectEqual(null, workingPath(null, &environ));
    try environ.put("FILE_BASH_CWD", "");
    try t.expectEqual(null, workingPath(null, &environ));
    try environ.put("FILE_BASH_CWD", "environment directory");
    try t.expectEqualStrings("environment directory", workingPath(null, &environ).?);
    try t.expectEqualStrings("cli directory", workingPath("cli directory", &environ).?);
}
