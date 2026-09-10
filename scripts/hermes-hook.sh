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
    # Job fail (gh lỗi, claude timeout, bị kill) thì xoá marker để lần
    # redeliver sau của GitHub còn được xử lý lại.
    "$CLI" "$2" "$3" || rm -f "$4"
    rm -f "$5"
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

mkdir -p "$STATE"
key="${repo//\//_}#$pr"
marker="$STATE/$key.sha"
pidfile="$STATE/$key.pid"

# GitHub retry gửi lại đúng payload cũ -> cùng head_sha -> bỏ qua.
[ -f "$marker" ] && [ "$(cat "$marker")" = "$sha" ] && silent
echo "$sha" > "$marker"

# Push mới cho cùng PR: huỷ job cũ, chỉ review sha mới nhất.
# ponytail: pidfile được job xoá khi xong nên hiếm khi ôi; nếu vẫn ôi và PID
# đã bị OS cấp lại thì kill bắn nhầm process group. Cần chắc hơn thì lưu kèm
# /proc/<pid>/stat starttime và đối chiếu trước khi kill.
if [ -f "$pidfile" ]; then
    kill -TERM -- "-$(cat "$pidfile")" 2>/dev/null
fi

setsid bash "$SELF" --job "$repo" "$pr" "$marker" "$pidfile" \
    >>"$LOG" 2>&1 </dev/null &
echo $! > "$pidfile"

silent
