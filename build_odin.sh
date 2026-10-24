#!/bin/bash

set -ex

mkdir -p dist

# Smallest binary: -o:size optimizes for code size, and the remaining flags drop
# the runtime checks (asserts, bounds checks, type asserts) a release CLI does
# not need. On this target neither -lto (grows the binary) nor -no-crt
# (unavailable on Windows) helps, and -o:size is smaller than -o:speed.
FLAGS=(-o:speed -disable-assert -no-bounds-check -no-type-assert)

echo Build bash_prompt
odin build bash_prompt.odin -file "${FLAGS[@]}" -out:dist/bash_prompt.exe

echo Build open
odin build open.odin -file "${FLAGS[@]}" -out:dist/open.exe

echo Build launch
odin build launch.odin -file "${FLAGS[@]}" -out:dist/launch.exe
