//! launch - 读取配置文件，运行其中描述的命令。
//!
//! 这是 launch.c3 的 Odin 重写版。假设可执行文件名为 `<name>.exe`，程序会读取
//! 同目录下的 `<name>.exe.json`，把参数里的 `$CWD` 替换成当前目录，再把命令交给
//! ShellExecuteW（封装在 odin/win 里）执行。仅支持 Windows。
//!
//! 执行流程：
//!   1. 取当前工作目录，作为 `$CWD` 的替换值；
//!   2. 定位可执行文件所在目录，拼出配置文件路径；
//!   3. 读取并解析 JSON 配置；
//!   4. 校验 command，并用 win.normalize_path 规范化；
//!   5. 拼接参数字符串，按需把 `$CWD` 换成真实目录；
//!   6. 调用 ShellExecuteW 启动，把成功/失败映射成进程退出码。
//!
//! 配置格式：
//!   {
//!     "command": "python",
//!     "changeDir": true,
//!     "args": ["script.py", "$CWD"]
//!   }
//!
//! 编译：
//!   odin build launch.odin -file -o:speed -out:../dist/launch.exe

package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "win"

// 配置文件映射成的结构体。
//
// json.unmarshal 默认按字段名匹配 JSON 键名，所以需要 `changeDir` 这种驼峰键时，
// 用标签 `json:"changeDir"` 显式指定；其余字段名与 JSON 键名一致。
Config :: struct {
	// 要执行的程序名或文件路径。会被 win.normalize_path 规范化。
	command:    string,
	// true 时：新进程的工作目录设为 exe 所在目录，并且参数里的 `$CWD`
	// 会被替换成调用方当前目录；false 时：工作目录保持调用方当前目录，
	// 参数原样传递。
	change_dir: bool `json:"changeDir"`,
	// 传给命令的参数列表，按顺序拼接成一个以空格分隔的字符串。
	args:       []string,
}

main :: proc() {
	// 先取当前目录：changeDir 为 true 时它用来替换 `$CWD`，为 false 时它同时
	// 作为新进程的工作目录。取不到就直接失败，因为后续逻辑都依赖它。
	cwd, cwd_err := os.get_working_directory(context.allocator)
	if cwd_err != nil {
		os.exit(1)
	}

	// 配置文件放在可执行文件旁边，并沿用可执行文件名：
	//   dist\launch.exe  ->  dist\launch.exe.json
	// 这样复制/改名 exe 就对应另一份配置，同一个二进制可当通用启动器使用。
	exe_path, exe_err := os.get_executable_path(context.allocator)
	if exe_err != nil {
		fmt.eprintf("Error, cannot resolve executable path\r\n")
		os.exit(1)
	}
	// install_path 是 exe 所在目录（不含文件名）。
	install_path := filepath.dir(exe_path)
	// config_name 是 "<exe 文件名>.json"，例如 "launch.exe.json"。
	config_name := fmt.aprintf("%s.json", filepath.base(exe_path))
	// 拼出完整配置路径；filepath.join 失败只会在参数非法时发生。
	config_path, join_err := filepath.join([]string{install_path, config_name})
	if join_err != nil {
		fmt.eprintf("Error, cannot resolve config path\r\n")
		os.exit(1)
	}

	// 一次性读入整个配置文件；失败（文件不存在、无权限等）就报错退出。
	config_data, read_err := os.read_entire_file_from_path(config_path, context.allocator)
	if read_err != nil {
		fmt.eprintf("Error, cannot read config %s: %v\r\n", config_path, read_err)
		os.exit(1)
	}

	// 解析 JSON。字段缺失时保持零值（command 为空串、change_dir 为 false、
	// args 为 nil），所以下面必须单独校验 command 是否为空。
	config: Config
	if unmarshal_err := json.unmarshal(config_data, &config); unmarshal_err != nil {
		fmt.eprintf("Error, invalid config %s: %v\r\n", config_path, unmarshal_err)
		os.exit(1)
	}

	// command 是唯一必需的字段，缺失或空串都视为配置错误。
	if len(config.command) == 0 {
		fmt.eprintf("Error, config %s has no \"command\"\r\n", config_path)
		os.exit(1)
	}

	// 先用 C3 版的路径规则把 command 规范化：统一分隔符、折叠 "." 与 ".."、
	// 拒绝 Windows 保留字符。和 open.c3 处理目标路径的方式保持一致。
	command, ok := win.normalize_path(config.command)
	if !ok {
		fmt.eprintf("Error, %s. Input = %s\r\n", win.INVALID_PATH_MESSAGE, config.command)
		os.exit(1)
	}

	// 把参数列表拼成一个字符串：ShellExecuteW 只接受单个 lpParameters，
	// 没法直接传 argv 数组，所以这里按“参数 + 空格”拼接。
	//
	// 注意：参数内部的引号/空格不做转义，这是刻意与 C3 原版保持一致的行为，
	// 需要空格的参数应自己带引号。
	flags: strings.Builder
	strings.builder_init_none(&flags)
	for arg in config.args {
		flag := arg
		// 只有 changeDir 打开时 `$CWD` 才是占位符，否则按字面量原样传下去。
		if config.change_dir && flag == "$CWD" {
			flag = cwd
		}
		strings.write_string(&flags, flag)
		strings.write_string(&flags, " ")
	}

	// changeDir 为 true 时在安装目录下执行（脚本通常相对于 exe 定位），
	// 否则沿用调用方当前目录。两种情况下 command 本身都已是绝对路径或
	// 可被 ShellExecuteW 解析的名字。
	work_dir := config.change_dir ? install_path : cwd
	// shell_exec 返回 bool，这里映射成 0/1 退出码，方便调用方脚本判断。
	os.exit(win.shell_exec(work_dir, command, strings.to_string(flags)) ? 0 : 1)
}
