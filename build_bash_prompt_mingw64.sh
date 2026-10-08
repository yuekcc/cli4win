#!/bin/bash

set -ex

OUTPUT=dist/bash_prompt.exe

c3c compile-only bash_prompt.c3 cmd.c3 --target mingw-x64 --single-module=yes -O3
zig cc -o $OUTPUT -O3 -g0 -Wl,--gc-sections -flto -nostdlib++ ./obj/mingw-x64/bash_prompt.obj -ldbghelp -lshlwapi
# strip -s $OUTPUT
ls -ahl dist
