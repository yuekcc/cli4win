# 实用工具

**bash_prompt**

Bash shell 提示符，显示路径、git 分支、代码修改量。支持 windows 和 linux。有 c3、zig 和 odin 三个实现。
三个实现默认都不统计修改量（省掉每条提示符一次 `git status`），加 `--git` 才统计。

**open**

调用 ShellExecuteW 打开文件或执行命令。类似双击打开文件、start 命令。只支持 windows。有 c3、zig 和 odin 三个实现。

**launch**

读取配置，再调用 ShellExecuteW 执行指定的命令。需要配置 <exe_name>.json。exe_name 可以是任意名称。适合作为脚本的启动器。只支持 windows。有 c3、zig 和 odin 三个实现。

## 编译

c3 实现需要 [c3c](https://github.com/c3lang/c3c) 和 Bash。Bash 通过[git for windows](https://gitforwindows.org/)安装。

zig 实现需要 [zig](https://ziglang.org/) 0.17.0。

odin 实现需要 [odin](https://odin-lang.org/)。

安装完上面工具后，在 Bash 中执行：

- `sh build.sh`：用 c3c 编译 bash_prompt、open、launch。
- `sh build_zig.sh`：用 zig 编译 bash_prompt、open、launch。
- `sh build_odin.sh`：用 odin 编译 bash_prompt、open、launch。
- `sh build_bash_prompt_mingw64.sh`：用 MinGW 目标 + zig cc 构建一个依赖最少的 `bash_prompt`（需 c3c、zig、objdump），并自带依赖校验与冒烟测试。分析见 `docs/c3-bash-prompt-clean-build.md`。
