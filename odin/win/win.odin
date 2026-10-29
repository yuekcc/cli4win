//! win - open.c3 / launch.c3 的 Odin 移植版共用的 Windows 辅助函数。
//!
//! 对应 win.c3 和 win.zig：
//!   - `shell_exec` 封装 ShellExecuteW，行为等价于双击文件或 `start` 命令；
//!   - 路径规范化移植自 C3 标准库 `std::io::path`。之所以不用 Odin 自带的
//!     `core:path/filepath`，是因为它既不会以同样的方式拒绝保留字符，也
//!     不会产生同样的 `INVALID_PATH` 故障，无法保持与 C3 版一致的行为。
//! 仅支持 Windows。

package win

import "core:fmt"
import "core:sys/windows"

// ShellExecuteW 的 nShowCmd 参数：以普通（还原）状态显示窗口。
// 打开文件夹、文档时基本看不出来，但打开程序窗口时就是“正常大小”。
SW_NORMAL :: 1

// 路径含保留字符时对外显示的错误名。
//
// 硬编码成这个字符串，是为了和 C3 版 `%s` 格式化 `path::INVALID_PATH` 故障时
// 输出的文本完全一致（调用方直接打印它）。
INVALID_PATH_MESSAGE :: "path::INVALID_PATH"

// 是否是路径分隔符。规范化阶段两种斜杠都接受。
is_separator :: proc(c: u8) -> bool {
	return c == '/' || c == '\\'
}

// Windows 下路径组件中不允许出现的字符，与 C3 原版一致：
//   - 0..31：控制字符；
//   - '>' '<' ':' '"' '|' '?' '*'：Win32 文件名保留字符；
//   - '/' '\\'：分隔符（本应已被单独处理，出现在这里说明用法异常）。
//
// 注意 ':' 也在其中：盘符里的冒号由卷名解析提前消费，普通组件里出现冒号
// 一律视为非法（不放开 NTFS 的备用数据流写法）。
is_reserved_win32_path_char :: proc(c: u8) -> bool {
	switch c {
	case 0 ..= 31, '>', '<', ':', '"', '/', '\\', '|', '?', '*':
		return true
	}
	return false
}

// 移植自 C3 `volume_name_len_win`：返回路径中“卷名前缀”的字节长度，
// 例如 "C:"、"\\server\share"，其余部分才是普通组件。
//
// 返回值：
//   n  —— 卷名前缀长度，0 表示没有卷名（相对路径、"/foo" 之类）；
//   ok —— false 表示 UNC 写法非法（例如缺少 share 名，或含保留字符），
//         调用方应按 INVALID_PATH 拒绝整条路径。
//
// 判定分三种情况：
//   1. 长度不足 2，或首字符既不是 '\\' 也不是字母 —— 没有卷名；
//   2. 首字符是 '\\' —— 可能是 UNC 前缀，下面细扫；
//   3. 首字符是字母 —— 只有紧跟 ':' 才算盘符卷名，否则没有卷名。
volume_name_len_win :: proc(path: []u8) -> (n: int, ok: bool) {
	path_len := len(path)
	// 少于两个字符不可能构成任何卷名前缀（最短的是 "C:"）。
	if path_len < 2 {
		return 0, true
	}

	switch path[0] {
	case '\\':
		// 恰好两个字符（"\\"）不当作 UNC：没有 server/share 可言，
		// 按“无卷名”处理，交给后续规范化逻辑。
		if path_len == 2 {
			return 0, true
		}
		// 数一数开头有几个连续反斜杠。只有正好两个才可能是 UNC
		// （"\\server\share"）；一个（"\foo"）是根路径，三个以上
		// （"\\\foo"）属于畸形写法，同样按“无卷名”处理。
		count := 1
		for count < path_len && path[count] == '\\' {
			count += 1
		}
		if count != 2 {
			return 0, true
		}
		// 从第 3 个字节开始找 server 名与 share 名的结束分隔符。
		base_found := 0
		for i := 2; i < path_len; i += 1 {
			c := path[i]
			if is_separator(c) {
				if base_found != 0 {
					// 已经找到过第一个分隔符，这次是 share 名结束，
					// 卷名前缀到此为止。
					return i, true
				}
				// 第一个分隔符：server 名结束，记下位置继续找 share 名。
				base_found = i
				continue
			}
			// server/share 名里不允许出现保留字符。
			// （顺带一提：'?' 也是保留字符，所以 "\\?\" 设备前缀会被判非法。）
			if is_reserved_win32_path_char(c) {
				return 0, false
			}
		}
		// 扫到结尾都没有第二个分隔符，只有两种情况是合法的：
		// 找到过 server 分隔符，且 share 名后面还有字符（此时整条路径就是卷名）。
		if base_found > 0 && base_found + 1 < path_len {
			return path_len, true
		}
		// 其余都是残缺 UNC（"\\server"、"\\server\" 等）。
		return 0, false
	case 'A' ..= 'Z', 'a' ..= 'z':
		// 盘符：字母 + ':' 才是卷名，占用两个字节。
		if path[1] == ':' {
			return 2, true
		}
		return 0, true
	}

	// 其他首字符：没有卷名。
	return 0, true
}

// 移植自 C3 `Path::new` 的 Windows 版本。完成四件事：
//   1. 折叠重复分隔符；
//   2. 折叠 "." 与 ".." 组件；
//   3. 把分隔符统一成 '\\'；
//   4. 校验保留字符。
//
// 返回规范化后的路径与 ok=true；若路径含保留字符（或 ".." 试图越过根），
// 返回 ok=false，调用方此时打印 INVALID_PATH_MESSAGE。
//
// 实现要点：全部在输入的一个副本上原地压缩——`i` 是读游标，`n` 是写游标，
// 由于只删不增，恒有 n <= i，所以可以边读边写而不破坏尚未读取的数据。
// 返回的 string 是这块堆内存的切片；这里有意不释放，因为进程即将退出
// （open/launch 都是短命进程），交给操作系统回收即可。
normalize_path :: proc(input: string) -> (path: string, ok: bool) {
	// 空路径本来就是“当前目录”的意思，原样返回。
	if len(input) == 0 {
		return "", true
	}

	// 多分配 1 字节：写入 ".." 时可能要先补分隔符，留一点余量。
	buf := make([]u8, len(input) + 1)
	copy(buf, input)
	path_len := len(input)

	// 先解析卷名前缀（"C:"、"\\server\share"）。非法 UNC 直接失败。
	// 之后所有分隔符处理都从 path_start 开始，不碰卷名内部。
	path_start, volume_ok := volume_name_len_win(buf[:path_len])
	if !volume_ok {
		return "", false
	}
	// 卷名里的 '/' 也要统一成 '\\'（例如 "C:/foo" 的前两个字节）。
	if path_start > 0 {
		for i in 0 ..< path_start {
			if buf[i] == '/' {
				buf[i] = '\\'
			}
		}
	}
	// 整条路径就是一个卷名（如 "C:"），没有需要处理的组件。
	if path_start == path_len {
		return string(buf[:path_len]), true
	}

	// n 是写游标，从卷名之后开始。
	n := path_start
	// 根：卷名后紧跟分隔符时，规范化成单个 '\\' 并写出去
	// （比如 "C://foo" 的第二个 '/' 会被折叠掉）。
	has_root := is_separator(buf[path_start])
	if has_root {
		buf[n] = '\\'
		n += 1
		path_start += 1
	}
	// 初始为 true：让紧跟卷名/根之后的点也能参与 "." 与 ".." 的判定
	// （例如 "C:."、"./foo"），而不是被当成普通字符。
	previous_was_separator := true

	for i := path_start; i < path_len; i += 1 {
		c := buf[i]

		// 连续分隔符只保留一个：上一个已经是分隔符就跳过当前这个。
		if is_separator(c) {
			if previous_was_separator {
				continue
			}
			buf[n] = '\\'
			n += 1
			previous_was_separator = true
			continue
		}

		// 普通字符里出现保留字符，整条路径判非法。
		if is_reserved_win32_path_char(c) {
			return "", false
		}

		// 处理 "." 与 ".." 组件。
		// 只在组件起始位置（前一个字符是分隔符）才可能是指代组件；
		// 还要确认点号之后就是路径结尾或分隔符，否则 ".gitignore"、
		// "..foo" 这类名字里的点只是普通字符。
		if c == '.' && previous_was_separator {
			is_last := i == path_len - 1
			dots: u8 = 1
			if !is_last {
				next := buf[i + 1]
				if next == '.' {
					dots = 2
					is_last = i == path_len - 2
					// ".." 后面必须接结尾或分隔符，否则是 "..name" 这种名字。
					if !is_last && !is_separator(buf[i + 2]) {
						dots = 0
					}
				} else if !is_separator(next) {
					// ".name"：不是单独的 "." 组件。
					dots = 0
				}
			}
			switch dots {
			case 1:
				// "./" —— 点本身不产生输出，连同后面那个分隔符一起跳过；
				// 循环末尾还会 i += 1，所以这里只加 1。
				i += 1
				continue
			case 2:
				// "/.." 越过根：没有上级可退，判非法。
				if n == path_start && has_root {
					return "", false
				}

				// 前一个组件不存在（相对路径开头），或者前一个组件本身就是
				// ".."，都无法再回退，于是把 ".." 原样保留。
				if n == path_start ||
				   (n - path_start >= 3 &&
						   buf[n - 1] == '\\' &&
						   buf[n - 3] == '.' &&
						   buf[n - 2] == '.' &&
						   (n - 3 == 0 || buf[n - 4] == '\\')) {
					// i == n 时 ".." 已经在正确位置，不必复制。
					if i != n {
						buf[n] = '.'
						buf[n + 1] = '.'
					}
					n += 2
					// 还没到结尾就补一个分隔符；这里用 n < path_len 判断，
					// 由后面的尾部分隔符清理兜底。
					if n < path_len {
						buf[n] = '\\'
						n += 1
					}
					i += 2
					continue
				}

				// 正常情况：回退到上一个分隔符之前，等于删掉上一个组件。
				// 先丢掉它后面的分隔符，再往回走到该组件起点。
				n -= 1
				for n > path_start && !is_separator(buf[n - 1]) {
					n -= 1
				}
				i += 2
				continue
			}
			// dots == 0：普通名字，落到下面按普通字符复制。
		}

		// 普通字符：i != n 说明前面有压缩，需要把字节前移。
		if i != n {
			buf[n] = c
		}
		previous_was_separator = false
		n += 1
	}

	// 去掉结尾多余的分隔符，但裸根（如 C:\ 或 \）要保留：
	// 那种情况下 n == path_start + 1，不满足下面的条件。
	if n > path_start + 1 && is_separator(buf[n - 1]) {
		n -= 1
	}
	// 全部被折叠掉（输入就是 "."）时，结果取当前目录 "."。
	if n == 0 {
		buf[0] = '.'
		return string(buf[:1]), true
	}

	return string(buf[:n]), true
}

// 路径是否存在（文件或目录都算），对应 C3 原版的 `path::exists`
// （Windows 上就是 PathFileExistsW）。
//
// 语义细节：
//   - 目录也算存在；
//   - "nul"、"con" 这类设备名会被判定为存在；
//   - 空路径永远不存在。
path_exists :: proc(path: string) -> bool {
	if len(path) == 0 {
		return false
	}
	// Win32 的 W 版本接口要 UTF-16；转换失败（非法 UTF-8 等）按不存在处理。
	wide := windows.utf8_to_wstring(path, context.temp_allocator)
	if wide == nil {
		return false
	}
	return windows.PathFileExistsW(wide) != false
}

// 把参数转成以 NUL 结尾的 UTF-16 字符串；空串映射为 nil。
//
// 为什么空串要变 nil：对 lpOperation / lpDirectory / lpFile 来说 nil 与空串
// 等价，但 lpParameters 若传空串，ShellExecuteW 会把它当成“有一个空参数”，
// 传 nil 才是“没有参数”。
//
// 内存来自临时分配器，不需要手动释放；这些指针只要在这次 ShellExecuteW
// 调用期间有效即可。
to_wide :: proc(value: string) -> windows.LPCWSTR {
	if len(value) == 0 {
		return nil
	}
	return windows.utf8_to_wstring(value, context.temp_allocator)
}

// 调用 ShellExecuteW（与 C3 的 `win::shell_exec` 是同一个 Win32 API）。
// 成功返回 true。
//
// 参数依次是：父窗口、动作、目标、参数串、工作目录、显示方式。
// 动作固定用 "open"，即“用该类型的默认程序打开”；目标可以是文件、目录，
// 也可以是 URL/协议（http:、mailto:）。
//
// 返回值陷阱：ShellExecuteW 声明返回 HINSTANCE，但这个数值实际上是状态码，
// 只有大于 32 才表示成功，32 及以下都是错误码（2 文件不存在、3 路径不存在、
// 5 访问被拒等）。
shell_exec :: proc(work_dir, target, parameters: string) -> bool {
	result := windows.ShellExecuteW(
		nil,                    // 无父窗口
		to_wide("open"),        // 动词：用默认程序打开
		to_wide(target),        // 要打开的文件 / 目录 / URI
		to_wide(parameters),    // 额外参数；空串会变成 nil
		to_wide(work_dir),      // 新进程的工作目录
		SW_NORMAL,              // 普通窗口
	)

	// 把 HINSTANCE 当整数看，判断是否落在成功区间。
	code := int(uintptr(result))
	if code > 32 {
		return true
	}

	// 与 C3 原版一致：把 ShellExecuteW 的原始状态码打到 stderr 并返回失败，
	// 由调用方映射成退出码 1。
	fmt.eprintf("Failed to open file (%d)\r\n", code)
	return false
}
