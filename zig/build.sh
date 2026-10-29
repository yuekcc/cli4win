#!/bin/bash

# 用 zig 编译 Zig 版 bash_prompt、open、launch，产物输出到仓库根目录的 dist/。
# 脚本可在任意目录调用：内部先切到本文件所在目录。

set -ex

cd "$(dirname "$0")"
mkdir -p ../dist

echo Build bash_prompt
zig build-exe -OReleaseFast -femit-bin=../dist/bash_prompt.exe bash_prompt.zig
rm -f ../dist/bash_prompt.pdb

echo Build open
zig build-exe -OReleaseFast -femit-bin=../dist/open.exe open.zig -lshell32 -lshlwapi
rm -f ../dist/open.pdb

echo Build launch
zig build-exe -OReleaseFast -femit-bin=../dist/launch.exe launch.zig -lshell32 -lshlwapi
rm -f ../dist/launch.pdb
