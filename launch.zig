//! launch - read a config file and run the command it describes.
//!
//! Zig rewrite of launch.c3. Given an executable named `<name>.exe`, it loads
//! `<name>.json` from the executable's directory, substitutes `$CWD` in the
//! arguments with the current directory, then hands the command to
//! ShellExecuteW (via win.zig). Windows only.
//!
//! Config format:
//!   {
//!     "command": "python",
//!     "changeDir": true,
//!     "args": ["script.py", "$CWD"]
//!   }
//!
//! Build with Zig 0.17.0 (no build.zig):
//!   zig build-exe -OReleaseFast -femit-bin=dist/launch.exe launch.zig -lshell32 -lshlwapi

const std = @import("std");
const win = @import("win.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Upper bound for the config file; large enough for any practical launcher.
const config_max_bytes = 1 << 20;

pub fn main(init: std.process.Init) u8 {
    return run(init) catch 1;
}

/// Resolve the install directory and its `<exe_name>.json`, then launch the
/// configured command. Mirrors launch.c3's `real_main`.
fn run(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.arena.allocator();

    // `<exe>.json` lives next to the executable, named after it.
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    const install_path = std.fs.path.dirname(exe_path) orelse ".";
    const exe_name = std.fs.path.basename(exe_path);
    const config_name = try allocator.print("{s}.json", .{exe_name});
    const config_path = try std.fs.path.join(allocator, &.{ install_path, config_name });

    const cwd = try std.process.currentPathAlloc(io, allocator);

    const context = std.Io.Dir.cwd().readFileAlloc(
        io,
        config_path,
        allocator,
        .limited(config_max_bytes),
    ) catch |err| {
        win.stderrPrint(io, "Error, cannot read config {s}: {s}\r\n", .{ config_path, @errorName(err) });
        return 1;
    };

    const config = std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        context,
        .{},
    ) catch |err| {
        win.stderrPrint(io, "Error, invalid config {s}: {s}\r\n", .{ config_path, @errorName(err) });
        return 1;
    };
    const root = switch (config) {
        .object => |obj| obj,
        else => {
            win.stderrPrint(io, "Error, config {s} is not a JSON object\r\n", .{config_path});
            return 1;
        },
    };

    // `command` is normalized the same way open.c3 handles a target path
    // (canonical separators, folded "." / "..").
    const command_raw = jsonString(root, "command") orelse {
        win.stderrPrint(io, "Error, config {s} has no \"command\"\r\n", .{config_path});
        return 1;
    };
    const command = (try win.normalizePath(allocator, command_raw)) orelse {
        win.stderrPrint(io, "Error, {s}. Input = {s}\r\n", .{ win.invalid_path_message, command_raw });
        return 1;
    };

    const change_dir = jsonBool(root, "changeDir") orelse false;

    // Build the argument string, replacing `$CWD` when changeDir is set.
    var flags: std.ArrayList(u8) = .empty;
    if (jsonArray(root, "args")) |args| {
        for (args.items) |arg_value| {
            var flag: []const u8 = switch (arg_value) {
                .string => |s| s,
                else => continue,
            };
            if (change_dir and std.mem.eql(u8, flag, "$CWD")) flag = cwd;

            try flags.appendSlice(allocator, flag);
            try flags.append(allocator, ' ');
        }
    }

    const work_dir = if (change_dir) install_path else cwd;
    return if (win.shellExec(io, allocator, work_dir, command, flags.items)) 0 else 1;
}

/// The `.string` payload of `obj[key]`, or null when absent or not a string.
fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// The `.bool` payload of `obj[key]`, or null when absent or not a bool.
fn jsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

/// The `.array` payload of `obj[key]`, or null when absent or not an array.
fn jsonArray(obj: std.json.ObjectMap, key: []const u8) ?std.json.Array {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .array => |a| a,
        else => null,
    };
}
