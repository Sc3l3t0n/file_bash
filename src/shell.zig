const std = @import("std");
const builtin = @import("builtin");

pub const Shell = enum {
    sh,
    bash,
    zsh,
    fish,
    nu,
    cmd,
    powershell,
    pwsh,

    const names = std.StaticStringMap(Shell).initComptime(.{
        .{ "sh", .sh },
        .{ "bash", .bash },
        .{ "zsh", .zsh },
        .{ "fish", .fish },
        .{ "nu", .nu },
        .{ "cmd", .cmd },
        .{ "powershell", .powershell },
        .{ "pwsh", .pwsh },
    });
};

const environment_name = "FILE_BASH_SHELL";
const default_shell: Shell = if (builtin.os.tag == .windows) .cmd else .sh;

const Argv = union(enum) {
    three: [3][]const u8,
    four: [4][]const u8,
    five: [5][]const u8,

    pub fn slice(self: *const Argv) []const []const u8 {
        return switch (self.*) {
            inline else => |*argv| argv,
        };
    }
};

pub fn command(environ: *const std.process.Environ.Map, source: []const u8) !Argv {
    const configured = environ.get(environment_name);
    const selected = if (configured == null or configured.?.len == 0)
        default_shell
    else
        Shell.names.get(configured.?) orelse return error.UnknownShell;

    return switch (selected) {
        inline .sh, .bash, .zsh, .fish, .nu => |shell| .{ .three = .{ @tagName(shell), "-c", source } },
        .cmd => if (builtin.os.tag == .windows)
            .{ .five = .{ "cmd.exe", "/d", "/s", "/c", source } }
        else
            error.UnsupportedShell,
        .powershell => if (builtin.os.tag == .windows)
            .{ .four = .{ "powershell.exe", "-NoProfile", "-Command", source } }
        else
            error.UnsupportedShell,
        .pwsh => .{ .four = .{ "pwsh", "-NoProfile", "-Command", source } },
    };
}

test "configured shell command lines" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    const cases = .{
        .{ "pwsh", &.{ "pwsh", "-NoProfile", "-Command", "echo hello" } },
        .{ "sh", &.{ "sh", "-c", "echo hello" } },
        .{ "bash", &.{ "bash", "-c", "echo hello" } },
        .{ "zsh", &.{ "zsh", "-c", "echo hello" } },
        .{ "fish", &.{ "fish", "-c", "echo hello" } },
        .{ "nu", &.{ "nu", "-c", "echo hello" } },
    };
    inline for (cases) |case| {
        try environ.put(environment_name, case[0]);
        const shell_command = try command(&environ, "echo hello");
        const expected: []const []const u8 = case[1];
        try std.testing.expectEqualDeep(expected, shell_command.slice());
    }

    const windows_cases = .{
        .{ "cmd", &.{ "cmd.exe", "/d", "/s", "/c", "echo hello" } },
        .{ "powershell", &.{ "powershell.exe", "-NoProfile", "-Command", "echo hello" } },
    };
    inline for (windows_cases) |case| {
        try environ.put(environment_name, case[0]);
        if (builtin.os.tag == .windows) {
            const shell_command = try command(&environ, "echo hello");
            const expected: []const []const u8 = case[1];
            try std.testing.expectEqualDeep(expected, shell_command.slice());
        } else {
            try std.testing.expectError(error.UnsupportedShell, command(&environ, "echo hello"));
        }
    }

    try environ.put(environment_name, "unknown");
    try std.testing.expectError(error.UnknownShell, command(&environ, "echo hello"));
}
