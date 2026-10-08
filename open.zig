//! open - open a file, directory or URI with the Windows shell.
//!
//! Zig rewrite of open.c3. Uses ShellExecuteW (the same API as the C3
//! `win::shell_exec`), so it behaves like a double click or the `start`
//! command. Windows only.
//!
//! Build with Zig 0.17.0 (no build.zig):
//!   zig build-exe -OReleaseFast -femit-bin=dist/open.exe open.zig -lshell32 -lshlwapi

const std = @import("std");
const win = @import("win.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) u8 {
    return run(init) catch 1;
}

/// Dispatch on the first argument (defaulting to the current directory):
/// http/https/mailto targets go straight to the shell, anything else is
/// treated as a file path.
///
/// Argument parsing mirrors open.c3: `argv[0]` is the executable name and
/// extra arguments after the target are forwarded to the launched program.
fn run(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);

    const cwd = try std.process.currentPathAlloc(io, allocator);

    // The target defaults to the current directory.
    var target: []const u8 = ".";
    if (args.len > 1) target = args[1];

    // Open URLs / mail addresses directly.
    if (std.mem.startsWith(u8, target, "http:") or
        std.mem.startsWith(u8, target, "https:") or
        std.mem.startsWith(u8, target, "mailto:"))
    {
        return if (win.shellExec(io, allocator, cwd, target, "")) 0 else 1;
    }

    return openFile(io, allocator, cwd, target, args);
}

/// Check that the target exists, then hand it (plus any extra arguments) to the
/// shell. On failure it prints the same message and returns exit code 1 as the
/// C3 original.
fn openFile(
    io: Io,
    allocator: Allocator,
    cwd: []const u8,
    file_path: []const u8,
    args: []const [:0]const u8,
) !u8 {
    // `path::new` returns INVALID_PATH for reserved characters; the original
    // reports that instead of a "file not found" for such input.
    const normalized = (try win.normalizePath(allocator, file_path)) orelse {
        win.stderrPrint(io, "Error, {s}. Input = {s}\r\n", .{ win.invalid_path_message, file_path });
        return 1;
    };

    if (!win.pathExists(allocator, normalized)) {
        win.stderrPrint(io, "Error, file not found. File path = {s}\r\n", .{normalized});
        return 1;
    }

    // Extra arguments (after the file path) are passed through to the target.
    var parameters: std.ArrayList(u8) = .empty;
    if (args.len > 2) {
        for (args[2..]) |arg| {
            try parameters.appendSlice(allocator, arg);
            try parameters.append(allocator, ' ');
        }
    }

    return if (win.shellExec(io, allocator, cwd, normalized, parameters.items)) 0 else 1;
}
