//! launch - read a config file and run the command it describes.
//!
//! Odin rewrite of launch.c3. Given an executable named `<name>.exe`, it loads
//! `<name>.exe.json` from the executable's directory, substitutes `$CWD` in the
//! arguments with the current directory, then hands the command to
//! ShellExecuteW (via odin/win). Windows only.
//!
//! Config format:
//!   {
//!     "command": "python",
//!     "changeDir": true,
//!     "args": ["script.py", "$CWD"]
//!   }
//!
//! Build:
//!   odin build launch.odin -file -o:speed -out:dist/launch.exe

package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "odin/win"

Config :: struct {
	command:    string,
	change_dir: bool `json:"changeDir"`,
	args:       []string,
}

main :: proc() {
	cwd, cwd_err := os.get_working_directory(context.allocator)
	if cwd_err != nil {
		os.exit(1)
	}

	// `<exe>.json` lives next to the executable, named after it.
	exe_path, exe_err := os.get_executable_path(context.allocator)
	if exe_err != nil {
		fmt.eprintf("Error, cannot resolve executable path\r\n")
		os.exit(1)
	}
	install_path := filepath.dir(exe_path)
	config_name := fmt.aprintf("%s.json", filepath.base(exe_path))
	config_path, join_err := filepath.join([]string{install_path, config_name})
	if join_err != nil {
		fmt.eprintf("Error, cannot resolve config path\r\n")
		os.exit(1)
	}

	config_data, read_err := os.read_entire_file_from_path(config_path, context.allocator)
	if read_err != nil {
		fmt.eprintf("Error, cannot read config %s: %v\r\n", config_path, read_err)
		os.exit(1)
	}

	config: Config
	if unmarshal_err := json.unmarshal(config_data, &config); unmarshal_err != nil {
		fmt.eprintf("Error, invalid config %s: %v\r\n", config_path, unmarshal_err)
		os.exit(1)
	}

	if len(config.command) == 0 {
		fmt.eprintf("Error, config %s has no \"command\"\r\n", config_path)
		os.exit(1)
	}

	// The command is normalized the same way open.c3 handles a target path
	// (canonical separators, folded "." / "..").
	command, ok := win.normalize_path(config.command)
	if !ok {
		fmt.eprintf("Error, %s. Input = %s\r\n", win.INVALID_PATH_MESSAGE, config.command)
		os.exit(1)
	}

	// Build the argument string, replacing `$CWD` when changeDir is set.
	flags: strings.Builder
	strings.builder_init_none(&flags)
	for arg in config.args {
		flag := arg
		if config.change_dir && flag == "$CWD" {
			flag = cwd
		}
		strings.write_string(&flags, flag)
		strings.write_string(&flags, " ")
	}

	work_dir := config.change_dir ? install_path : cwd
	os.exit(win.shell_exec(work_dir, command, strings.to_string(flags)) ? 0 : 1)
}
