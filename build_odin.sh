#!/bin/bash

set -ex

# Smallest binary: -o:size optimizes for code size, and the remaining flags drop
# the runtime checks (asserts, bounds checks, type asserts) a release CLI does
# not need. On this target neither -lto (grows the binary) nor -no-crt
# (unavailable on Windows) helps, and -o:size is smaller than -o:speed.
FLAGS=(-o:speed -disable-assert -no-bounds-check -no-type-assert)

echo Build bash_prompt
odin build bash_prompt.odin -file "${FLAGS[@]}" -out:dist/bash_prompt.exe
