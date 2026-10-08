#!/bin/bash

set -ex

echo Build bash_prompt
zig build-exe -OReleaseFast -femit-bin=dist/bash_prompt.exe bash_prompt.zig
rm -f dist/bash_prompt.pdb

echo Build open
zig build-exe -OReleaseFast -femit-bin=dist/open.exe open.zig -lshell32 -lshlwapi
rm -f dist/open.pdb

echo Build launch
zig build-exe -OReleaseFast -femit-bin=dist/launch.exe launch.zig -lshell32 -lshlwapi
rm -f dist/launch.pdb
