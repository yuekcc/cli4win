#!/bin/bash

set -ex

OUTPUT=bash_prompt

c3c compile-only bash_prompt.c3 cmd.c3 --target mingw-x64 --single-module=yes -O2
gcc -o $OUTPUT ./obj/mingw-x64/bash_prompt.obj -ldbghelp -lshlwapi
strip -s ${OUTPUT}.exe