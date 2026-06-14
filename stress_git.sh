#!/usr/bin/env bash
# stress_git.sh — 创建一个 git 仓库并制造大量变更
# 用于测试 git status / diff 在高负载下的表现
#
# 用法:
#   ./stress_git.sh [文件数] [目录深度]
#   ./stress_git.sh            # 默认: 2000 个文件, 3 层目录
#   ./stress_git.sh 10000 5    # 10000 个文件, 5 层目录

set -euo pipefail

NUM_FILES="${1:-2000}"
MAX_DEPTH="${2:-3}"
REPO_DIR="stress_test_repo_$(date +%s)"

echo "=== Git Stress Test ==="
echo "Target: $NUM_FILES files, depth $MAX_DEPTH"
echo "Repo:   $REPO_DIR"
echo ""

# --- 创建仓库 ---
rm -rf "$REPO_DIR"
mkdir "$REPO_DIR"
cd "$REPO_DIR"

git init --quiet
git config user.email "stress@test.local"
git config user.name "Stress Tester"

echo "[1/6] Initial empty commit..."
git commit --allow-empty --quiet -m "initial"

# --- 准备目录结构 ---
echo "[2/6] Creating directory tree (depth=$MAX_DEPTH)..."

create_dirs() {
    local current_depth="$1"
    local prefix="$2"

    if [ "$current_depth" -ge "$MAX_DEPTH" ]; then
        return
    fi

    local subdirs_per_level=3
    for s in $(seq 1 $subdirs_per_level); do
        local dir="${prefix}/d${s}"
        mkdir -p "$dir"
        create_dirs $((current_depth + 1)) "$dir"
    done
}

create_dirs 0 "."

# 统计实际创建的目录数
DIR_COUNT=$(find . -mindepth 1 -type d | wc -l)
echo "      Created $DIR_COUNT directories"

# --- 生成初始 tracked 文件 ---
echo "[3/6] Generating $NUM_FILES tracked files..."

FILES_PER_DIR=$((NUM_FILES / (DIR_COUNT + 1)))
[ "$FILES_PER_DIR" -lt 1 ] && FILES_PER_DIR=1

FILE_COUNT=0
for dir in $(find . -mindepth 1 -type d); do
    for i in $(seq 1 $FILES_PER_DIR); do
        FILE_COUNT=$((FILE_COUNT + 1))
        if [ "$FILE_COUNT" -gt "$NUM_FILES" ]; then
            break 2
        fi

        FILE_PATH="${dir}/tracked_${FILE_COUNT}.txt"
        # 写入一些内容，让文件不是空的
        printf "tracked file %d\ncreated at %s\nhello world %d\n" \
            "$FILE_COUNT" "$(date)" "$RANDOM" > "$FILE_PATH"
    done
done

# 如果循环不够，在根目录补齐
while [ "$FILE_COUNT" -lt "$NUM_FILES" ]; do
    FILE_COUNT=$((FILE_COUNT + 1))
    printf "tracked file %d\ncreated at %s\nhello world %d\n" \
        "$FILE_COUNT" "$(date)" "$RANDOM" > "./tracked_${FILE_COUNT}.txt"
done

echo "      Created $FILE_COUNT files"

# --- 提交初始文件 ---
echo "[4/6] Committing initial files..."
git add -A
git commit --quiet -m "add $FILE_COUNT files"

# --- 制造 staged 变更 ---
echo "[5/6] Creating staged changes..."
STAGED_COUNT=$((NUM_FILES / 10))
[ "$STAGED_COUNT" -lt 1 ] && STAGED_COUNT=1

STAGED=0
git diff --name-only | head -n "$STAGED_COUNT" | while IFS= read -r f; do
    STAGED=$((STAGED + 1))
    printf "\nstaged modification at %s\nline %d\n" "$(date)" "$RANDOM" >> "$f"
    git add --quiet "$f"
done
echo "      Staged ~$STAGED_COUNT files for modification"

# --- 制造 unstaged 变更 ---
echo "[6/6] Creating unstaged + untracked changes..."

# unstaged: 修改已 tracked 但未 stage 的文件
UNSTAGED_COUNT=$((NUM_FILES / 5))
[ "$UNSTAGED_COUNT" -lt 1 ] && UNSTAGED_COUNT=1

git diff --cached --name-only | tail -n +"$STAGED_COUNT" 2>/dev/null \
    | head -n "$UNSTAGED_COUNT" \
    | while IFS= read -r f; do
    printf "\nunstaged modification at %s\nline %d\n" "$(date)" "$RANDOM" >> "$f"
done

# untracked: 创建全新的未跟踪文件
UNTRACKED_COUNT=$((NUM_FILES / 4))
[ "$UNTRACKED_COUNT" -lt 1 ] && UNTRACKED_COUNT=1

for i in $(seq 1 $UNTRACKED_COUNT); do
    DIR=$(find . -mindepth 1 -type d | shuf -n 1)
    printf "untracked file %d\ncreated at %s\nrandom: %d\n" \
        "$i" "$(date)" "$RANDOM" > "${DIR}/untracked_${i}.txt"
done
echo "      Created $UNTRACKED_COUNT untracked files"

# --- 汇总 ---
echo ""
echo "=== Done ==="
echo "Repo path: $(pwd)"
echo ""
echo "Quick stats:"
echo "  Tracked files:  $(git ls-files | wc -l)"
echo "  Staged:        $(git diff --cached --name-only | wc -l)"
echo "  Modified:      $(git diff --name-only | wc -l)"
echo "  Untracked:     $(git ls-files --others --exclude-standard | wc -l)"
echo ""
echo "Now you can test:"
echo "  time git status --porcelain"
echo "  time git diff --numstat HEAD"
echo "  time git status"
