#!/bin/bash

# 用 odin 编译 Odin 版 bash_prompt、open、launch，产物输出到仓库根目录的 dist/。
# 脚本可在任意目录调用：内部先切到本文件所在目录。

set -ex

cd "$(dirname "$0")"
mkdir -p ../dist

# Smallest binary: -o:size optimizes for code size, and the remaining flags drop
# the runtime checks (asserts, bounds checks, type asserts) a release CLI does
# not need. On this target neither -lto (grows the binary) nor -no-crt
# (unavailable on Windows) helps, and -o:size is smaller than -o:speed.
FLAGS=(-o:speed -disable-assert -no-bounds-check -no-type-assert)

echo Build bash_prompt
odin build bash_prompt.odin -file "${FLAGS[@]}" -out:../dist/bash_prompt.exe

echo Build open
odin build open.odin -file "${FLAGS[@]}" -out:../dist/open.exe

echo Build launch
odin build launch.odin -file "${FLAGS[@]}" -out:../dist/launch.exe
