# C3 vs Zig：基于 cli4win 项目的语言复杂度与标准库对比

## 1. 背景与方法

本仓库 `cli4win` 用 **C3** 和 **Zig 0.17.0** 分别实现了同一批 Windows/Linux 命令行工具（`bash_prompt`、`open`、`launch`）。两套实现：

- 功能等价（行为、输出、退出码、错误信息都对齐）；
- 由同一作者、同一时期编写，风格一致；
- 都零 GC、编译为原生可执行文件、直接调用 Win32 API。

因此它是一个非常干净的对照样本：**同一个问题域、同一个人、两种语言**，能较纯粹地反映语言表达力与标准库能力的差异。

本文所有结论都附上仓库中的代码证据。

### 1.1 文件清单与代码量

去掉了注释和空行后的纯代码行数（`code`）与总行数（`total`）：

| 功能 | C3 文件 | C3 code | Zig 文件 | Zig code |
|---|---|---:|---|---:|
| ShellExecute + 路径处理 | `win.c3` | 45 | `win.zig` | 187 |
| 启动器 | `launch.c3` | 47 | `launch.zig` | 87 |
| 打开文件/URI | `open.c3` | 46 | `open.zig` | 46 |
| Shell 提示符 | `bash_prompt.c3` | 241 | `bash_prompt.zig` | 267 |
| 子进程封装 | `cmd.c3` | 52 | Zig 用 `std.process.run` 替代 | — |
| 测试 | `test_cmd.c3` | 7 | — | — |
| **合计** | | **428** | | **587** |

> Zig 版比 C3 版多出约 **37%** 的代码。差值几乎全部集中在 `win.zig`（187 vs 45）——即标准库路径能力缺口，详见第 3 节。

### 1.2 量化指标

对全项目做粗略词频统计（用于佐证，不作为严格结论）：

| 指标 | C3 | Zig |
|---|---:|---:|
| 分配器相关标识符出现次数（`tmem`/`mem` vs `allocator`） | 32 | 88 |
| 显式错误处理关键字（`!`/`!!`/`??` vs `try`） | 30 | 58 |
| 源码 `import` 行数 | 13 | 3 |

C3 的分配器标识符出现次数少，不是因为 C3 分配得少，而是因为 **`tmem`/`mem` 可以省略传递**；Zig 里 `allocator` 必须逐个手工传递。

---

## 2. 语言复杂度与表达力

### 2.1 错误处理

**C3** 采用「可选类型 `T?` + fault」模型，提供多种短路语法糖：

- `!!` — 强制解包，失败即传播/崩溃；
- `??` — 提供默认值；
- `try x = expr` — 捕获 fault 并绑定原因；
- `expr!` — 传播 fault。

```c3
// open.c3
Path? target = path::new(tmem, file_path);
if (catch reason = target)
{
	io::eprintfn("Error, %s. Input = %s", reason, file_path);
	return 1;
}

// bash_prompt.c3
bool ready = repo.try_init(tmem, cwd) ?? false;
Path git_dir = target.append(tmem, ".git")!;   // 传播 fault
```

**Zig** 统一使用 error union `E!T`，靠 `try` / `catch` / `orelse` 处理：

```zig
// launch.zig
const command = (try win.normalizePath(allocator, command_raw)) orelse {
    win.stderrPrint(io, "Error, {s}. Input = {s}\r\n",
        .{ win.invalid_path_message, command_raw });
    return 1;
};
```

**对比**

| 维度 | C3 | Zig |
|---|---|---|
| 概念数量 | fault、Optional、error 三种，语义精细 | 只有 error union 一种 |
| 语法密度 | 高（`!!`/`??`/`catch`），代码短 | 低，需展开成 `try`/`catch`/`orelse` |
| 可预测性 | 稍弱（`!!` 会中断控制流） | 强，错误路径显式 |
| 学习成本 | 需理解多种后缀运算 | 概念单一，易上手 |

**小结**：C3 表达力更丰富、更省字符；Zig 更统一、更可预测，但更啰嗦。

### 2.2 内存管理（差异最大）

**C3** 把分配器与「临时内存池」提升到语言/运行时层面，`mem`（全局分配器）与 `tmem`（临时池）是隐式可用的；`@pool()` 块在作用域结束自动回收临时内存：

```c3
// bash_prompt.c3
@pool()
{
    Path target = cwd;
    for (;;)
    {
        Path git_dir = target.append(tmem, ".git")!;
        // ...
    }
}

DString buf = dstring::new(tmem);          // 绑定临时池
Path exe_name = path::new(mem, arg0)!!;    // 绑定全局分配器
```

**Zig** 0.17 的分配器必须**逐个手工传递**；`std.ArrayList` 是无管理的，每次写入都要传 allocator：

```zig
// bash_prompt.zig
var out: std.ArrayList(u8) = .empty;
try out.appendSlice(allocator, NEW_LINE);
try printCwd(&out, allocator, cwd, home, flag.use_short_name);
```

释放则依赖 `defer`（`arena_state.deinit()`）或 arena 一次性回收：

```zig
// win.zig
var arena_state = std.heap.ArenaAllocator.init(allocator);
defer arena_state.deinit();
const arena = arena_state.allocator();
```

本项目里 Zig 的分配器策略：
- `launch.zig`：`init.arena.allocator()`，进程级 arena，不逐个 free；
- `open.zig`：`init.arena.allocator()`；
- `bash_prompt.zig`：`init.arena.allocator()`；
- `win.zig`：局部 `ArenaAllocator` + `defer` 回收。

**对比**

| 维度 | C3 | Zig |
|---|---|---|
| 分配器传递 | 隐式（`mem`/`tmem`） | 显式，每次调用都传 |
| 临时内存 | `@pool()` 自动回收 | 靠 arena / `defer` 手动组织 |
| 心智负担 | 低 | 高，噪音明显 |
| 所有权清晰度 | 隐式、需理解池生命周期 | 完全显式、可审查 |

**小结**：C3 的隐式分配器 + `@pool` 大幅降低样板量，是 C3 代码更短的关键原因之一；Zig 用显式所有权换取可预测性，代价是代码噪音。

### 2.3 元编程与泛型

**C3** 用 `macro` 做「带类型的模板替换」：

```c3
// bash_prompt.c3
macro String style(String $style, String $str)
{
	return $style +++ $str +++ Ansi.RESET;
}
```

**Zig** 用 `comptime` + 泛型函数 + `inline for`，能力更强（类型反射、零运行时开销），但更难读：

```zig
// bash_prompt.zig：编译期把 '\n' 展开为 '\r\n'，运行时零开销
fn textMode(comptime input: []const u8) []const u8 {
    if (builtin.target.os.tag != .windows) return input;
    comptime {
        var buf: [input.len * 2]u8 = undefined;
        // ... 展开换行 ...
        const frozen: [len]u8 = buf[0..len].*;
        return &frozen;
    }
}

// 用 comptime 表 + @field 做「一行加一个 flag」
const flag_specs = .{
    .{ .name = "--short", .field = "use_short_name" },
    // ...
};
inline for (flag_specs) |spec| {
    if (std.mem.eql(u8, arg, spec.name)) @field(flag, spec.field) = true;
}
```

**小结**：C3 的 macro 好写、贴近文本替换；Zig 的 `comptime` 更强大、更安全（类型级运算、`@field` 反射），但学习曲线更陡。Zig 在 `textMode` 里实现了真正的零运行时开销，是明显优势。

### 2.4 字符串与「方法式」调用

C3 的 `String` 是带方法的值类型，链式调用自然：

```c3
// bash_prompt.c3
content.treplace("ref: refs/heads/", "").trim().copy(allocator)
```

Zig 的字符串是裸切片 `[]const u8`，没有方法，只能调 `std.mem.*` 系列：

```zig
// bash_prompt.zig
var value = std.mem.trim(u8, content, " \t\r\n");
if (std.mem.startsWith(u8, value, prefix)) value = value[prefix.len..];
// win.zig
return std.mem.replaceOwned(u8, allocator, input, needle, replacement);
```

**小结**：C3 更接近脚本语言的可读性；Zig 更接近 C 的显式风格。两者都零 GC，但 C3 的抽象层更高。

### 2.5 结构体方法、模块与 C 互操作

**结构体方法**
- C3 支持扩展方法语法 `fn void Repo.free(&self)`、`fn CommandResult? execute(...)`，模块内 `import cmd;` 即可用。
- Zig 用 `pub fn` + `*Self` 指针，模块通过 `@import("win.zig")` 引入。

**模块/导入数量**

| | C3 | Zig |
|---|---:|---:|
| `import`/`@import` 行 | 13 | 3 |

C3 更依赖现成模块（`std::os::process`、`std::encoding::json`…）；Zig 版高度依赖单个 `std`。

**C 互操作**

两者都要手写 `extern`，但 C3 的类型映射更省事（`@cname` + 现成 `Win32_*` 类型）；Zig 需要 `callconv(.winapi)` 和显式可空标注：

```c3
// win.c3
extern fn Win32_HINSTANCE shell_execute(
	Win32_HWND hwnd,
	Win32_LPCWSTR lpOperation,
	Win32_LPCWSTR lpFile,
	Win32_LPCWSTR lpParameters,
	Win32_LPCWSTR lpDirectory,
	Win32_INT32 nShowCmd,
) @cname("ShellExecuteW");
```

```zig
// win.zig
extern "shell32" fn ShellExecuteW(
    hwnd: ?windows.HWND,
    lpOperation: ?windows.LPCWSTR,
    lpFile: ?windows.LPCWSTR,
    lpParameters: ?windows.LPCWSTR,
    lpDirectory: ?windows.LPCWSTR,
    nShowCmd: windows.INT,
) callconv(.winapi) windows.HINSTANCE;
```

**小结**：两者都未内置 `ShellExecuteW`，都需要手写 extern；C3 的 Win32 类型更开箱即用，Zig 的标注更啰嗦但也更精确。

### 2.6 构建与交叉编译

**C3**：多文件模块自动串联，直接编译：

```sh
c3c compile -D RELEASE -O2 -g0 -o dist/open open.c3 win.c3
c3c compile -D RELEASE -O2 -g0 -o dist/bash_prompt bash_prompt.c3 cmd.c3
```

**Zig**：裸 `zig build-exe`（本项目没有 `build.zig`），依赖文件当源码传入，系统库手动 `-l`：

```sh
zig build-exe -OReleaseFast -femit-bin=dist/open.exe open.zig -lshell32 -lshlwapi
zig build-exe -OReleaseFast -femit-bin=dist/bash_prompt.exe bash_prompt.zig
```

C3 还提供了「编译到目标文件再交给 `zig cc` 链接」的混编路径：

```sh
c3c compile-only bash_prompt.c3 cmd.c3 --target mingw-x64 --single-module=yes -O3
zig cc -o $OUTPUT -O3 -g0 -Wl,--gc-sections -flto -nostdlib++ \
    ./obj/mingw-x64/bash_prompt.obj -ldbghelp -lshlwapi
```

**小结**：两者构建都简单，但 Zig 0.17 的 `std.process.Init`、无管理 `ArrayList`、`std.Io` 等 API 仍在演进，代码里大量 0.17 专属写法，**版本迁移成本更高**；C3 门面更稳定、更「一站式」。

---

## 3. 标准库丰富程度

这一节是最能体现差异的部分，全部有仓库代码佐证。

### 3.1 路径处理 —— 差距最大

**C3** 的 `std::io::path` 提供完整的高层路径 API，`open.c3` / `launch.c3` 直接使用：

```c3
// launch.c3
Path exe_name = path::new(mem, arg0)!!;
Path full_path = exe_name.absolute(mem)!!;
Path install_path = full_path.parent()!!;
Path cwd = path::cwd(mem)!!;
String command = path::normalize(config.get_string("command")!!)!!;
// ...
Path config_path = install_path.tappend(string::tformat("%s.json", exe_name.basename()))!!;
```

**Zig** 的 `std.fs.path` 只有 `join` / `dirname` / `basename`（纯字符串切分），**没有 `normalize`**，`exists` 语义也不一致。于是本项目在 `win.zig` 里手工移植了约 **120 行**：

- `volumeNameLenWin`（Windows 卷前缀 `C:`、`\\?\`、UNC 解析）；
- `normalizePath`（合并冗余分隔符、折叠 `.`/`..`、统一为 `\`、校验保留字符）；
- `pathExists`（用 `PathFileExistsW` 对齐 C3 `path::exists` 对 `nul`/`CON` 的特殊语义）；
- `isSeparator` / `isReservedWin32PathChar` 等辅助。

`win.zig` 文件头注释直接点明：

> `Mirrors win.c3 ... hosts the Windows path normalization ported from the C3 std (std::io::path), which Zig's std does not offer with identical semantics.`

**小结**：**C3 的路径库明显更丰富、更高层**。这是 Zig 代码多 37% 的核心来源。

### 3.2 JSON —— C3 更「高层」

**C3** `std::encoding::json` 直接返回动态对象 `Object*`，用带类型 getter 读取：

```c3
// launch.c3
Object* config = json::parse(mem, context)!!;
String command = path::normalize(config.get_string("command")!!)!!;
bool change_dir = config.get_bool("changeDir")!!;
for (sz i = 0; i < config.get("args").get_len()!!; i++)
{
	String flag = config.get("args").get_string_at(i)!!;
}
```

**Zig** 的 `std.json.Value` 是 tagged union，必须自己 `switch` 解包。`launch.zig` 末尾为此写了三个 helper：

```zig
const root = switch (config) {
    .object => |obj| obj,
    else => { win.stderrPrint(...); return 1; },
};

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) { .string => |s| s, else => null };
}
// 类似地还有 jsonBool / jsonArray
```

**小结**：**C3 提供面向对象的高层 JSON，更省事**；Zig 只给通用值树，便利性靠用户自封。`std.json.parseFromSliceLeaky` 本身很强，但类型化取值没有 C3 顺手。

### 3.3 进程 / 命令执行 —— Zig 反而更好

**C3** 的 `std::os::process` 只给底层 `spawn` / `read_stdout` / `join`，所以项目**额外手写了 `cmd.c3`（52 行）**，还要手工关 stdin 和 win32 句柄：

```c3
// cmd.c3
Process process = process::spawn(
	command_line, STDERR_TO_STDOUT | INHERIT_ENV | NO_WINDOW)!;
defer (void)process.destroy();

// 手工关闭 stdin，避免一直在等待输入
close_stdin(&process);

@pool()
{
	DString result = dstring::new(tmem);
	while (true)
	{
		char[8192] buf;
		sz len = process.read_stdout(&buf, buf.len) ?? -1;
		if (len <= 0) break;
		result.append_bytes(buf[:len]);
	}
	int exit_code = process.join()!;
	return { .code = exit_code, .output = result.copy_str(allocator) };
}
```

**Zig** 的 `std.process.run` 一行捕获完整 stdout：

```zig
// bash_prompt.zig
const result = std.process.run(allocator, io, .{ .argv = argv.items }) catch return "";
return std.mem.trim(u8, result.stdout, " \t\r\n");
```

**小结**：**这一项 Zig 胜出**。说明 Zig std 并非全面落后——在进程、哈希、加密、HTTP、comptime 等底层/通用领域覆盖更广。C3 的 `bash_prompt` 反而要依赖自制的 `cmd.c3`。

### 3.4 动态字符串与格式化

**C3**：`DString` 自带分配器，`append` / `appendf` / `tformat` 一步到位：

```c3
DString flags = dstring::new(mem);
flags.append(flag);
flags.append(" ");
// ...
buf.appendf(style(Ansi.RED, " <%d>"), changed_files);
```

**Zig**：`std.ArrayList(u8)` 无管理（每次传 allocator），或用 `std.fmt.bufPrint` / `allocPrint` 并自行管理缓冲区大小：

```zig
// win.zig：用固定栈缓冲区做 stderr 打印
pub fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    Io.File.stderr().writeStreamingAll(io, text) catch {};
}
```

**小结**：**C3 的动态字符串更「电池内置」**；Zig 更原始但可控（缓冲大小、分配时机都显式）。

### 3.5 Unicode / UTF-16

两者都提供，但组织方式不同：

- C3 挂在 `String` 上：`.to_temp_utf16()`、`.to_wstring()`、`string::from_utf16(...)`；
- Zig 在 `std.unicode`：`utf8ToUtf16LeAllocZ`、`utf8ByteSequenceLength`。

```c3
// win.c3
target.to_temp_utf16()!!
```

```zig
// win.zig
const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch return false;
```

**小结**：丰富度相当，C3 更顺手。

### 3.6 Win32 绑定

- C3 `std::os::win32` 提供 `Win32_*` 类型与 `closeHandle` 等函数；
- Zig `std.os.windows` 提供类型，但整体更偏 POSIX 抽象。

两者的 std 都**没有**内置 `ShellExecuteW`，都需要手写 `extern`（见 2.5）。这一项打平。

### 3.7 环境变量

- C3：`std::os::env` 的 `env::get_home_dir(tmem)` 跨平台封装（Windows 取 `USERPROFILE`，POSIX 取 `HOME`）；
- Zig：手动分支读取 `init.environ_map`：

```c3
// bash_prompt.c3
if (try home_env = env::get_home_dir(tmem)) { home = home_env.replace(tmem, "\\", "/"); }
```

```zig
// bash_prompt.zig
const home_env = if (builtin.target.os.tag == .windows) "USERPROFILE" else "HOME";
const home = if (init.environ_map.get(home_env)) |raw|
    try replaceAll(allocator, raw, "\\", "/")
else null;
```

**小结**：C3 有现成的跨平台封装，Zig 需自己分支。

### 3.8 主要 std 使用对照

**C3**（按模块）

| 模块 | 用途 |
|---|---|
| `std::io` / `std::io::path` / `std::io::file` | 输出、路径、文件读取 |
| `std::os::process` | 子进程 |
| `std::os::win32` | Win32 句柄 |
| `std::os::env` | 环境变量（home） |
| `std::encoding::json` + `std::collections::object` | 配置解析 |
| `libc` | `fclose` 等 |

**Zig**（按符号）

| 符号 | 用途 |
|---|---|
| `std.ArrayList` (10) | 动态字符串 |
| `std.mem.startsWith` (6) / `trim` / `eql` / `splitScalar` / `replaceOwned` / `indexOfScalar` / `count` | 字符串操作（无方法） |
| `std.process.Init` (6) / `currentPathAlloc` / `executablePathAlloc` / `run` | 进程与路径 |
| `std.json.ObjectMap` / `Value` / `parseFromSliceLeaky` / `Array` | 配置解析 |
| `std.fs.path.join` / `dirname` / `basename` | 路径（仅切分） |
| `std.fmt.bufPrint` | 格式化 |
| `std.unicode.*` | UTF-16 |
| `std.heap.ArenaAllocator` | 临时分配 |

---

## 4. 逐文件对照证据

### 4.1 `win.c3`（45 行）→ `win.zig`（187 行）

C3 只做一件事：把 `ShellExecuteW` 包一层。

```c3
fn bool shell_exec(String work_dir, String target, String parameters)
{
	$if !$feat(RELEASE):
		io::printfn("target: %s", target);  // ...
	$endif

	$if !env::WIN32:
		io::eprintfn("Only work in Windows");
		return false;
	$endif

	String operation = "open";
	Win32_HINSTANCE result = shell_execute(
		null, operation.to_temp_utf16()!!, target.to_temp_utf16()!!,
		parameters.to_temp_utf16()!!, work_dir.to_temp_utf16()!!, SW_NORMAL);
	if (@cast_int(result) > 32) return true;
	io::eprintfn("Failed to open file (%d)", @cast_int(result));
	return false;
}
```

Zig 版除了同样的 `shellExec`，还必须自带上「整段 C3 std 路径逻辑」，才达到行为一致。

### 4.2 `open.c3`（46 行）≈ `open.zig`（46 行）

两者代码量相同，但**难度分布不同**：

- C3 直接调 `path::new` / `path::exists`（现成的、语义完整的库）；
- Zig 调 `win.normalizePath` / `win.pathExists`（自研替代品），把复杂度转移到了 `win.zig`。

**这是关键洞察**：Zig 版 `open.zig` 短，不是因为 Zig 更简洁，而是因为路径复杂度被抽到了 `win.zig`。按「项目总和」算，Zig 依然多 37%。

### 4.3 `launch.c3`（47 行）→ `launch.zig`（87 行）

C3 用动态 JSON 对象：

```c3
Object* config = json::parse(mem, context)!!;
String command = path::normalize(config.get_string("command")!!)!!;
bool change_dir = config.get_bool("changeDir")!!;
```

Zig 需要 tagged union 解包 + 三个 helper（`jsonString`/`jsonBool`/`jsonArray`）+ 显式错误分支，代码近乎翻倍。

### 4.4 `bash_prompt.c3`（241 行）→ `bash_prompt.zig`（267 行）

差距相对最小的一个（+11%），因为业务逻辑复杂、语言差异被稀释。但仍有可辨识的模式：

| 环节 | C3 | Zig |
|---|---|---|
| 换行处理 | 依赖 CRT 文本模式，直接写 `"\n"` | `comptime textMode` 手工展开 `\r\n` |
| 命令行解析 | 手写 if-else 链 | `flag_specs` 表 + `inline for` + `@field` |
| 子进程 | 依赖自制 `cmd.c3` | `std.process.run` |
| 路径存在 | `path::exists` | `std.Io.Dir.cwd().access` |
| 路径拼接 | `Path.append` / `tappend` | `std.fs.path.join` |

### 4.5 `cmd.c3`（52 行）→ 无

C3 为了「捕获子进程输出」自写了 `cmd.c3`；Zig 用 `std.process.run` 一行解决。**这是 Zig std 反超的典型例子。**

---

## 5. 总体结论

### 5.1 语言复杂度

| 维度 | C3 | Zig |
|---|---|---|
| 错误处理 | `!!`/`??`/`catch`，表达力强、代码短 | 统一 error union，显式但啰嗦 |
| 内存管理 | 隐式分配器 + `@pool`，心智负担低 | 显式传递 + arena/defer，可预测但噪音大 |
| 元编程 | `macro`，简单直观 | `comptime`，强大但陡峭 |
| 字符串 | 带方法的值类型，链式自然 | 裸切片 + `std.mem.*`，C 风格 |
| 学习曲线 | 平缓 | 陡峭，且 API 演进快 |

**C3 更像「带 GC 手感的系统语言」**：用更丰富的 std 和高层语法换来更短的代码，代价是抽象更隐式。
**Zig 更像「显式的现代 C」**：一切显式、可预测、无隐藏分配，代价是啰嗦、学习曲线陡、版本迭代带来的迁移成本。

### 5.2 标准库丰富程度

- **C3 胜在「高层、一站式」**：
  - `std::io::path`（`normalize`/`exists`/`cwd`/`parent`/`absolute`）—— 本项目里 Zig 需额外约 120 行来补齐；
  - `std::encoding::json` 动态对象 + 类型化 getter；
  - `DString` + 格式化；
  - `env::get_home_dir` 跨平台封装。
- **Zig 胜在「底层、通用、覆盖面广」**：
  - `std.process.run` 直接消灭了 `cmd.c3`；
  - allocator、hash、crypto、http、`comptime` 生态更完整；
  - 但缺少 C3 那种开箱即用的路径/字符串/JSON 便利层。
- **两者打平**：都未绑定 `ShellExecuteW`，C 互操作都得手写 extern。

### 5.3 一句话总结

> 同一个功能，Zig 版在本项目里多写了约 **37%** 的代码——增量几乎全部来自标准库在**路径、JSON、动态字符串**上的便利层缺口，以及内存/错误处理的显式化要求；作为交换，Zig 得到的是完全显式、可预测的所有权与错误流，并在**子进程运行**等底层能力上反超 C3。

### 5.4 选型建议（基于本项目场景）

- 若追求**开发速度、代码短、业务逻辑密集**（如各类 CLI 小工具、脚本启动器），C3 的体验更顺。
- 若追求**显式所有权、长期可维护的可预测性、更广的底层/通用库**（进程、网络、加密），或已深度使用 Zig 生态，Zig 更合适，但需接受更长的样板和更频繁的 API 变更。
- 两者可**混编**：本项目 `build_bash_prompt_mingw64.sh` 就演示了「C3 编译到 obj → `zig cc` 链接」的路径。

---

## 附录 A：复现统计的命令

```sh
# 纯代码行数（去注释、去空行）
for f in win.c3 win.zig ...; do
  grep -vE '^\s*(//|$|/\*|\*)' "$f" | grep -vE '^\s*$' | wc -l
done

# 分配器标识符
grep -oE '\b(tmem|mem)\b' *.c3 | wc -l      # C3
grep -oE '\ballocator\b'    *.zig | wc -l   # Zig

# 错误处理关键字
grep -oE '!!|\?\?|![;,) ]' *.c3 | wc -l     # C3
grep -oE '\btry\b'          *.zig | wc -l   # Zig

# std 使用
grep -ohE 'std::[a-z:]+'   *.c3  | sort | uniq -c | sort -rn
grep -ohE 'std\.[a-zA-Z.]+' *.zig | sort | uniq -c | sort -rn
```

## 附录 B：关键文件索引

| 主题 | C3 | Zig |
|---|---|---|
| ShellExecute 封装 | `win.c3` | `win.zig` |
| 路径规范化（自研） | `std::io::path` | `win.zig` 的 `normalizePath` |
| 打开文件/URI | `open.c3` | `open.zig` |
| 配置启动器 | `launch.c3` | `launch.zig` |
| Shell 提示符 | `bash_prompt.c3` | `bash_prompt.zig` |
| 子进程封装 | `cmd.c3` | `std.process.run` |
| 构建脚本 | `build.sh` | `build_zig.sh` |
| 混编示例 | `build_bash_prompt_mingw64.sh` | — |
