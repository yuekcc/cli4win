#!/bin/bash

set -ex

sources=(
    "open.c3"
)

for src_file in ${sources[@]};
do
    tool_name="${src_file%.*}"
    c3c compile -Oz -g0 -o dist/$tool_name $src_file win.c3
done

