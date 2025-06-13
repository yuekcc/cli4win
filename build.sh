#!/bin/bash

set -ex

sources=(
    "wopen.c3"
)

for src_file in ${sources[@]};
do
    tool_name="${src_file%.*}"
    c3c compile -O3 -g0 -o dist/$tool_name $src_file win.c3
done

