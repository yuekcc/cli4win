//! open - open a file, directory or URI with the Windows shell.
//!
//! Zig rewrite of open.c3. Uses ShellExecuteW (the same API as the C3
//! `win::shell_exec`), so it behaves like a double click or the `start`
//! command. Windows only.
//!
//! Build with Zig 0.17.0 (no build.zig):
//!   zig build-exe -OReleaseFast -femit-bin=dist/open.exe open.zig -lshell32

const std = @import("std");

const windows = std.os.windows;
const Io = std.Io;
const Allocator = std.mem.Allocator;

// ShellExecuteW returns an HINSTANCE whose value is really a status code.
// Values greater than 32 indicate success; anything else is an error code.
extern "shell32" fn ShellExecuteW(
    hwnd: ?windows.HWND,
    lpOperation: ?windows.LPCWSTR,
    lpFile: ?windows.LPCWSTR,
    lpParameters: ?windows.LPCWSTR,
    lpDirectory: ?windows.LPCWSTR,
    nShowCmd: windows.INT,
) callconv(.winapi) windows.HINSTANCE;

// The C3 original's `path::exists` uses PathFileExistsW on Windows. Using the
// same shlwapi call (rather than a file stat) keeps behavior identical for
// special names such as "nul" or "CON".
extern "shlwapi" fn PathFileExistsW(pszPath: windows.LPCWSTR) callconv(.winapi) windows.BOOL;

/// Show the window in its normal (restored) state.
const SW_NORMAL: windows.INT = 1;

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
        return if (shellExec(io, allocator, cwd, target, "")) 0 else 1;
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
    const normalized = (try normalizePath(allocator, file_path)) orelse {
        stderrPrint(io, "Error, {s}. Input = {s}\r\n", .{ invalid_path_message, file_path });
        return 1;
    };

    if (!pathExists(allocator, normalized)) {
        stderrPrint(io, "Error, file not found. File path = {s}\r\n", .{normalized});
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

    return if (shellExec(io, allocator, cwd, normalized, parameters.items)) 0 else 1;
}

/// Displayed when the path has reserved characters. Hardcoded to match the
/// C3 `%s` formatting of the `path::INVALID_PATH` fault.
const invalid_path_message = "path::INVALID_PATH";

fn isSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}

/// The C3 original rejects these characters in path components on Windows.
fn isReservedWin32PathChar(c: u8) bool {
    return switch (c) {
        0...31, '>', '<', ':', '"', '/', '\\', '|', '?', '*' => true,
        else => false,
    };
}

/// Port of C3 `volume_name_len_win`: length of a Windows volume prefix
/// ("C:", "\\\\?\\", ...). Returns `error.InvalidPath` for a malformed UNC
/// prefix, matching the original.
fn volumeNameLenWin(path: []const u8) error{InvalidPath}!usize {
    const len = path.len;
    if (len < 2) return 0;
    switch (path[0]) {
        '\\' => {
            if (len == 2) return 0;
            var count: usize = 1;
            while (count < len and path[count] == '\\') count += 1;
            if (count != 2) return 0;
            var base_found: usize = 0;
            var i: usize = 2;
            while (i < len) : (i += 1) {
                const c = path[i];
                if (isSeparator(c)) {
                    if (base_found != 0) return i;
                    base_found = i;
                    continue;
                }
                if (isReservedWin32PathChar(c)) return error.InvalidPath;
            }
            if (base_found > 0 and base_found + 1 < len) return len;
            return error.InvalidPath;
        },
        'A'...'Z', 'a'...'z' => return if (path[1] == ':') 2 else 0,
        else => return 0,
    }
}

/// Port of C3 `Path::new` for Windows: fold redundant separators and `.`/`..`
/// components, canonicalize separators to `\`, and validate characters.
///
/// Returns a normalized copy, or `null` when the path contains a reserved
/// character (the caller prints `invalid_path_message` then).
fn normalizePath(allocator: Allocator, input: []const u8) !?[]u8 {
    if (input.len == 0) return try allocator.dupe(u8, input);

    const buf = try allocator.dupe(u8, input);
    const path_len = buf.len;

    var path_start: usize = volumeNameLenWin(buf) catch {
        allocator.free(buf);
        return null;
    };
    if (path_start > 0) {
        for (0..path_start) |i| {
            if (buf[i] == '/') buf[i] = '\\';
        }
    }
    if (path_start == path_len) return buf;

    var len = path_start;
    const has_root = isSeparator(buf[path_start]);
    if (has_root) {
        buf[len] = '\\';
        len += 1;
        path_start += 1;
    }
    var previous_was_separator = true;

    var i = path_start;
    while (i < path_len) : (i += 1) {
        const c = buf[i];

        // Fold repeated separators.
        if (isSeparator(c)) {
            if (previous_was_separator) continue;
            buf[len] = '\\';
            len += 1;
            previous_was_separator = true;
            continue;
        }

        if (isReservedWin32PathChar(c)) {
            allocator.free(buf);
            return null;
        }

        // Handle "." and ".." components.
        if (c == '.' and previous_was_separator) {
            var is_last = i == path_len - 1;
            var dots: u8 = 1;
            if (!is_last) {
                const next = buf[i + 1];
                if (next == '.') {
                    dots = 2;
                    is_last = i == path_len - 2;
                    if (!is_last and !isSeparator(buf[i + 2])) dots = 0;
                } else if (!isSeparator(next)) {
                    dots = 0;
                }
            }
            switch (dots) {
                1 => { // "./" -> skip
                    i += 1;
                    continue;
                },
                2 => {
                    // "/.." above the root is invalid.
                    if (len == path_start and has_root) {
                        allocator.free(buf);
                        return null;
                    }

                    // Leading or repeated "..": keep it verbatim.
                    if (len == path_start or
                        (len - path_start >= 3 and buf[len - 1] == '\\' and
                            buf[len - 3] == '.' and buf[len - 2] == '.' and
                            (len - 3 == 0 or buf[len - 4] == '\\')))
                    {
                        if (i != len) {
                            buf[len] = '.';
                            buf[len + 1] = '.';
                        }
                        len += 2;
                        if (len < path_len) {
                            buf[len] = '\\';
                            len += 1;
                        }
                        i += 2;
                        continue;
                    }

                    // Otherwise step back over the previous component.
                    len -= 1;
                    while (len > path_start and !isSeparator(buf[len - 1])) len -= 1;
                    i += 2;
                    continue;
                },
                else => {},
            }
        }

        if (i != len) buf[len] = c;
        previous_was_separator = false;
        len += 1;
    }

    // Drop a trailing separator (except for a bare root like "\").
    if (len > path_start + 1 and isSeparator(buf[len - 1])) len -= 1;
    if (len == 0) {
        buf[0] = '.';
        return buf[0..1];
    }
    // The result is handed to ShellExecuteW, so keep the NUL terminator.
    if (buf.len > len) buf[len] = 0;
    return buf[0..len];
}

/// True when `path` exists (file or directory), matching the C3 original's
/// `path::exists` which calls `pathFileExistsW` on Windows. This reports
/// existing directories as well, and treats special names like "nul" as
/// existing. An empty path never exists.
fn pathExists(allocator: Allocator, path: []const u8) bool {
    if (path.len == 0) return false;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch return false;
    return PathFileExistsW(wide).toBool();
}

/// Convert an argument to a NUL terminated UTF-16 string. `""` becomes `null`,
/// which is harmless for lpOperation/lpDirectory/lpFile and matters for
/// lpParameters (an empty parameter string would otherwise be passed along).
fn toW(os: Allocator, value: []const u8) !?windows.LPCWSTR {
    if (value.len == 0) return null;
    return try std.unicode.utf8ToUtf16LeAllocZ(os, value);
}

/// Call `ShellExecuteW` (the same Win32 API as the C3 `win::shell_exec`).
/// Returns true on success. ShellExecuteW uses an HINSTANCE return value whose
/// numeric value is really a status code: values > 32 mean success.
fn shellExec(
    io: Io,
    allocator: Allocator,
    work_dir: []const u8,
    target: []const u8,
    parameters: []const u8,
) bool {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const operation_w = toW(arena, "open") catch null;
    const target_w = toW(arena, target) catch null;
    const parameters_w = toW(arena, parameters) catch null;
    const work_dir_w = toW(arena, work_dir) catch null;

    const result: usize = @intFromPtr(ShellExecuteW(
        null,
        operation_w,
        target_w,
        parameters_w,
        work_dir_w,
        SW_NORMAL,
    ));

    if (result > 32) return true;
    // Same as the C3 original: report the raw ShellExecuteW status code and
    // return failure. Callers map this to exit code 1.
    stderrPrint(io, "Failed to open file ({d})\r\n", .{result});
    return false;
}

/// `io::eprintfn` equivalent: format into a small stack buffer and write to
/// stderr, ignoring write errors.
fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    Io.File.stderr().writeStreamingAll(io, text) catch {};
}
