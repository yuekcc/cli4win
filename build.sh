#!/bin/bash

set -ex

sources=(
    "open.c3"
    "launch.c3"
    "bash_prompt.c3"
    "agent.c3"
)

for src_file in ${sources[@]};
do
    tool_name="${src_file%.*}"
    echo "build tool: ${tool_name}"
    c3c compile -O2 -o dist/$tool_name $src_file win.c3 cmd.c3
done
