//! open - open a file, directory or URI with the Windows shell.
//!
//! Odin rewrite of open.c3. Uses ShellExecuteW (via odin/win, the same API as
//! the C3 `win::shell_exec`), so it behaves like a double click or the `start`
//! command. Windows only.
//!
//! Build:
//!   odin build open.odin -file -o:speed -out:dist/open.exe

package main

import "core:fmt"
import "core:os"
import "core:strings"

import "odin/win"

main :: proc() {
	argv := os.args

	cwd, cwd_err := os.get_working_directory(context.allocator)
	if cwd_err != nil {
		os.exit(1)
	}

	// The target defaults to the current directory.
	target_file := "."
	if len(argv) > 1 {
		target_file = argv[1]
	}

	// Open URLs / mail addresses directly.
	if strings.has_prefix(target_file, "http:") ||
	   strings.has_prefix(target_file, "https:") ||
	   strings.has_prefix(target_file, "mailto:") {
		os.exit(open_uri(cwd, target_file))
	}

	os.exit(open_file(cwd, target_file, argv))
}

open_uri :: proc(cwd, uri: string) -> int {
	return win.shell_exec(cwd, uri, "") ? 0 : 1
}

// Check that the target exists, then hand it (plus any extra arguments) to the
// shell. On failure it prints the same message and returns exit code 1 as the
// C3 original.
open_file :: proc(cwd, file_path: string, argv: []string) -> int {
	target, ok := win.normalize_path(file_path)
	if !ok {
		fmt.eprintf("Error, %s. Input = %s\r\n", win.INVALID_PATH_MESSAGE, file_path)
		return 1
	}

	if !win.path_exists(target) {
		fmt.eprintf("Error, file not found. File path = %s\r\n", target)
		return 1
	}

	// Extra arguments (after the file path) are passed through to the target.
	parameters: strings.Builder
	strings.builder_init_none(&parameters)
	if len(argv) > 2 {
		for i := 2; i < len(argv); i += 1 {
			strings.write_string(&parameters, argv[i])
			strings.write_string(&parameters, " ")
		}
	}

	return win.shell_exec(cwd, target, strings.to_string(parameters)) ? 0 : 1
}
