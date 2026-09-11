//! Output size limit read from the environment. A run whose stdout or stderr
//! file outgrows the limit is killed so a looping command cannot fill the disk.
const std = @import("std");

pub const key = "FILE_BASH_MAX_SIZE";

/// Applies when the variable is unset or empty.
pub const default_max_size: u64 = 256 * 1024 * 1024;

const Unit = enum(u6) {
    bytes = 0,
    kibibytes = 10,
    mebibytes = 20,
    gibibytes = 30,

    /// Every letter a suffix is spelled with; anything else is invalid.
    const suffix_letters = "KMGkmg";

    const suffixes = std.StaticStringMap(Unit).initComptime(.{
        .{ "K", .kibibytes },
        .{ "k", .kibibytes },
        .{ "M", .mebibytes },
        .{ "m", .mebibytes },
        .{ "G", .gibibytes },
        .{ "g", .gibibytes },
    });
};

pub const Error = error{InvalidMaxSize};

/// Returns the per-file size limit in bytes; the caller disables it separately.
pub fn maxSize(environ: *const std.process.Environ.Map) Error!u64 {
    const text = environ.get(key) orelse return default_max_size;
    if (text.len == 0) return default_max_size;

    return parse(text);
}

/// Accepts a positive count with an optional `K`, `M`, or `G` suffix; a bare count is bytes.
fn parse(text: []const u8) Error!u64 {
    const digits = std.mem.trimEnd(u8, text, Unit.suffix_letters);
    const suffix = text[digits.len..];
    const unit: Unit = if (suffix.len == 0)
        .bytes
    else
        Unit.suffixes.get(suffix) orelse return error.InvalidMaxSize;
    const count = std.fmt.parseUnsigned(u64, digits, 10) catch return error.InvalidMaxSize;
    if (count == 0) return error.InvalidMaxSize;

    return std.math.shlExact(u64, count, @intFromEnum(unit)) catch error.InvalidMaxSize;
}

test "size limit environment parsing" {
    const t = std.testing;
    var environ: std.process.Environ.Map = .init(t.allocator);
    defer environ.deinit();

    try t.expectEqual(default_max_size, try maxSize(&environ));
    try environ.put(key, "");
    try t.expectEqual(default_max_size, try maxSize(&environ));

    const cases = .{
        .{ "4096", 4096 },
        .{ "16K", 16 * 1024 },
        .{ "16k", 16 * 1024 },
        .{ "100M", 100 * 1024 * 1024 },
        .{ "2G", 2 * 1024 * 1024 * 1024 },
    };
    inline for (cases) |case| {
        try environ.put(key, case[0]);
        try t.expectEqual(@as(u64, case[1]), try maxSize(&environ));
    }

    inline for (.{ "0", "0M", "-1", "x", "5MB", "5 M", "5KM", "99999999999999999999G" }) |invalid| {
        try environ.put(key, invalid);
        try t.expectError(error.InvalidMaxSize, maxSize(&environ));
    }
}
