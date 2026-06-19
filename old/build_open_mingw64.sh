#!/bin/bash

set -ex

OUTPUT=open.exe

c3c compile-only open.c3 win.c3 --target mingw-x64 --single-module=yes -O2 -D RELEASE
zig cc -o $OUTPUT ./obj/mingw-x64/open.obj -ldbghelp -lshlwapi
strip -s ${OUTPUT}
