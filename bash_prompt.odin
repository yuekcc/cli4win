//! bash_prompt - a PROMPT_COMMAND for bash on Windows and Linux.
//!
//! Odin rewrite of bash_prompt.c3. Prints the current directory (optionally
//! shortened), the git branch and the number of changed files, using
//! platform-native line endings: "\r\n" on Windows (the C3 original relies on
//! the CRT's text mode, which widens every "\n" for `fwrite`) and "\n" on
//! POSIX, where text and binary modes are identical.
//!
//! Build (smallest binary):
//!   odin build bash_prompt.odin -file -o:size -disable-assert -no-bounds-check -no-type-assert -out:dist/bash_prompt.exe

package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

// The prompt is separated from the shell by a native newline. The C3 original
// writes a bare '\n' and lets the Windows CRT turn it into "\r\n"; Odin writes
// bytes verbatim, so the widening happens here at compile time instead.
NEW_LINE :: "\r\n" when ODIN_OS == .Windows else "\n"

// `env::get_home_dir`: USERPROFILE on Windows, HOME elsewhere.
HOME_ENV :: "USERPROFILE" when ODIN_OS == .Windows else "HOME"

Ansi :: struct {
	RESET:  string,
	BOLD:   string,
	ITALIC: string,
	RED:    string,
	YELLOW: string,
	BLUE:   string,
}

ANSI :: Ansi {
	RESET  = "\x1b[0m",
	BOLD   = "\x1b[1m",
	ITALIC = "\x1b[3m",
	RED    = "\x1b[31m",
	YELLOW = "\x1b[33m",
	BLUE   = "\x1b[34m",
}

// `io::printn` adds one platform newline, so the text itself stops before it.
HELP_TEXT :: "bash_prompt, a PROMPT_COMMAND" + NEW_LINE +
	"flags:" + NEW_LINE +
	"\t--short: enable short dir name" + NEW_LINE +
	"\t--venv: show BP_ENV_XXX for multi version programs" + NEW_LINE +
	"\t--init: print init script. To quick setup, run: bash_prompt --init >> ~/.bashrc" + NEW_LINE +
	"\t--help: print this message"

// The `--init` snippet, split around the executable name so it can be written
// without concatenation at runtime.
INIT_PREFIX :: NEW_LINE + "PROMPT_COMMAND=\""
INIT_SUFFIX :: " --short --venv\"; export PROMPT_COMMAND; PS1=\"\\$ \";"

CommandLineFlag :: struct {
	use_short_name: bool,
	show_env_xxx:   bool,
	show_init:      bool,
	show_help:      bool,
	exe_name:       string,
}

// Parse argv, mirroring the C3 original: argv[0] is stored as `exe_name` and
// unknown flags are silently ignored.
parse_flags :: proc(argv: []string) -> CommandLineFlag {
	flag: CommandLineFlag
	for arg, i in argv {
		if i == 0 {
			flag.exe_name = arg
			continue
		}
		switch arg {
		case "--short":
			flag.use_short_name = true
		case "--venv":
			flag.show_env_xxx = true
		case "--init":
			flag.show_init = true
		case "--help", "-h":
			flag.show_help = true
		case:
			// Unknown flags are ignored, same as the original.
		}
	}
	return flag
}

main :: proc() {
	flag := parse_flags(os.args)

	if flag.show_help {
		os.write_string(os.stdout, HELP_TEXT)
		os.write_string(os.stdout, NEW_LINE)
		return
	}

	if flag.show_init {
		// Print a snippet to append to ~/.bashrc. Only the basename of the
		// invoked name is used, matching the C3 original.
		os.write_string(os.stdout, INIT_PREFIX)
		os.write_string(os.stdout, filepath.base(flag.exe_name))
		os.write_string(os.stdout, INIT_SUFFIX)
		return
	}

	// If the cwd cannot be obtained, print nothing (same as the original).
	cwd, cwd_err := os.get_working_directory(context.allocator)
	if cwd_err != nil {
		return
	}

	out: strings.Builder
	strings.builder_init_none(&out)

	strings.write_string(&out, NEW_LINE)
	print_cwd(&out, cwd, flag.use_short_name)
	print_git(&out, cwd)
	if flag.show_env_xxx {
		environ, _ := os.environ(context.allocator)
		print_env_xxx(&out, environ)
	}
	strings.write_string(&out, NEW_LINE)

	os.write_string(os.stdout, strings.to_string(out))
}

// Append `text` wrapped in `style` ... reset. Mirrors the C3 `style` macro.
append_styled :: proc(out: ^strings.Builder, style, text: string) {
	strings.write_string(out, style)
	strings.write_string(out, text)
	strings.write_string(out, ANSI.RESET)
}

// Print the cwd in blue + bold. Backslashes are normalized to '/' first.
print_cwd :: proc(out: ^strings.Builder, cwd: string, use_short_name: bool) {
	cwd_str, _ := strings.replace_all(cwd, "\\", "/")
	view := short_view(cwd_str, use_short_name)
	append_styled(out, ANSI.BLUE + ANSI.BOLD, view)
}

// Print the git suffix: ` @ <branch>` in yellow, and ` <N>` in red when there
// are changed files. Prints nothing when cwd is not inside a repo.
print_git :: proc(out: ^strings.Builder, cwd: string) {
	root, found := find_git_root(cwd)
	if !found {
		return
	}

	strings.write_string(out, " @ ")
	append_styled(out, ANSI.YELLOW, branch_name(root))

	changed := file_changes(root)
	if changed > 0 {
		num_buf: [32]u8
		append_styled(out, ANSI.RED, fmt.bprintf(num_buf[:], " <%d>", changed))
	}
}

// Walk up from `cwd` until a `.git` entry is found, returning that directory
// (the repo root), like `Repo.try_init`.
find_git_root :: proc(cwd: string) -> (root: string, found: bool) {
	current := cwd
	for {
		git_dir := filepath.join([]string{current, ".git"}) or_break
		if os.exists(git_dir) {
			return current, true
		}

		parent := filepath.dir(current)
		if parent == current || len(parent) == 0 {
			break
		}
		current = parent
	}
	return "", false
}

// Read the branch from `.git/HEAD` directly (no git subprocess, like the C3
// original), stripping the "ref: refs/heads/" prefix. Returns "" when HEAD
// cannot be read.
branch_name :: proc(root: string) -> string {
	head_path, join_err := filepath.join([]string{root, ".git", "HEAD"})
	if join_err != nil {
		return ""
	}
	content, read_err := os.read_entire_file_from_path(head_path, context.allocator)
	if read_err != nil {
		return ""
	}

	value, _ := strings.replace_all(string(content), "ref: refs/heads/", "")
	return strings.trim_space(value)
}

// Number of changed files, via `git status --porcelain` (one line per entry).
file_changes :: proc(root: string) -> int {
	output := run_git(root, []string{"status", "--porcelain"})
	return count_changed_files(output)
}

// Run git with the same fixed prefix as the C3 original. Failures (e.g. a
// missing `git` binary) degrade to an empty string, so the prompt still shows.
//
// The C3 `cmd::execute` spawned git with STDERR_TO_STDOUT; here only stdout is
// counted, which is identical for `--porcelain` output in normal use (the Zig
// rewrite does the same).
run_git :: proc(root: string, command_line: []string) -> string {
	argv: [dynamic]string
	append(&argv, "git", "-C", root, "--no-optional-locks", "--no-pager")
	append(&argv, ..command_line)
	defer delete(argv)

	_, stdout, stderr, err := os.process_exec(
		{command = argv[:]},
		context.allocator,
	)
	defer delete(stdout)
	defer delete(stderr)
	if err != nil {
		return ""
	}

	return strings.clone(strings.trim_space(string(stdout)))
}

// `git status --porcelain` prints one line per entry; the original counted
// `output.split("\n").len`. Since `run_git` trims a trailing newline, N entries
// are separated by N-1 newlines.
count_changed_files :: proc(output: string) -> int {
	if len(output) == 0 {
		return 0
	}
	return strings.count(output, "\n") + 1
}

// Append one ` (value)` per BP_ENV_* variable, italicized.
//
// The C3 original split each "KEY=VALUE" on '=' and printed `xs[1]`, i.e. the
// text right after the first '='. Iteration order follows the environment
// block order, matching the original which walked `environ`.
print_env_xxx :: proc(out: ^strings.Builder, environ: []string) {
	for entry in environ {
		if !strings.has_prefix(entry, "BP_ENV_") {
			continue
		}

		parts := strings.split(entry, "=", context.allocator)
		if len(parts) < 2 {
			// The original read xs[1] unguarded; an environment entry without
			// '=' is malformed, so skip it rather than read out of bounds.
			continue
		}

		strings.write_string(out, ANSI.ITALIC)
		strings.write_string(out, " (")
		strings.write_string(out, parts[1])
		strings.write_string(out, ")")
		strings.write_string(out, ANSI.RESET)
	}
}

// Fold `home` into "~", then split on '/' and abbreviate the intermediate
// components to their first character when `use_short_name` is set.
//
// The first component (drive or "~") and the final component are never
// abbreviated: e.g. `C:/Users/me/projects/app` becomes `C:/U/m/p/app`, and
// `/home/me/app` becomes `/h/m/app`. This mirrors the C3 original, including
// its edge case of keeping a trailing '/' when the path ends in a separator
// (the last split element is empty).
short_view :: proc(work_dir: string, use_short_name: bool) -> string {
	home: string
	if raw := os.get_env(HOME_ENV, context.allocator); len(raw) > 0 {
		home, _ = strings.replace_all(raw, "\\", "/")
	}

	dir := work_dir
	if len(home) > 0 && strings.has_prefix(dir, home) {
		dir, _ = strings.replace_all(dir, home, "~")
	}

	paths := strings.split(dir, "/", context.allocator)

	out: strings.Builder
	strings.builder_init_none(&out)
	for part, i in paths {
		if i == 0 {
			strings.write_string(&out, part)
			strings.write_string(&out, "/")
		} else if i == len(paths) - 1 {
			strings.write_string(&out, part)
		} else {
			if use_short_name {
				// The original kept the first UTF-16 code unit; use the first
				// whole UTF-8 scalar value instead.
				strings.write_string(&out, first_rune(part))
			} else {
				strings.write_string(&out, part)
			}
			strings.write_string(&out, "/")
		}
	}

	return strings.to_string(out)
}

// First Unicode scalar value of `s`.
first_rune :: proc(s: string) -> string {
	if len(s) == 0 {
		return s
	}
	_, size := utf8.decode_rune_in_string(s)
	if size <= 0 {
		return s[:1]
	}
	return s[:min(size, len(s))]
}
