#!/bin/bash

# 用 c3c 编译 C3 版 bash_prompt、open、launch，产物输出到仓库根目录的 dist/。
# 脚本可在任意目录调用：内部先切到本文件所在目录。

set -ex

cd "$(dirname "$0")"
mkdir -p ../dist

echo Build bash_prompt
c3c compile -D RELEASE -O2 -g0 -o ../dist/bash_prompt bash_prompt.c3 cmd.c3

echo Build open
c3c compile -D RELEASE -O2 -g0 -o ../dist/open open.c3 win.c3

echo Build launch
c3c compile -D RELEASE -O2 -g0 -o ../dist/launch launch.c3 win.c3
