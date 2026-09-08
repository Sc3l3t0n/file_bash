const std = @import("std");
const builtin = @import("builtin");

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
