# 实用工具

**bash_prompt**

Bash shell 提示符，显示路径、git 分支、代码修改量。支持 windows 和 linux。有 c3、zig 和 odin 三个实现。
三个实现默认都不统计修改量（省掉每条提示符一次 `git status`），加 `--git` 才统计。

**open**

调用 ShellExecuteW 打开文件或执行命令。类似双击打开文件、start 命令。只支持 windows。有 c3、zig 和 odin 三个实现。

**launch**

读取配置，再调用 ShellExecuteW 执行指定的命令。需要配置 <exe_name>.json。exe_name 可以是任意名称。适合作为脚本的启动器。只支持 windows。有 c3、zig 和 odin 三个实现。

## 目录结构

按编程语言归档，每个语言目录存放该语言的实现和对应的编译脚本：

```
c3/     C3 实现：bash_prompt.c3、open.c3、launch.c3、win.c3、cmd.c3
zig/    Zig 实现：bash_prompt.zig、open.zig、launch.zig、win.zig
odin/   Odin 实现：bash_prompt.odin、open.odin、launch.odin、win/win.odin
docs/   设计说明与语言对比
dist/   编译产物（已在 .gitignore 中忽略）
```

三个实现功能等价，可分别编译对比；源文件开头的注释写着该文件的作用与编译命令。

## 编译

c3 实现需要 [c3c](https://github.com/c3lang/c3c) 和 Bash。Bash 通过[git for windows](https://gitforwindows.org/)安装。

zig 实现需要 [zig](https://ziglang.org/) 0.17.0。

odin 实现需要 [odin](https://odin-lang.org/)。

安装完上面工具后，在仓库根目录用 Bash 执行：

- `sh c3/build.sh`：用 c3c 编译 bash_prompt、open、launch。
- `sh zig/build.sh`：用 zig 编译 bash_prompt、open、launch。
- `sh odin/build.sh`：用 odin 编译 bash_prompt、open、launch。

脚本内部会切到自己所在的目录，因此也可以在任意目录调用（如 `sh c3/build.sh` 或 `cd c3 && sh build.sh`）。
产物统一输出到仓库根目录的 `dist/`。

其他脚本：

- `sh c3/build_bash_prompt_mingw64.sh`：用 MinGW 目标 + zig cc 构建一个依赖最少的 `bash_prompt`（需 c3c、zig、objdump），并自带依赖校验与冒烟测试。分析见 `docs/c3-bash-prompt-clean-build.md`。
- `sh bench.sh [迭代次数]`：编译四个 bash_prompt 版本并测启动耗时，对应 `docs/c3-odin-zig-perf.html`。
- `c3c compile-test c3/test_cmd.c3 c3/cmd.c3`：运行 C3 版的单元测试。
