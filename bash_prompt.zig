//! bash_prompt - a PROMPT_COMMAND for bash on Windows and Linux.
//!
//! Zig rewrite of bash_prompt.c3. Prints the current directory (optionally
//! shortened), the git branch and the number of changed files, using
//! platform-native line endings (CRLF on Windows, LF on Linux).
//!
//! Build with Zig 0.17.0 (no build.zig):
//!   zig build-exe -OReleaseFast -femit-bin=dist/bash_prompt.exe bash_prompt.zig

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;

// bash_prompt targets Windows and Linux only; `textMode` and the home-directory
// lookup below branch on the target OS, so pin the supported set here.
comptime {
    std.debug.assert(builtin.target.os.tag == .windows or
        builtin.target.os.tag == .linux);
}

const Ansi = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const italic = "\x1b[3m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
};

/// Turn a constant's LF line endings into the platform-native ones at compile
/// time: `\n` becomes `\r\n` on Windows (the C3 original relies on the CRT's
/// text mode, which does the same for `fwrite`), and is left alone on Linux
/// (POSIX text and binary modes are identical). Because it runs in a `comptime`
/// block, every constant below is stored already expanded; nothing is
/// allocated or rewritten at runtime.
fn textMode(comptime input: []const u8) []const u8 {
    if (builtin.target.os.tag != .windows) return input;
    comptime {
        var buf: [input.len * 2]u8 = undefined;
        var len: usize = 0;
        for (input) |byte| {
            if (byte == '\n') {
                buf[len] = '\r';
                buf[len + 1] = '\n';
                len += 2;
            } else {
                buf[len] = byte;
                len += 1;
            }
        }
        const frozen: [len]u8 = buf[0..len].*;
        return &frozen;
    }
}

/// The prompt is separated from the shell by a native newline. Written as a
/// single `\n` constant and widened by `textMode`, so Windows gets `\r\n` and
/// Linux gets `\n` (no stray CR).
const NEW_LINE = textMode("\n");

const HELP_TEXT = textMode(
    "bash_prompt, a PROMPT_COMMAND\n" ++
        "flags:\n" ++
        "\t--short: enable short dir name\n" ++
        "\t--venv: show BP_ENV_XXX for multi version programs\n" ++
        "\t--init: print init script. To quick setup, run: bash_prompt --init >> ~/.bashrc\n" ++
        "\t--help: print this message\n",
);

/// The `--init` snippet, split around the executable name so it can be written
/// without concatenation.
const INIT_PREFIX = textMode("\nPROMPT_COMMAND=\"");
const INIT_SUFFIX = textMode(" --short --venv\"; export PROMPT_COMMAND; PS1=\"\\$ \";");

const Flags = struct {
    use_short_name: bool = false,
    show_env_xxx: bool = false,
    show_init: bool = false,
    show_help: bool = false,
    exe_name: [:0]const u8 = "",
};

/// Flag name -> struct field. Two names may map to the same field (the
/// `--help`/`-h` pair). `parseFlags` walks this with `inline for`, so the
/// comparisons are unrolled at compile time and adding a flag is a one-line
/// change here.
const flag_specs = .{
    .{ .name = "--short", .field = "use_short_name" },
    .{ .name = "--venv", .field = "show_env_xxx" },
    .{ .name = "--init", .field = "show_init" },
    .{ .name = "--help", .field = "show_help" },
    .{ .name = "-h", .field = "show_help" },
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch 1;
}

/// Runs as a bash `PROMPT_COMMAND`: bash executes it before printing each
/// prompt, so its stdout is injected into the terminal stream. It emits a
/// single line: the (optionally shortened) cwd, plus git info and BP_ENV_*
/// values when requested.
///
/// Argument parsing mirrors the C3 original: `argv[0]` is the executable name,
/// unknown flags are ignored, and `--help`/`-h` produces the usage text.
fn run(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    const flag = parseFlags(args);

    if (flag.show_help) {
        try writeStdout(io, HELP_TEXT);
        return 0;
    }

    if (flag.show_init) {
        // Print a snippet to append to ~/.bashrc. `exe_name` keeps the name the
        // tool was invoked with (e.g. "bash_prompt" or "bash_prompt.exe"), and
        // only its basename is used, matching the C3 original.
        try writeStdout(io, INIT_PREFIX);
        try writeStdout(io, std.fs.path.basename(flag.exe_name));
        try writeStdout(io, INIT_SUFFIX);
        return 0;
    }

    // If the cwd cannot be obtained, print nothing (same as the original).
    const cwd = std.process.currentPathAlloc(io, allocator) catch return 0;

    // The home directory is used to fold the path prefix into "~". This mirrors
    // the C3 `env::get_home_dir`: `USERPROFILE` on Windows, `HOME` elsewhere.
    // PATH separators are normalized to '/' before the comparison.
    const home_env = if (builtin.target.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = if (init.environ_map.get(home_env)) |raw|
        try replaceAll(allocator, raw, "\\", "/")
    else
        null;

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, NEW_LINE);

    try printCwd(&out, allocator, cwd, home, flag.use_short_name);
    try printGit(&out, io, allocator, cwd);

    if (flag.show_env_xxx) {
        try printEnvXxx(&out, allocator, init.environ_map);
    }

    try out.appendSlice(allocator, NEW_LINE);
    try writeStdout(io, out.items);
    return 0;
}

/// Parse argv, mirroring the C3 original: `argv[0]` is stored as `exe_name`
/// and unknown flags are silently ignored.
fn parseFlags(args: []const [:0]const u8) Flags {
    var flag = Flags{};
    for (args, 0..) |arg, i| {
        if (i == 0) {
            flag.exe_name = arg;
            continue;
        }
        inline for (flag_specs) |spec| {
            if (std.mem.eql(u8, arg, spec.name)) @field(flag, spec.field) = true;
        }
    }
    return flag;
}

/// Append `text` wrapped in `style` ... reset. `style` is comptime known so the
/// prefix is a constant; only `text` is runtime data.
fn appendStyled(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    comptime style: []const u8,
    text: []const u8,
) !void {
    try out.appendSlice(allocator, style);
    try out.appendSlice(allocator, text);
    try out.appendSlice(allocator, Ansi.reset);
}

/// Print the cwd in blue + bold. Backslashes are normalized to '/' first.
fn printCwd(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    cwd: []const u8,
    home: ?[]const u8,
    use_short_name: bool,
) !void {
    const normalized = try replaceAll(allocator, cwd, "\\", "/");
    const view = try shortView(allocator, normalized, home, use_short_name);
    try appendStyled(out, allocator, Ansi.blue ++ Ansi.bold, view);
}

/// Fold `home` into "~", then split on '/' and abbreviate the intermediate
/// components to their first character when `use_short_name` is set.
///
/// The first component (drive or "~") and the final component are never
/// abbreviated: e.g. `C:/Users/me/projects/app` becomes `C:/U/m/p/app`, and
/// `/home/me/app` becomes `/h/m/app`. This mirrors the C3 original, including
/// its edge case of keeping a trailing '/' when the path ends in a separator
/// (the last split element is empty).
fn shortView(
    allocator: Allocator,
    work_dir: []const u8,
    home: ?[]const u8,
    use_short_name: bool,
) ![]u8 {
    var dir = work_dir;
    if (home) |h| {
        if (h.len > 0 and std.mem.startsWith(u8, dir, h)) {
            const rest = dir[h.len..];
            const folded = try allocator.alloc(u8, 1 + rest.len);
            folded[0] = '~';
            @memcpy(folded[1..], rest);
            dir = folded;
        }
    }

    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, dir, '/');
    while (it.next()) |part| {
        try parts.append(allocator, part);
    }
    const len = parts.items.len;

    var out: std.ArrayList(u8) = .empty;
    for (parts.items, 0..) |part, i| {
        if (i == 0) {
            try out.appendSlice(allocator, part);
            try out.append(allocator, '/');
        } else if (i == len - 1) {
            try out.appendSlice(allocator, part);
        } else {
            if (use_short_name) {
                try out.appendSlice(allocator, firstCodepoint(part));
            } else {
                try out.appendSlice(allocator, part);
            }
            try out.append(allocator, '/');
        }
    }

    return out.items;
}

/// First Unicode scalar value of `s` (roughly the first UTF-16 code unit the
/// original used for the short name).
fn firstCodepoint(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    const seq_len = std.unicode.utf8ByteSequenceLength(s[0]) catch return s[0..1];
    return s[0..@min(@as(usize, seq_len), s.len)];
}

/// Print the git suffix: ` @ <branch>` in yellow, and ` <N>` in red when
/// there are changed files. Prints nothing when `cwd` is not in a repo.
fn printGit(
    out: *std.ArrayList(u8),
    io: Io,
    allocator: Allocator,
    cwd: []const u8,
) !void {
    const root = (try findGitRoot(io, allocator, cwd)) orelse return;

    const branch = try branchName(io, allocator, root);
    try out.appendSlice(allocator, " @ ");
    try appendStyled(out, allocator, Ansi.yellow, branch);

    const changed = try fileChanges(io, allocator, root);
    if (changed > 0) {
        var num_buf: [32]u8 = undefined;
        const suffix = std.fmt.bufPrint(&num_buf, " <{d}>", .{changed}) catch unreachable;
        try appendStyled(out, allocator, Ansi.red, suffix);
    }
}

/// Walk up from `cwd` until a `.git` entry is found, returning that directory.
fn findGitRoot(io: Io, allocator: Allocator, cwd: []const u8) !?[]const u8 {
    var current: []const u8 = cwd;
    while (true) {
        const git_dir = try std.fs.path.join(allocator, &.{ current, ".git" });
        if (pathExists(io, git_dir)) return current;
        current = std.fs.path.dirname(current) orelse return null;
    }
}

/// Read the branch from `.git/HEAD` directly (no git subprocess, like the C3
/// original). Detached HEADs keep the raw "ref: ..." text if it does not match
/// the refs/heads prefix. Returns "" when HEAD cannot be read.
fn branchName(io: Io, allocator: Allocator, root: []const u8) ![]const u8 {
    const head_path = try std.fs.path.join(allocator, &.{ root, ".git", "HEAD" });
    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        head_path,
        allocator,
        .limited(4096),
    ) catch return "";

    var value = std.mem.trim(u8, content, " \t\r\n");
    const prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, value, prefix)) {
        value = value[prefix.len..];
    }
    return value;
}

/// Number of changed files, via `git status --porcelain` (one line per entry).
fn fileChanges(io: Io, allocator: Allocator, root: []const u8) !usize {
    const output = try runGit(io, allocator, root, &.{ "status", "--porcelain" });
    return countChangedFiles(output);
}

/// Run git with the same fixed prefix as the C3 original. Failures (e.g. a
/// missing `git` binary) degrade to an empty string, so the prompt still shows.
fn runGit(
    io: Io,
    allocator: Allocator,
    root: []const u8,
    command_line: []const []const u8,
) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "git", "-C", root, "--no-optional-locks", "--no-pager" });
    try argv.appendSlice(allocator, command_line);

    const result = std.process.run(allocator, io, .{ .argv = argv.items }) catch return "";
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

/// `git status --porcelain` prints one line per entry. The C3 original counted
/// `output.split("\n").len`, and Zig's `splitScalar` yields the same count for
/// non-empty input: N lines -> N results with trailing newline stripped. When
/// the trimmed output is empty the count is 0, matching `count_changed_files`.
fn countChangedFiles(output: []const u8) usize {
    if (output.len == 0) return 0;
    // N entries are separated by N-1 newlines.
    return std.mem.count(u8, output, "\n") + 1;
}

/// Append one ` (value)` per BP_ENV_* variable, italicized.
///
/// The C3 original split each "KEY=VALUE" on '=' and printed `xs[1]`, i.e. the
/// text right after the first '='; we reproduce that by truncating at the first
/// '='. Iteration order is unspecified for both versions.
fn printEnvXxx(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    environ_map: *std.process.Environ.Map,
) !void {
    var it = environ_map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, key, "BP_ENV_")) continue;

        const value = entry.value_ptr.*;
        const shown = if (std.mem.indexOfScalar(u8, value, '=')) |idx| value[0..idx] else value;

        try out.appendSlice(allocator, Ansi.italic);
        try out.appendSlice(allocator, " (");
        try out.appendSlice(allocator, shown);
        try out.appendSlice(allocator, ")");
        try out.appendSlice(allocator, Ansi.reset);
    }
}

fn pathExists(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn replaceAll(
    allocator: Allocator,
    input: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, input, needle, replacement);
}

/// Write bytes to stdout. Every constant passed here has already been expanded
/// by `textMode`, and the dynamic pieces (cwd, branch, exe name) cannot contain
/// a raw `\n` on Windows, so no runtime translation is needed.
fn writeStdout(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}
