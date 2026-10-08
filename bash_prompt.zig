//! bash_prompt - a PROMPT_COMMAND for bash on Windows.
//!
//! Zig rewrite of bash_prompt.c3. Prints the current directory (optionally
//! shortened), the git branch and the number of changed files. Output is
//! kept byte-for-byte identical to the C3 original (see `toTextMode`).
//!
//! Build with Zig 0.17.0 (no build.zig):
//!   zig build-exe -OReleaseFast -femit-bin=dist/bash_prompt.exe bash_prompt.zig

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The prompt is emitted with CRLF line endings. On Windows the original runs
/// stdout in text mode, which turns every `\n` into `\r\n`; `stdoutWriteAllText`
/// reproduces that so the output is byte-for-byte identical (including the
/// resulting `\r\r\n` for the `\r\n` literals below).
const NEW_LINE = "\r\n";

const Ansi = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const italic = "\x1b[3m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
};

// Note the plain `\n` line ends here: `toTextMode` turns them into CRLF on the
// way out. `NEW_LINE` below is a literal `\r\n`, so it becomes `\r\r\n`.
const HELP_TEXT =
    "bash_prompt, a PROMPT_COMMAND\n" ++
    "flags:\n" ++
    "\t--short: enable short dir name\n" ++
    "\t--venv: show BP_ENV_XXX for multi version programs\n" ++
    "\t--init: print init script. To quick setup, run: bash_prompt --init >> ~/.bashrc\n" ++
    "\t--help: print this message\n";

const Flags = struct {
    use_short_name: bool = false,
    show_env_xxx: bool = false,
    show_init: bool = false,
    show_help: bool = false,
    exe_name: []const u8 = "",
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

    var flag = Flags{};
    for (args, 0..) |arg, i| {
        if (i == 0) {
            flag.exe_name = arg;
            continue;
        }

        if (std.mem.eql(u8, arg, "--short")) {
            flag.use_short_name = true;
        } else if (std.mem.eql(u8, arg, "--venv")) {
            flag.show_env_xxx = true;
        } else if (std.mem.eql(u8, arg, "--init")) {
            flag.show_init = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            flag.show_help = true;
        }
        // Unknown flags are silently ignored, matching the C3 original.
    }

    if (flag.show_help) {
        try stdoutWriteAllText(io, HELP_TEXT);
        return 0;
    }

    if (flag.show_init) {
        // Print a snippet to append to ~/.bashrc. `exe_name` keeps the name the
        // tool was invoked with (e.g. "bash_prompt" or "bash_prompt.exe"), and
        // only its basename is used, matching the C3 original.
        const basename = std.fs.path.basename(flag.exe_name);
        const text = try allocator.print(
            "\nPROMPT_COMMAND=\"{s} --short --venv\"; export PROMPT_COMMAND; PS1=\"\\$ \";",
            .{basename},
        );
        try stdoutWriteAllText(io, text);
        return 0;
    }

    // If the cwd cannot be obtained, print nothing (same as the original).
    const cwd = std.process.currentPathAlloc(io, allocator) catch return 0;

    // The home directory is used to fold the path prefix into "~". The C3
    // original reads USERPROFILE on Windows; PATH separators are normalized
    // to '/' before the comparison.
    const home = if (init.environ_map.get("USERPROFILE")) |raw|
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
    try stdoutWriteAllText(io, out.items);
    return 0;
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

    try out.appendSlice(allocator, Ansi.blue);
    try out.appendSlice(allocator, Ansi.bold);
    try out.appendSlice(allocator, view);
    try out.appendSlice(allocator, Ansi.reset);
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
    try out.appendSlice(allocator, Ansi.yellow);
    try out.appendSlice(allocator, branch);
    try out.appendSlice(allocator, Ansi.reset);

    const changed = try fileChanges(io, allocator, root);
    if (changed > 0) {
        var num_buf: [20]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{changed}) catch unreachable;
        try out.appendSlice(allocator, Ansi.red);
        try out.appendSlice(allocator, " <");
        try out.appendSlice(allocator, num);
        try out.appendSlice(allocator, ">");
        try out.appendSlice(allocator, Ansi.reset);
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

    var count: usize = 0;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |_| count += 1;
    return count;
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

/// Write to stdout with the Windows text-mode translation applied (see
/// `toTextMode`). Used for every byte the tool emits.
fn stdoutWriteAllText(io: Io, bytes: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.page_allocator);
    try toTextMode(std.heap.page_allocator, &out, bytes);
    try Io.File.stdout().writeStreamingAll(io, out.items);
}

/// Reproduce Windows text-mode stdout: every `\n` becomes `\r\n` (so a `\r\n`
/// in the source ends up as `\r\r\n`, exactly like the C3 original).
fn toTextMode(allocator: Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    for (bytes) |byte| {
        if (byte == '\n') {
            try out.appendSlice(allocator, "\r\n");
        } else {
            try out.append(allocator, byte);
        }
    }
}
