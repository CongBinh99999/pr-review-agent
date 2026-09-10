#!/usr/bin/env bash
# Hook cho `hermes webhook --script`. Hermes đã verify HMAC và lọc event trước
# khi gọi tới đây; payload GitHub thô nằm ở stdin.
#
# Việc của script này: lọc action, chống trùng, tách một tiến trình nền rồi
# thoát NGAY. Hermes chạy script đồng bộ với timeout 30s và capture_output —
# nếu tiến trình con còn giữ stdout thì Hermes sẽ treo tới hết timeout.
# Vì vậy phải setsid + redirect cả 3 fd.
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SELF_DIR=$(cd "$(dirname "$SELF")" && pwd)
CLI="${PR_REVIEW_CLI:-$SELF_DIR/../pr_review.py}"

# --- chế độ job: chạy trong tiến trình nền đã tách khỏi Hermes ---------------
if [ "${1:-}" = "--job" ]; then
    repo=$2 pr=$3 claim=$4 pidfile=$5
    # $$ ở đây luôn là PGID: setsid làm tiến trình này thành session leader,
    # dù nó có fork hay exec thẳng. Ghi từ bên trong job nên không đoán mò.
    echo $$ > "$pidfile"
    # Job hỏng (gh lỗi, claude timeout, bị kill) thì nhả claim để lần redeliver
    # sau của GitHub còn được xử lý lại.
    "$CLI" "$repo" "$pr" || rmdir "$claim" 2>/dev/null
    rm -f "$pidfile"
    exit 0
fi

# --- chế độ hook: chạy trong request path của Hermes, phải nhanh -------------
STATE="${PR_REVIEW_STATE:-${HERMES_HOME:-$HOME/.hermes}/state/pr-review}"
LOG="$STATE/review.log"

silent() { echo "[SILENT]"; exit 0; }

fields=$(python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("action") not in ("opened", "synchronize", "reopened"):
    sys.exit(1)
print(d["repository"]["full_name"], d["number"], d["pull_request"]["head"]["sha"])
') || silent
read -r repo pr sha <<<"$fields"
[ -n "${sha:-}" ] || silent
case $sha in *[!0-9a-fA-F]* | "") silent ;; esac

mkdir -p "$STATE"
find "$STATE" -maxdepth 1 -name '*.claim' -type d -mtime +30 -exec rmdir {} + 2>/dev/null
# ponytail: cắt log khi quá 5MB thay vì logrotate. Mất phần cũ, đủ cho debug.
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
    tail -c 1048576 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

key="${repo//\//_}#$pr"
claim="$STATE/$key@$sha.claim"
pidfile="$STATE/$key.pid"

# Claim theo từng sha, tạo bằng mkdir nên atomic: hai delivery song song cùng
# một sha thì chỉ một cái vào được. Claim gắn với sha nên job của sha cũ không
# thể nhả claim của sha mới.
mkdir "$claim" 2>/dev/null || silent

# Push mới cho cùng PR: huỷ job cũ, chỉ review sha mới nhất.
if [ -f "$pidfile" ]; then
    kill -TERM -- "-$(cat "$pidfile")" 2>/dev/null
fi

setsid bash "$SELF" --job "$repo" "$pr" "$claim" "$pidfile" \
    >>"$LOG" 2>&1 </dev/null &

silent
