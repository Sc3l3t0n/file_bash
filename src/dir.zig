const std = @import("std");
const builtin = @import("builtin");

pub const last_filename = "last";

pub const output_dirname = "file_bash";

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

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    try environ.put("TMPDIR", "");
    try std.testing.expectEqualStrings("/tmp", try tempPath(&environ));

    try environ.put("TMPDIR", "/custom temp/");
    try std.testing.expectEqualStrings("/custom temp/", try tempPath(&environ));

    try environ.put("TMPDIR", "relative");
    try std.testing.expectError(error.TemporaryDirectoryMustBeAbsolute, tempPath(&environ));
}

test "Windows temporary directory precedence and missing environment" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    try std.testing.expectError(error.TemporaryDirectoryNotFound, tempPath(&environ));

    try environ.put("USERPROFILE", "C:\\Users\\user");
    try environ.put("SystemRoot", "C:\\Windows");
    try std.testing.expectError(error.TemporaryDirectoryNotFound, tempPath(&environ));

    const keys = [_][]const u8{ "TEMP", "TMP" };
    const paths = [_][]const u8{ "C:\\temp", "D:\\tmp" };
    for (keys, paths) |key, path| {
        try environ.put(key, path);
        try std.testing.expectEqualStrings(path, try tempPath(&environ));
    }

    try environ.put("TMP", "");
    try std.testing.expectEqualStrings("C:\\temp", try tempPath(&environ));

    try environ.put("TMP", "relative");
    try std.testing.expectError(error.TemporaryDirectoryMustBeAbsolute, tempPath(&environ));
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
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    const key = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    try std.testing.expectError(error.HomeDirectoryNotFound, homePath(&environ));

    try environ.put(key, "");
    try std.testing.expectError(error.HomeDirectoryNotFound, homePath(&environ));

    try environ.put(key, "relative");
    try std.testing.expectError(error.HomeDirectoryMustBeAbsolute, homePath(&environ));

    const path = if (builtin.os.tag == .windows) "C:\\Users\\test" else "/home/test";
    try environ.put(key, path);
    try std.testing.expectEqualStrings(path, try homePath(&environ));
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
        if (name.len == 4 and (std.ascii.eqlIgnoreCase(name[0..3], "COM") or std.ascii.eqlIgnoreCase(name[0..3], "LPT")) and name[3] >= '1' and name[3] <= '9') return false;
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
