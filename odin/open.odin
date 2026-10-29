//! open - 用 Windows 外壳（Shell）打开文件、目录或 URI。
//!
//! 这是 open.c3 的 Odin 重写版。底层调用 ShellExecuteW（封装在 odin/win 里，
//! 与 C3 的 `win::shell_exec` 是同一个 API），因此行为和双击文件或 `start`
//! 命令一致。仅支持 Windows。
//!
//! 执行流程：
//!   1. 取当前工作目录，作为新进程的工作目录；
//!   2. 确定目标：argv[1]，缺省则为 "."（当前目录）；
//!   3. 目标是 http:/https:/mailto: 时直接当 URI 打开；
//!   4. 否则当作文件/目录：规范化路径、检查存在，再连同多余参数一起打开。
//!
//! 编译：
//!   odin build open.odin -file -o:speed -out:../dist/open.exe

package main

import "core:fmt"
import "core:os"
import "core:strings"

import "win"

main :: proc() {
	// os.args[0] 是程序名，真正的目标是 args[1] 开始的部分参数。
	argv := os.args

	// 取不到当前目录就没法执行，直接失败退出。
	cwd, cwd_err := os.get_working_directory(context.allocator)
	if cwd_err != nil {
		os.exit(1)
	}

	// 目标默认为当前目录，这样无参数运行时相当于打开资源管理器。
	target_file := "."
	if len(argv) > 1 {
		target_file = argv[1]
	}

	// 协议前缀的目标交给默认浏览器/邮件客户端处理。这里用前缀匹配而不是
	// 解析 URL：只要以 "http:"、"https:" 或 "mailto:" 开头就原样传给 shell，
	// 既不规范化也不做存在性检查。
	if strings.has_prefix(target_file, "http:") ||
	   strings.has_prefix(target_file, "https:") ||
	   strings.has_prefix(target_file, "mailto:") {
		os.exit(open_uri(cwd, target_file))
	}

	os.exit(open_file(cwd, target_file, argv))
}

// 直接打开 URI：不拼参数，工作目录用调用方当前目录。
// 返回 0/1 退出码，与 win.shell_exec 的 bool 结果对应。
open_uri :: proc(cwd, uri: string) -> int {
	return win.shell_exec(cwd, uri, "") ? 0 : 1
}

// 打开文件或目录：先检查目标存在，再把目标（加上多余参数）交给 shell。
// 失败时打印与 C3 原版一致的信息并返回退出码 1。
open_file :: proc(cwd, file_path: string, argv: []string) -> int {
	// 路径规范化：统一成反斜杠、折叠 "." / ".."、校验保留字符。
	// 含保留字符时返回 ok=false，这里按 C3 的 INVALID_PATH 故障处理。
	target, ok := win.normalize_path(file_path)
	if !ok {
		fmt.eprintf("Error, %s. Input = %s\r\n", win.INVALID_PATH_MESSAGE, file_path)
		return 1
	}

	// 规范化后再判断存在性（文件或目录都算存在）。不存在的路径不交给
	// shell，避免弹出系统自己的错误对话框。
	if !win.path_exists(target) {
		fmt.eprintf("Error, file not found. File path = %s\r\n", target)
		return 1
	}

	// 目标之后的额外参数原样透传（例如用默认程序打开时附带的参数）。
	// 同样按“参数 + 空格”拼接，不做引号转义，保持与 C3 原版一致。
	parameters: strings.Builder
	strings.builder_init_none(&parameters)
	if len(argv) > 2 {
		for i := 2; i < len(argv); i += 1 {
			strings.write_string(&parameters, argv[i])
			strings.write_string(&parameters, " ")
		}
	}

	// 实际打开：动词固定为 "open"，窗口正常显示，成败转成 0/1 退出码。
	return win.shell_exec(cwd, target, strings.to_string(parameters)) ? 0 : 1
}
