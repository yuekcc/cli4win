//! bash_prompt - 供 bash 使用的 PROMPT_COMMAND，支持 Windows 和 Linux。
//!
//! 这是 bash_prompt.c3 的 Odin 重写版。输出当前目录（可缩短显示）和 git 分支。
//! 变更文件数量默认不显示，因为统计它需要额外启动一个 `git status` 子进程，
//! 只有加 `--git` 时才统计。
//!
//! 换行符按平台取原生写法：Windows 用 "\r\n"（C3 原版依赖 CRT 的文本模式，
//! 把 `fwrite` 的每个 "\n" 撑宽），POSIX 用 "\n"（那里文本模式与二进制模式
//! 没有区别）。Odin 直接写字节，所以这个“撑宽”改在编译期完成。
//!
//! 编译（最小体积）：
//!   odin build bash_prompt.odin -file -o:size -disable-assert -no-bounds-check -no-type-assert -out:../dist/bash_prompt.exe

package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

// 提示符前先换一行，把输入行和提示符分开。
//
// `when` 是编译期分支：只保留当前目标平台的那一个常量，另一支不参与编译。
// C3 原版只写一个 '\n'，由 Windows CRT 转成 "\r\n"；Odin 逐字节输出，
// 所以这里在编译期就选好要写的字节。
NEW_LINE :: "\r\n" when ODIN_OS == .Windows else "\n"

// 家目录对应的环境变量名：Windows 用 USERPROFILE，其他平台用 HOME。
// 这与 C3 `env::get_home_dir` 的实现一致。
HOME_ENV :: "USERPROFILE" when ODIN_OS == .Windows else "HOME"

// 一组 ANSI 转义序列，用于给提示符的不同部分上色/加样式。
Ansi :: struct {
	RESET:  string, // 复位所有样式
	BOLD:   string, // 加粗
	ITALIC: string, // 斜体
	RED:    string, // 红色（用于变更数量）
	YELLOW: string, // 黄色（用于 git 分支）
	BLUE:   string, // 蓝色（用于目录）
}

// 具体的转义序列取值。颜色用的是标准 8 色的前景色码（30+）。
ANSI :: Ansi {
	RESET  = "\x1b[0m",
	BOLD   = "\x1b[1m",
	ITALIC = "\x1b[3m",
	RED    = "\x1b[31m",
	YELLOW = "\x1b[33m",
	BLUE   = "\x1b[34m",
}

// --help 的输出文本。
//
// 换行在这里就拼好，文本本身不含结尾换行；main 里输出完整块后再补一个
// NEW_LINE，效果等同于 C3 的 `io::printn`（它只追加一个平台换行）。
HELP_TEXT :: "bash_prompt, a PROMPT_COMMAND" + NEW_LINE +
	"flags:" + NEW_LINE +
	"\t--short: enable short dir name" + NEW_LINE +
	"\t--git: show changed file count (spawns git status)" + NEW_LINE +
	"\t--venv: show BP_ENV_XXX for multi version programs" + NEW_LINE +
	"\t--init: print init script. To quick setup, run: bash_prompt --init >> ~/.bashrc" + NEW_LINE +
	"\t--help: print this message"

// --init 输出的片段。拆成前缀/后缀两段，中间在运行时插入 exe 文件名，
// 这样可以全部用编译期常量，不需要在运行时做字符串拼接。
//
// 生成的内容形如：
//   PROMPT_COMMAND="bash_prompt --short --venv"; export PROMPT_COMMAND; PS1="\$ ";
INIT_PREFIX :: NEW_LINE + "PROMPT_COMMAND=\""
INIT_SUFFIX :: " --short --venv\"; export PROMPT_COMMAND; PS1=\"\\$ \";"

// 解析后的命令行开关。
CommandLineFlag :: struct {
	use_short_name: bool,   // --short：中间目录只显示首字母
	show_git:       bool,   // --git：显示变更文件数（会起 git 子进程）
	show_env_xxx:   bool,   // --venv：显示 BP_ENV_* 环境变量
	show_init:      bool,   // --init：打印 .bashrc 片段
	show_help:      bool,   // --help / -h：打印帮助
	exe_name:       string, // argv[0]，--init 时取它的 basename
}

// 遍历 argv 解析开关。
//
// 与 C3 原版保持一致：argv[0] 存进 exe_name（不是开关），无法识别的参数
// 直接忽略，不报错。多个开关可以任意组合。
parse_flags :: proc(argv: []string) -> CommandLineFlag {
	flag: CommandLineFlag
	for arg, i in argv {
		// 第 0 个参数是程序路径，留作 --init 时取文件名。
		if i == 0 {
			flag.exe_name = arg
			continue
		}
		switch arg {
		case "--short":
			flag.use_short_name = true
		case "--git":
			flag.show_git = true
		case "--venv":
			flag.show_env_xxx = true
		case "--init":
			flag.show_init = true
		case "--help", "-h":
			flag.show_help = true
		case:
			// 未知开关忽略，和原版一致——bash 里混入其他参数不至于报错。
		}
	}
	return flag
}

main :: proc() {
	flag := parse_flags(os.args)

	// --help 优先级最高：打印帮助后立即返回，不输出提示符。
	if flag.show_help {
		os.write_string(os.stdout, HELP_TEXT)
		os.write_string(os.stdout, NEW_LINE)
		return
	}

	// --init 也属于“纯输出后退出”的模式：只打 .bashrc 片段，不做 git 查询。
	// 片段里的程序名只取 basename，这样无论从哪儿调用都写得进 shell 配置。
	if flag.show_init {
		os.write_string(os.stdout, INIT_PREFIX)
		os.write_string(os.stdout, filepath.base(flag.exe_name))
		os.write_string(os.stdout, INIT_SUFFIX)
		return
	}

	// 常规模式：取不到 cwd 就什么都不输出（与原版一致，避免污染提示符）。
	cwd, cwd_err := os.get_working_directory(context.allocator)
	if cwd_err != nil {
		return
	}

	// 提示符整体先攒进 builder，最后一次性写出，减少 write 系统调用次数，
	// 也避免多段输出被其他进程的日志插进来。
	out: strings.Builder
	strings.builder_init_none(&out)

	// 结构：换行 + 目录 + git 后缀 + 环境标记 + 换行。
	// 结尾的换行让 bash 在下一行显示输入光标。
	strings.write_string(&out, NEW_LINE)
	print_cwd(&out, cwd, flag.use_short_name)
	print_git(&out, cwd, flag.show_git)
	if flag.show_env_xxx {
		// 环境变量取一次，供所有 BP_ENV_* 判断使用；分配失败时 environ 为空，
		// 循环会直接跳过（不影响目录和分支的显示）。
		environ, _ := os.environ(context.allocator)
		print_env_xxx(&out, environ)
	}
	strings.write_string(&out, NEW_LINE)

	os.write_string(os.stdout, strings.to_string(out))
}

// 把 `text` 包成「`style` ... 复位」，追加到 `out`。
// 对应 C3 里的 `style` 宏；只做拼接，不关心样式码具体含义。
append_styled :: proc(out: ^strings.Builder, style, text: string) {
	strings.write_string(out, style)
	strings.write_string(out, text)
	strings.write_string(out, ANSI.RESET)
}

// 输出当前目录：蓝色 + 加粗。
//
// 先把反斜杠统一成正斜杠，保证 Windows 和 Linux 下的切分/缩写逻辑一致，
// 再交给 short_view 决定是否缩写。
print_cwd :: proc(out: ^strings.Builder, cwd: string, use_short_name: bool) {
	cwd_str, _ := strings.replace_all(cwd, "\\", "/")
	view := short_view(cwd_str, use_short_name)
	append_styled(out, ANSI.BLUE + ANSI.BOLD, view)
}

// 输出 git 后缀：` @ <分支名>`，黄色。
//
// 变更数量 ` <N>`（红色）只在 `show_changes` 为真时才算，因为它要起
// `git status --porcelain` 子进程；分支名则是直接读 `.git/HEAD`，只是一次
// 普通文件读取，所以默认就显示。cwd 不在任何仓库里时不输出任何东西。
print_git :: proc(out: ^strings.Builder, cwd: string, show_changes: bool) {
	root, found := find_git_root(cwd)
	if !found {
		return
	}

	// 前缀里的空格是格式的一部分：目录和分支之间用 " @ " 分隔。
	strings.write_string(out, " @ ")
	append_styled(out, ANSI.YELLOW, branch_name(root))

	if show_changes {
		changed := file_changes(root)
		// 0 个变更时不显示，保持提示符干净。
		if changed > 0 {
			// 用栈上的固定缓冲格式化数字，避免额外堆分配。
			num_buf: [32]u8
			append_styled(out, ANSI.RED, fmt.bprintf(num_buf[:], " <%d>", changed))
		}
	}
}

// 从 `cwd` 开始逐级向上找，直到遇到含 `.git` 的目录，返回该目录（仓库根），
// 对应 C3 的 `Repo.try_init`。
//
// 不调用 git 命令，纯靠文件系统判断，所以很快。失败返回 found=false。
// 循环终止条件：父目录与当前目录相同（已到根）或父目录为空。
find_git_root :: proc(cwd: string) -> (root: string, found: bool) {
	current := cwd
	for {
		// or_break：拼接失败（参数非法）时直接跳出循环，按“未找到”处理。
		git_dir := filepath.join([]string{current, ".git"}) or_break
		// 用 exists 而不是判断目录：worktree 里 `.git` 可能是文件。
		if os.exists(git_dir) {
			return current, true
		}

		// 向上退一层；到达文件系统根后 dir 会返回自身，据此结束循环。
		parent := filepath.dir(current)
		if parent == current || len(parent) == 0 {
			break
		}
		current = parent
	}
	return "", false
}

// 直接读 `.git/HEAD` 拿分支名（不起 git 子进程，与 C3 原版一致）。
//
// HEAD 内容有两种形式：
//   ref: refs/heads/main     -> 当前在分支 main 上
//   <40 位 commit hash>      -> 分离头指针（detached HEAD），此时前缀替换没有
//                               匹配项，函数会把 hash 原样返回
// 读不到文件时返回空串，调用方仍然会输出 " @ " 前缀（与原版行为一致）。
branch_name :: proc(root: string) -> string {
	head_path, join_err := filepath.join([]string{root, ".git", "HEAD"})
	if join_err != nil {
		return ""
	}
	content, read_err := os.read_entire_file_from_path(head_path, context.allocator)
	if read_err != nil {
		return ""
	}

	// 只去掉标准的分支前缀；再做 trim 去掉行尾的换行/空白。
	value, _ := strings.replace_all(string(content), "ref: refs/heads/", "")
	return strings.trim_space(value)
}

// 变更文件数：执行 `git status --porcelain`，一个条目一行。
file_changes :: proc(root: string) -> int {
	output := run_git(root, []string{"status", "--porcelain"})
	return count_changed_files(output)
}

// 执行 git，并带上与 C3 原版相同的固定前缀：
//   -C <root>            在仓库根下执行，避免依赖当前目录
//   --no-optional-locks  不写 index 锁，避免和用户并发的 git 操作抢锁
//   --no-pager           禁止分页器，否则输出可能卡在 less 里
//
// 失败（例如没装 git）时退化成空串，提示符仍然能正常显示。
//
// 另外：C3 的 `cmd::execute` 以前把 STDERR 合并到 STDOUT，这里只统计 stdout。
// 对 `--porcelain` 的正常输出两者等价（Zig 版也这么处理）。
run_git :: proc(root: string, command_line: []string) -> string {
	// 用动态数组拼 argv：固定三项前缀 + 调用方给的参数。
	argv: [dynamic]string
	append(&argv, "git", "-C", root, "--no-optional-locks", "--no-pager")
	append(&argv, ..command_line)
	// defer 保证函数返回时释放 argv 的底层数组（字符串内容本身是常量，不释放）。
	defer delete(argv)

	// process_exec 会等待子进程结束并收集输出；stderr 拿到但不使用。
	_, stdout, stderr, err := os.process_exec(
		{command = argv[:]},
		context.allocator,
	)
	defer delete(stdout)
	defer delete(stderr)
	if err != nil {
		return ""
	}

	// 结果去掉首尾空白后克隆一份再返回：这里的字符串本应由调用方释放，
	// 但提示符进程只跑一次、随即退出，交给操作系统回收即可。
	return strings.clone(strings.trim_space(string(stdout)))
}

// 统计 `git status --porcelain` 的条目数：每个条目一行。
//
// 原版是数 `output.split("\n").len`。因为 run_git 已经去掉了结尾换行，
// 所以 N 个条目之间只有 N-1 个换行，返回值是换行数 + 1。
// 空输出（工作区干净）单独返回 0，避免把空串算成 1 个条目。
count_changed_files :: proc(output: string) -> int {
	if len(output) == 0 {
		return 0
	}
	return strings.count(output, "\n") + 1
}

// 对每个 BP_ENV_* 环境变量追加一段 ` (值)`，用斜体显示。
//
// 用途：同一程序有多个版本/环境时（例如不同 Python、不同工具链），
// 用 BP_ENV_PYTHON=3.12 这类变量提示当前处于哪个环境。
//
// C3 原版把每个 "KEY=VALUE" 按 '=' 切开后打印 `xs[1]`，也就是第一个 '='
// 之后的全部内容。遍历顺序跟随环境块顺序，与原版遍历 `environ` 一致。
print_env_xxx :: proc(out: ^strings.Builder, environ: []string) {
	for entry in environ {
		// 只关心带 BP_ENV_ 前缀的变量，其余跳过。
		if !strings.has_prefix(entry, "BP_ENV_") {
			continue
		}

		// 按第一个 '=' 切分；值里再出现 '=' 会留在 parts[1] 中，符合预期。
		parts := strings.split(entry, "=", context.allocator)
		if len(parts) < 2 {
			// 原版直接读 xs[1] 不做保护；没有 '=' 的条目属于畸形环境变量，
			// 这里跳过而不是越界读取。
			continue
		}

		strings.write_string(out, ANSI.ITALIC)
		strings.write_string(out, " (")
		strings.write_string(out, parts[1])
		strings.write_string(out, ")")
		strings.write_string(out, ANSI.RESET)
	}
}

// 生成目录显示文本：先把 `home` 折叠成 "~"，再按 '/' 切成若干段；
// 开了 `use_short_name` 时，把中间各段缩成首字母。
//
// 规则：第一段（盘符或 "~"）和最后一段（当前目录名）永不缩写。
// 例如：
//   C:/Users/me/projects/app  ->  C:/U/m/p/app
//   /home/me/app              ->  /h/m/app
// 这与 C3 原版一致，包括它的边界情况：路径以分隔符结尾时，split 的最后一段
// 是空串，于是输出仍保留结尾的 '/'。
short_view :: proc(work_dir: string, use_short_name: bool) -> string {
	// 读取家目录环境变量；取不到或为空时 home 保持空串，下面就不做 "~" 折叠。
	home: string
	if raw := os.get_env(HOME_ENV, context.allocator); len(raw) > 0 {
		// 同样把反斜杠统一成正斜杠，才能和已规范化的 work_dir 做前缀比较。
		home, _ = strings.replace_all(raw, "\\", "/")
	}

	// 路径以家目录开头时，把这段前缀整体替换成 "~"（只替换第一次出现）。
	dir := work_dir
	if len(home) > 0 && strings.has_prefix(dir, home) {
		dir, _ = strings.replace_all(dir, home, "~")
	}

	// 以 '/' 切分。Odin 的 split 会保留空串元素，所以开头的 "/" 会切出一个
	// 空的第 0 段，结尾的 "/" 会切出一个空的最后一段。
	paths := strings.split(dir, "/", context.allocator)

	out: strings.Builder
	strings.builder_init_none(&out)
	for part, i in paths {
		if i == 0 {
			// 第一段原样输出（盘符 "C:"、"~" 或空串），后面补一个 '/'，
			// 这样绝对路径开头的 "/" 就被正确还原。
			strings.write_string(&out, part)
			strings.write_string(&out, "/")
		} else if i == len(paths) - 1 {
			// 最后一段是当前目录名，原样输出，且不再补 '/'。
			strings.write_string(&out, part)
		} else {
			// 中间段：按开关决定缩写。
			if use_short_name {
				// 原版取第一个 UTF-16 码元；这里改为取第一个完整的 UTF-8
				// 码点，避免把多字节字符截成半个。
				strings.write_string(&out, first_rune(part))
			} else {
				strings.write_string(&out, part)
			}
			strings.write_string(&out, "/")
		}
	}

	return strings.to_string(out)
}

// 返回 `s` 的第一个 Unicode 码点（按 UTF-8 编码的字节切片）。
// 空串原样返回；非法 UTF-8 时 decode 返回 size<=0，退化为取第一个字节。
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
