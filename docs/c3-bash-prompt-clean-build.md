# C3 版 bash_prompt：DLL 依赖分析与干净构建

本文回答一个问题：为什么 C3 版 `bash_prompt` 会依赖一堆 DLL，而 Zig 版几乎不依赖，以及
在**基本不改写实现**（只换掉一处文件存在性检查）的前提下能把依赖压到多低。

所有数据都是在本机实测的（c3c 0.8.4，MinGW-w64 / zig cc，Windows）。

## 1. 结论速览

- C3 版 `bash_prompt` 的 DLL 依赖**可以**从「MSVC 调试构建的 4 个（含 `ucrtbased.dll`、
  `VCRUNTIME140D.dll`）」压到「2 个系统 DLL + 8 个 UCRT API set 桩」，其中 `SHLWAPI` 通过
  改写代码（见第 5 节）彻底消除。
- 但压不到 Zig 那种「只有 `ntdll` + `KERNEL32`」——原因是 **C3 的 std 建立在 libc 之上**，
  且**编译期无法去掉 panic/backtrace 机制**，后者强制链接 `dbghelp.dll`。
- 想达到 Zig 水平，唯一的路是 `--link-libc=no` + 不用 std、直接调 Win32 的重写（工程量很大，
  本文不做）。因此本文给出「当前实现的干净构建」。

修好的脚本：`build_bash_prompt_mingw64.sh`（见第 5 节）。

## 2. 依赖对照表（实测）

| 构建方式 | 产物大小 | DLL 依赖 |
|---|---:|---|
| `c3c` 默认链接（`compile` + `-O2 -g0`，lld-link） | 113 KB | `dbghelp`、`KERNEL32`、`SHLWAPI`、`VCRUNTIME140.dll` + 9 个 `api-ms-win-crt-*` |
| `c3c` 调试构建（`-O4`/`-O5` + `-g`，emit debug info） | 92 KB | `dbghelp`、`KERNEL32`、**`ucrtbased.dll`、`VCRUNTIME140D.dll`** |
| MinGW obj + `zig cc`（`-g0 -Wl,--gc-sections -flto`，**未 strip**；旧脚本） | 730 KB | `KERNEL32`、`SHLWAPI`、`dbghelp` + 8 个 `api-ms-win-crt-*` |
| **MinGW obj + `zig cc -Oz -s -Wl,--gc-sections`（本方案 + 去掉 SHLWAPI）** | **133 KB** | `KERNEL32`、`dbghelp` + 8 个 `api-ms-win-crt-*` |
| Zig 版 `bash_prompt` | — | `ntdll`、`KERNEL32` |

关键点：

- 「很多 DLL」里真正刺眼的是 **`ucrtbased.dll` + `VCRUNTIME140D.dll`**——这是**调试 CRT**，
  只在装了 Visual Studio 的机器上有。它出现的原因是构建时带了调试信息（c3c 默认如此）。
  去掉调试信息、用 MinGW 静态方式链接即可消除。
- 剩下的是 **UCRT 的 API set 桩**（`api-ms-win-crt-*`）。它们不是独立组件，而是 Windows 10+
  自带的 `ucrtbase.dll` 的转发器，属于系统组件，**不需要随程序分发**。

## 3. 每条依赖的来源

| DLL | 来自 |
|---|---|
| `KERNEL32.dll` | C3 运行时 / 进程启动 |
| ~~`SHLWAPI.dll`~~ | **已消除**：`std::io::path` 的 `path::exists` → `PathFileExistsW`。改为直接调 `GetFileAttributesExW`，见第 5 节 |
| `dbghelp.dll` | `std::core::builtin_panic` → `std::os::win32::symbolize_backtrace`（`SymInitialize` 等），仅用于 panic 时打印回溯 |
| `api-ms-win-crt-*` | C3 std 调用 libc（`fprintf`/`malloc`/…），由 UCRT 提供 |

## 4. 为什么到不了 Zig 的水平（实测边界）

即使把程序缩到只剩 `fn int main() { return 3; }`：

```sh
c3c compile q.c3 -Oz -o q.exe          # 59 KB
objdump -p q.exe | grep "DLL Name"     # dbghelp + VCRUNTIME140 + api-ms-win-crt-*
```

- **libc 无法回避**：任何用到 `std::io`（打印、文件、进程）的程序都会链接 UCRT。
- **`dbghelp` 无法通过编译选项去除**：`builtin_panic` 里的 `print_backtrace` 会调用
  `symbolize_backtrace`，只要存在 panic 处理就保留该引用。`--show-backtrace=no`、
  `--panic-msg=no`、`-O5`/`-Oz`、`--gc-sections` 都**不能**去掉它（因为 `main` 必然引用
  panic 入口，链路恒可达）。`-municode` 也不是解药（见第 5 节）。

要真正去掉 libc / dbghelp，只能：

1. 用 `--link-libc=no --custom-libc=yes -D NO_LIBC` + 自己写入口，绕过 std 的 I/O 与 panic，
   或用原始 Win32 调用替换（Zig 走的就是这条路：直接 `ntdll`/`KERNEL32`）。

这件事超出「清理现有实现」的范围，属于重写。（`SHLWAPI` 属另一类——它是我们自己代码引入的，
已在第 5 节用 `GetFileAttributesExW` 消除。）

## 5. 修好的构建脚本与改动

`build_bash_prompt_mingw64.sh` 现在做三件事：c3c 编译成 obj → `zig cc` 链接 → strip，
并**验证依赖白名单**和**跑一次冒烟测试**。

相比旧脚本的改动：

1. **消除 `SHLWAPI`（改代码）**。`path::exists` 在 Windows 上最终调用 shlwapi 的
   `PathFileExistsW`。`bash_prompt.c3` 里只在一处用到它（定位 `.git`），改为直接调
   KERNEL32 的 `GetFileAttributesExW`：

   ```c3
   fn bool path_exists(String path)
   {
       @pool()
       {
           Win32_FILE_ATTRIBUTE_DATA data;
           return (bool)win32::getFileAttributesExW(
               path.to_temp_utf16()!!,
               Win32_GET_FILEEX_INFO_LEVELS.STANDARD,
               &data);
       };
   }
   ```

   `GetFileAttributesExW` 同样能解析 `NUL`/`CON` 等设备名，语义与原来一致。链接时因此不再需要
   `-lshlwapi`。
2. **启用 strip**（`-s`）。旧脚本把 `strip -s` 注释掉了，符号和调试信息全留着；去掉后
   体积从 730 KB 降到约 130 KB。
3. **`-O3` → `-Oz`**。bash_prompt 每次提示符都会执行，体积更敏感；`-Oz` 实测启动开销与
   `-O3` 无差异，体积更小。
4. **去掉 `-flto -nostdlib++`**：对本产物无增益（`--gc-sections` 才是关键），去掉更清晰。
5. **加验证**：构建后检查依赖白名单、跑一次 `--init` 冒烟测试，回归立刻暴露。

⚠️ 一个容易踩的坑：**不要给这个二进制加 `-municode`**。c3c 生成的入口是普通 `main`，程序
自带 C3 启动代码；加了 `-municode` 会让 MinGW CRT 去找 `wmain`，链接能过但一运行就陷阱崩溃：

```
ERROR: 'Unhandled exception (80000003) at 0x...'
  in wmain (source unavailable) ...
```

（某些较早的 c3c 版本生成的是 `wmain` 入口，那时的脚本/文档确实要 `-municode`；当前 0.8.4
不需要，加了反而坏。）

可选调整（性能 vs 体积）：

| 参数 | 大小 | 说明 |
|---|---:|---|
| `-O3` | 143 KB | 吞吐优先 |
| `-Oz`（脚本默认） | 130 KB | 体积优先，启动开销与 `-O3` 实测无差异 |

## 6. 复现

```sh
# 干净构建（约 133 KB，2 + 8 条系统依赖，跑得起来）
sh c3/build_bash_prompt_mingw64.sh

# 看依赖
objdump -p dist/bash_prompt.exe | grep "DLL Name"

# 对照：MSVC/调试构建会多出调试 CRT
c3c compile -O2 -g0 -o /tmp/raw c3/bash_prompt.c3 c3/cmd.c3
objdump -p /tmp/raw | grep "DLL Name"   # 含 ucrtbased/VCRUNTIME140D
```
