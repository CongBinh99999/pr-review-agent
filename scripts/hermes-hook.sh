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
    repo=$2 pr=$3 claim=$4
    "$CLI" "$repo" "$pr"
    # Mã 2 = hỏng mà chưa báo được lên PR (thường là `gh` chết). Nhả claim để
    # delivery sau còn chạy lại. Mã 1 = đã có comment ⚠️ trên PR, giữ claim
    # nên redeliver không đẻ comment trùng.
    [ $? -eq 2 ] && rmdir "$claim" 2>/dev/null
    exit 0
fi

# --- chế độ hook: chạy trong request path của Hermes, phải nhanh -------------
STATE="${PR_REVIEW_STATE:-${HERMES_HOME:-$HOME/.hermes}/state/pr-review}"
LOG="$STATE/review.log"
ALLOW="$STATE/repos.allow"

silent() { echo "[SILENT]"; exit 0; }
note()   { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

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
pr = int(d["number"])
if pr <= 0:
    sys.exit(1)
print(repo, pr, sha)
') || silent
read -r repo pr sha <<<"$fields"

mkdir -p "$STATE" || silent

if [ ! -x "$CLI" ]; then
    # Không `silent`: thoát khác 0 để Hermes ghi vào log gateway, chứ không
    # nuốt lỗi cài đặt rồi im lặng bỏ qua mọi PR.
    note "HỎNG: không chạy được $CLI"
    echo "pr-review: CLI không chạy được: $CLI" >&2
    exit 1
fi

# Allowlist repo, fail-closed. Secret webhook dùng chung và có thể lộ (ps,
# shell history); ai có nó sẽ khiến bot đọc diff và comment lên bất kỳ repo nào
# token của người vận hành với tới được. Không có allowlist thì không chạy.
if ! grep -qxF "$repo" "$ALLOW" 2>/dev/null; then
    note "TỪ CHỐI: $repo không có trong $ALLOW"
    silent
fi

# Claim rò khi job chết bất thường (reboot, OOM, gateway restart) sẽ khoá PR
# đó vĩnh viễn. Job dài nhất ~16 phút nên claim quá 1 giờ chắc chắn là rác.
find "$STATE" -maxdepth 1 -name '*.claim' -type d -mmin +60 -exec rmdir {} + 2>/dev/null

key="${repo//\//_}#$pr"
claim="$STATE/$key@$sha.claim"

# Claim theo từng sha, tạo bằng mkdir nên atomic: hai delivery song song cùng
# một sha thì chỉ một cái vào được. `reopened` mang đúng sha cũ nên sẽ bị chặn
# ở đây — đúng ý: review của sha đó vẫn còn nguyên trên PR, không cần làm lại.
mkdir "$claim" 2>/dev/null || silent

# Job tự hỏi GitHub xem sha của mình còn là HEAD không trước khi đăng comment.
PR_REVIEW_SHA="$sha" setsid bash "$SELF" --job "$repo" "$pr" "$claim" \
    >>"$LOG" 2>&1 </dev/null &

silent
