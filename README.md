# 实用工具

**bash_prompt**

Bash shell 提示符，显示路径、git 分支、代码修改量。

**open**

调用 ShellExecuteW 打开文件或执行命令。类似双击打开文件、start 命令。只支持 windows。

**launch**

读取配置，再调用 ShellExecuteW 执行指定的命令。需要配置 <exe_name>.json。exe_name 可以是任意名称。适合作为脚本的启动器。只支持 windows。

## 编译

需要 [c3c](https://github.com/c3lang/c3c) 和 Bash。Bash 通过[git for windows](https://gitforwindows.org/)安装。

安装完上面工具后，在 Bash 中执行 `sh build.sh`。
