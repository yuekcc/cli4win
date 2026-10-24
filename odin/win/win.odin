//! win - shared Windows helpers for the Odin ports of open.c3 and launch.c3.
//!
//! Mirrors win.c3 and win.zig: `shell_exec` wraps ShellExecuteW, so it behaves
//! like a double click or the `start` command. The path normalization is ported
//! from the C3 std (`std::io::path`) because Odin's `filepath` neither rejects
//! the same reserved characters nor produces the same `INVALID_PATH` fault.
//! Windows only.

package win

import "core:fmt"
import "core:sys/windows"

// Show the window in its normal (restored) state.
SW_NORMAL :: 1

// Displayed when a path has reserved characters. Hardcoded to match the C3
// `%s` formatting of the `path::INVALID_PATH` fault.
INVALID_PATH_MESSAGE :: "path::INVALID_PATH"

is_separator :: proc(c: u8) -> bool {
	return c == '/' || c == '\\'
}

// The C3 original rejects these characters in path components on Windows.
is_reserved_win32_path_char :: proc(c: u8) -> bool {
	switch c {
	case 0 ..= 31, '>', '<', ':', '"', '/', '\\', '|', '?', '*':
		return true
	}
	return false
}

// Port of C3 `volume_name_len_win`: length of a Windows volume prefix
// ("C:", "\\\\?\\", ...). Returns ok=false for a malformed UNC prefix,
// matching the original.
volume_name_len_win :: proc(path: []u8) -> (n: int, ok: bool) {
	path_len := len(path)
	if path_len < 2 {
		return 0, true
	}

	switch path[0] {
	case '\\':
		if path_len == 2 {
			return 0, true
		}
		count := 1
		for count < path_len && path[count] == '\\' {
			count += 1
		}
		if count != 2 {
			return 0, true
		}
		base_found := 0
		for i := 2; i < path_len; i += 1 {
			c := path[i]
			if is_separator(c) {
				if base_found != 0 {
					return i, true
				}
				base_found = i
				continue
			}
			if is_reserved_win32_path_char(c) {
				return 0, false
			}
		}
		if base_found > 0 && base_found + 1 < path_len {
			return path_len, true
		}
		return 0, false
	case 'A' ..= 'Z', 'a' ..= 'z':
		if path[1] == ':' {
			return 2, true
		}
		return 0, true
	}

	return 0, true
}

// Port of C3 `Path::new` for Windows: fold redundant separators and `.`/`..`
// components, canonicalize separators to `\`, and validate characters.
//
// Returns the normalized path plus ok=true, or ok=false when the path contains
// a reserved character (the caller prints INVALID_PATH_MESSAGE then).
normalize_path :: proc(input: string) -> (path: string, ok: bool) {
	if len(input) == 0 {
		return "", true
	}

	buf := make([]u8, len(input) + 1)
	copy(buf, input)
	path_len := len(input)

	path_start, volume_ok := volume_name_len_win(buf[:path_len])
	if !volume_ok {
		return "", false
	}
	if path_start > 0 {
		for i in 0 ..< path_start {
			if buf[i] == '/' {
				buf[i] = '\\'
			}
		}
	}
	if path_start == path_len {
		return string(buf[:path_len]), true
	}

	n := path_start
	has_root := is_separator(buf[path_start])
	if has_root {
		buf[n] = '\\'
		n += 1
		path_start += 1
	}
	previous_was_separator := true

	for i := path_start; i < path_len; i += 1 {
		c := buf[i]

		// Fold repeated separators.
		if is_separator(c) {
			if previous_was_separator {
				continue
			}
			buf[n] = '\\'
			n += 1
			previous_was_separator = true
			continue
		}

		if is_reserved_win32_path_char(c) {
			return "", false
		}

		// Handle "." and ".." components.
		if c == '.' && previous_was_separator {
			is_last := i == path_len - 1
			dots: u8 = 1
			if !is_last {
				next := buf[i + 1]
				if next == '.' {
					dots = 2
					is_last = i == path_len - 2
					if !is_last && !is_separator(buf[i + 2]) {
						dots = 0
					}
				} else if !is_separator(next) {
					dots = 0
				}
			}
			switch dots {
			case 1:
				// "./" -> skip the dot and the following separator.
				i += 1
				continue
			case 2:
				// "/.." above the root is invalid.
				if n == path_start && has_root {
					return "", false
				}

				// Leading or repeated "..": keep it verbatim.
				if n == path_start ||
				   (n - path_start >= 3 &&
						   buf[n - 1] == '\\' &&
						   buf[n - 3] == '.' &&
						   buf[n - 2] == '.' &&
						   (n - 3 == 0 || buf[n - 4] == '\\')) {
					if i != n {
						buf[n] = '.'
						buf[n + 1] = '.'
					}
					n += 2
					if n < path_len {
						buf[n] = '\\'
						n += 1
					}
					i += 2
					continue
				}

				// Otherwise step back over the previous component.
				n -= 1
				for n > path_start && !is_separator(buf[n - 1]) {
					n -= 1
				}
				i += 2
				continue
			}
		}

		if i != n {
			buf[n] = c
		}
		previous_was_separator = false
		n += 1
	}

	// Drop a trailing separator (except for a bare root like "\").
	if n > path_start + 1 && is_separator(buf[n - 1]) {
		n -= 1
	}
	if n == 0 {
		buf[0] = '.'
		return string(buf[:1]), true
	}

	return string(buf[:n]), true
}

// True when `path` exists (file or directory), matching the C3 original's
// `path::exists`, which calls PathFileExistsW on Windows. This reports existing
// directories as well and treats special names like "nul" as existing. An empty
// path never exists.
path_exists :: proc(path: string) -> bool {
	if len(path) == 0 {
		return false
	}
	wide := windows.utf8_to_wstring(path, context.temp_allocator)
	if wide == nil {
		return false
	}
	return windows.PathFileExistsW(wide) != false
}

// Convert an argument to a NUL terminated UTF-16 string, mapping "" to nil.
// nil is harmless for lpOperation/lpDirectory/lpFile and matters for
// lpParameters (an empty parameter string would otherwise be passed along).
to_wide :: proc(value: string) -> windows.LPCWSTR {
	if len(value) == 0 {
		return nil
	}
	return windows.utf8_to_wstring(value, context.temp_allocator)
}

// Call ShellExecuteW (the same Win32 API as the C3 `win::shell_exec`).
// Returns true on success. ShellExecuteW returns an HINSTANCE whose numeric
// value is really a status code: values > 32 mean success.
shell_exec :: proc(work_dir, target, parameters: string) -> bool {
	result := windows.ShellExecuteW(
		nil,
		to_wide("open"),
		to_wide(target),
		to_wide(parameters),
		to_wide(work_dir),
		SW_NORMAL,
	)

	code := int(uintptr(result))
	if code > 32 {
		return true
	}

	// Same as the C3 original: report the raw ShellExecuteW status code and
	// return failure. Callers map this to exit code 1.
	fmt.eprintf("Failed to open file (%d)\r\n", code)
	return false
}
