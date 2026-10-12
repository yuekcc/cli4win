#!/usr/bin/env bash
#
# Reproduce the startup benchmark behind docs/c3-odin-zig-perf.html.
#
# Builds the four bash_prompt ports, then times process startup with the native
# harness (CreateProcessW + QueryPerformanceCounter, flags=0, std* -> NUL).
#
# The harness (benchf.c / benchf.exe) lives next to this file; build it with:
#     zig cc -o benchf.exe benchf.c
#
# Usage: sh bench.sh [iterations]
set -e

ITERS=${1:-500}
DIST=dist
HARNESS=$(dirname "$0")/benchf.exe

# git cwd is any working tree; no-git cwd must not be inside one.
NOGIT=${NOGIT:-$(mktemp -d 2>/dev/null || echo /tmp/bpbench-nogit)}
GIT=${GIT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}
mkdir -p "$NOGIT"

echo "== Build =="
c3c compile -D RELEASE -O2 -g0 -o "$DIST/bp_c3.exe" bash_prompt.c3 cmd.c3
c3c compile-only bash_prompt.c3 cmd.c3 --target mingw-x64 --single-module=yes -O3
zig cc -o "$DIST/bp_c3_mingw.exe" -O3 -g0 -Wl,--gc-sections \
	./obj/mingw-x64/bash_prompt.obj -ldbghelp
odin build bash_prompt.odin -file -o:size -disable-assert -no-bounds-check -no-type-assert -out:"$DIST/bp_odin.exe"
zig build-exe -OReleaseFast -femit-bin="$DIST/bp_zig.exe" bash_prompt.zig

echo "== Run ($ITERS iters each) =="
# Windows paths for the harness.
win() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
W_NOGIT=$(win "$NOGIT"); W_GIT=$(win "$GIT")
for exe in bp_c3 bp_c3_mingw bp_odin bp_zig; do
	W_EXE=$(win "$PWD/$DIST/$exe.exe")
	printf '%-14s --help ' "$exe"; "$HARNESS" "$ITERS" "$W_NOGIT" "$W_EXE" --help
	printf '%-14s non-git ' "$exe"; "$HARNESS" "$ITERS" "$W_NOGIT" "$W_EXE"
	printf '%-14s git     ' "$exe"; "$HARNESS" "$ITERS" "$W_GIT" "$W_EXE"
	printf '%-14s --short ' "$exe"; "$HARNESS" "$ITERS" "$W_NOGIT" "$W_EXE" --short
done

echo "== Imports =="
for exe in bp_c3 bp_c3_mingw bp_odin bp_zig; do
	printf '%-14s ' "$exe"
	objdump -p "$DIST/$exe.exe" | grep -i "DLL Name" | awk '{printf "%s ", $3}'; echo
done
