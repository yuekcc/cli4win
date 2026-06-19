#!/bin/bash

set -ex

echo Build bash_prompt
c3c compile -D RELEASE -O2 -g0 -o dist/bash_prompt bash_prompt.c3 cmd.c3

echo Build open
c3c compile -D RELEASE -O2 -g0 -o dist/open open.c3 win.c3

echo Build launch
c3c compile -D RELEASE -O2 -g0 -o dist/launch launch.c3 win.c3