#!/usr/bin/env bash
# Hook cho `hermes webhook --script`. Hermes đã verify HMAC và lọc event trước
# khi gọi tới đây; payload GitHub thô nằm ở stdin.
#
# Việc của script này: lọc action, chống trùng, tách một tiến trình nền rồi
# thoát NGAY. Hermes chạy script đồng bộ với timeout 30s và capture_output —
# nếu tiến trình con còn giữ stdout thì Hermes sẽ treo tới hết timeout.
# Vì vậy phải setsid + redirect cả 3 fd.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLI="${PR_REVIEW_CLI:-$SELF_DIR/../pr_review.py}"
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
if [ -f "$pidfile" ]; then
    kill -TERM -- "-$(cat "$pidfile")" 2>/dev/null
fi

setsid bash -c "echo \$\$ > '$pidfile'; exec '$CLI' '$repo' '$pr'" \
    >>"$LOG" 2>&1 </dev/null &

silent
