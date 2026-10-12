#!/bin/bash
#
# Clean MinGW build for bash_prompt.
#
# Why this exists instead of a plain `c3c compile`: c3c's own linker pulls in a
# lot of runtime DLLs (and, in debug mode, the debug CRT). This script builds a
# minimal binary by splitting compile and link:
#
#   1. c3c compiles to a single object file (compile-only).
#   2. zig cc links that object, dropping unused sections.
#   3. strip removes symbols.
#
# Resulting imports are verified below. See docs/c3-bash-prompt-clean-build.md.
#
# Requires: c3c, Zig (zig cc), and a POSIX shell (Git for Windows).

set -e

OUTPUT=dist/bash_prompt.exe
OBJ=./obj/mingw-x64/bash_prompt.obj

# -Oz: optimize for size (bash_prompt runs on every prompt, so start-up and
#      file size matter more than raw throughput). -g0 keeps debug info out.
echo "== Compile (c3c -> object) =="
c3c compile-only bash_prompt.c3 cmd.c3 \
	--target mingw-x64 --single-module=yes -Oz -g0

# NOTE: do NOT add -municode here. c3c emits a plain `main` entry and provides
# its own C3 start-up; -municode makes the MinGW CRT call `wmain`, which does
# not exist in this object and traps at start-up (exception 0x80000003).
#
# Only -ldbghelp is needed: bash_prompt's own path existence check uses
# GetFileAttributesExW (KERNEL32) instead of shlwapi's PathFileExistsW, so
# SHLWAPI.dll is not linked.
echo "== Link (zig cc) =="
zig cc -o "$OUTPUT" -Oz -s -Wl,--gc-sections "$OBJ" -ldbghelp

echo "== Verify =="
ls -alh "$OUTPUT"

# Every import must be a Windows component that is present on a clean install.
# Anything else means the build regressed.
allowed='KERNEL32.dll|dbghelp.dll|api-ms-win-crt-[a-z0-9-]+-l1-1-0.dll'
deps=$(objdump -p "$OUTPUT" | awk '/DLL Name/ {print $3}')
echo "-- imports --"
echo "$deps"
if echo "$deps" | grep -viE "^(${allowed})$" >/dev/null; then
	echo "ERROR: unexpected import(s):"
	echo "$deps" | grep -viE "^(${allowed})$"
	exit 1
fi

# Smoke test: the binary must actually run (an accidental -municode or a bad
# start-up path shows up here as a crash).
"$OUTPUT" --init >/dev/null
echo "== OK: $OUTPUT =="
