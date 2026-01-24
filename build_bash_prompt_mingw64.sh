#!/bin/bash

set -ex

c3c compile-only bash_prompt.c3 cmd.c3 --target mingw-x64 --single-module=yes -O2
gcc -o bash_prompt_mingw ./obj/mingw-x64/bash_prompt.obj -ldbghelp -lshlwapi