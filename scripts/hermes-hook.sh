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
    repo=$2 pr=$3 pidfile=$4 claim=$5
    # $$ ở đây luôn là PGID: setsid làm tiến trình này thành session leader,
    # dù nó có fork hay exec thẳng. Ghi từ bên trong job nên không đoán mò.
    echo $$ > "$pidfile"
    "$CLI" "$repo" "$pr"
    # Mã 2 = hỏng mà chưa báo được lên PR (thường là `gh` chết). Nhả claim để
    # delivery sau còn chạy lại. Mã 1 = đã có comment ⚠️ trên PR, giữ claim
    # nên redeliver không đẻ comment trùng.
    [ $? -eq 2 ] && rmdir "$claim" 2>/dev/null
    # Chỉ xoá nếu pidfile vẫn là của mình. Job mới có thể đã ghi đè khi push
    # dồn dập — xoá bừa là job kế tiếp mất đường huỷ nó.
    [ "$(cat "$pidfile" 2>/dev/null)" = "$$" ] && rm -f "$pidfile"
    exit 0
fi

# --- chế độ hook: chạy trong request path của Hermes, phải nhanh -------------
STATE="${PR_REVIEW_STATE:-${HERMES_HOME:-$HOME/.hermes}/state/pr-review}"
LOG="$STATE/review.log"

silent() { echo "[SILENT]"; exit 0; }

fields=$(python3 -c '
import json, re, sys
d = json.load(sys.stdin)
if d.get("action") not in ("opened", "synchronize", "reopened"):
    sys.exit(1)
repo = d["repository"]["full_name"]
if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repo):
    sys.exit(1)
sha = d["pull_request"]["head"]["sha"]
if not re.fullmatch(r"[0-9a-fA-F]{7,64}", sha):
    sys.exit(1)
print(repo, int(d["number"]), sha, d["action"])
') || silent
read -r repo pr sha action <<<"$fields"

mkdir -p "$STATE"
find "$STATE" -maxdepth 1 -name '*.claim' -type d -mtime +30 -exec rmdir {} + 2>/dev/null

# Xoay log giữ nguyên inode: job đang chạy vẫn giữ fd `>>` trỏ vào file này,
# `mv` sẽ làm mọi dòng log sau đó của nó biến mất.
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
    tmp=$(mktemp "$STATE/.log.XXXXXX") &&
        tail -c 1048576 "$LOG" > "$tmp" && cat "$tmp" > "$LOG" && rm -f "$tmp"
fi

if [ ! -x "$CLI" ]; then
    echo "[$(date '+%F %T')] HỎNG: không chạy được $CLI" >> "$LOG"
    silent
fi

key="${repo//\//_}#$pr"
claim="$STATE/$key@$sha.claim"
pidfile="$STATE/$key.pid"

# Claim theo từng sha, tạo bằng mkdir nên atomic: hai delivery song song cùng
# một sha thì chỉ một cái vào được. Job hỏng KHÔNG nhả claim — pr_review.py đã
# comment báo hỏng lên PR, nhả ra chỉ đẻ thêm comment trùng. Muốn thử lại thì
# đẩy commit mới (sha mới) hoặc chạy tay.
# `reopened` thường mang đúng sha cũ nên claim đã tồn tại. Không nhả claim
# trước thì action này vĩnh viễn không xử lý được.
[ "$action" = reopened ] && rmdir "$claim" 2>/dev/null
mkdir "$claim" 2>/dev/null || silent

# Push mới cho cùng PR: huỷ job cũ, chỉ review sha mới nhất.
if [ -f "$pidfile" ]; then
    old=$(cat "$pidfile" 2>/dev/null)
    # PID bị OS cấp lại thì pidfile mồ côi trỏ vào process group của người
    # khác. Đối chiếu cmdline trước khi bắn TERM.
    if [ -n "$old" ] && grep -qa "hermes-hook" "/proc/$old/cmdline" 2>/dev/null; then
        kill -TERM -- "-$old" 2>/dev/null
    fi
fi

setsid bash "$SELF" --job "$repo" "$pr" "$pidfile" "$claim" >>"$LOG" 2>&1 </dev/null &

silent
