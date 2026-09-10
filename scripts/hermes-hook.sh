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
    # Hook đã trả 200 cho GitHub TRƯỚC khi job chạy, nên GitHub không có lý do
    # gì để redeliver. Muốn có retry thì phải tự làm ở đây.
    for attempt in 1 2 3; do
        # Lần cuối: cho phép job cố đăng comment ⚠️ dù chính `gh` đang trục
        # trặc, còn hơn để PR im lặng không dấu vết nào ngoài review.log.
        [ $attempt -eq 3 ] && export PR_REVIEW_LAST_ATTEMPT=1
        "$CLI" "$repo" "$pr"
        rc=$?
        [ $rc -ne 2 ] && break
        [ $attempt -lt 3 ] && sleep $((attempt * ${PR_REVIEW_RETRY_SLEEP:-30}))
    done
    # 0 = xong, 1 = đã báo hỏng lên PR. Cả hai đều "đã xử lý xong sha này":
    # đổi .claim -> .done để chống trùng vĩnh viễn, GC không đụng tới.
    # 2 = chưa báo được (gh chết) -> nhả claim cho delivery sau chạy lại.

    # -T: không có nó, `.done` đã tồn tại (do race) sẽ khiến mv nhét claim VÀO
    # trong .done, làm .done không rỗng và GC `rmdir` không bao giờ dọn được.
    # Mọi mã khác 0/1 (2, 127, 128+signal của CLI) đều nhả claim ngay để giải
    # phóng chỗ trong trần job song song. Chỉ khi chính wrapper --job bị giết
    # (OOM cả process group, gateway restart) thì .claim mới ở lại và phải chờ
    # GC dọn.
    case $rc in
        0|1) mv -T "$claim" "${claim%.claim}.done" 2>/dev/null || rmdir "$claim" 2>/dev/null ;;
        *)   rmdir "$claim" 2>/dev/null ;;
    esac
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
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*", repo) \
        or ".." in repo or repo.endswith(".git"):
    sys.exit(1)
sha = d["pull_request"]["head"]["sha"]
if not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", sha):
    sys.exit(1)
pr = int(d["number"])
if pr <= 0:
    sys.exit(1)
assoc = d["pull_request"].get("author_association", "NONE")
if not re.fullmatch(r"[A-Z_]+", assoc):
    sys.exit(1)
print(repo, pr, sha, assoc)
') || silent
read -r repo pr sha assoc <<<"$fields"

mkdir -p "$STATE" || silent

# Allowlist repo, fail-closed. Secret webhook dùng chung và có thể lộ (ps,
# shell history); ai có nó sẽ khiến bot đọc diff và comment lên bất kỳ repo nào
# token của người vận hành với tới được. Không có allowlist thì không chạy.
if ! grep -qxF "$repo" "$ALLOW" 2>/dev/null; then
    note "TỪ CHỐI: $repo không có trong $ALLOW"
    silent
fi

# Job xấu nhất: 3 lần thử × (60s diff + 900s claude + 30s stale + 60s comment)
# + 90s nghỉ ≈ 54 phút. Ngưỡng 90 phút: đủ biên để không giật claim của job
# đang sống, mà claim kẹt cũng không khoá trần job song song quá lâu.
find "$STATE" -maxdepth 1 -name '*.claim' -type d -mmin +90 -exec rmdir {} + 2>/dev/null
# .done giữ rất lâu để chống trùng, nhưng không vĩnh viễn: mỗi sha một thư mục.
find "$STATE" -maxdepth 1 -name '*.done' -type d -mtime +90 -exec rmdir {} + 2>/dev/null

if [ ! -x "$CLI" ]; then
    # Thoát khác 0 (không `silent`) để Hermes ghi vào log gateway thay vì nuốt
    # lỗi cài đặt. Đã kiểm source: returncode != 0 đi đúng nhánh "ignored" như
    # [SILENT], agent LLM không bị kích hoạt.
    note "HỎNG: không chạy được $CLI"
    echo "pr-review: CLI không chạy được: $CLI" >&2
    exit 1
fi

# `:` không hợp lệ trong tên repo GitHub nên không thể đụng nhau.
key="${repo/\//:}#$pr"
claim="$STATE/$key@$sha.claim"

# Sha đã xử lý xong rồi thì thôi, vĩnh viễn. `reopened` và nút Redeliver của
# GitHub đều mang đúng sha cũ nên dừng ở đây — review của sha đó vẫn còn
# nguyên trên PR.
[ -d "${claim%.claim}.done" ] && silent

# Claim tạo bằng mkdir nên atomic: hai delivery song song cùng một sha thì chỉ
# một cái vào được.
mkdir "$claim" 2>/dev/null || silent

# Đếm SAU khi đã giữ claim nên trần tính cả chính mình. Đếm trước thì nhiều
# delivery song song đều thấy còn chỗ rồi cùng chạy.
# ponytail: vẫn là xấp xỉ — N racer cùng vượt trần thì tất cả cùng lùi. An
# toàn (thà ít hơn), đổi sang flock nếu cần trần cứng.
max_jobs=${PR_REVIEW_MAX_JOBS:-3}
case $max_jobs in ''|*[!0-9]*) max_jobs=3 ;; esac  # sai kiểu -> fail-closed về 3
running=$(find "$STATE" -maxdepth 1 -name '*.claim' -type d 2>/dev/null | wc -l)
if [ "$running" -gt "$max_jobs" ]; then
    note "TỪ CHỐI: $running job đang chạy, quá trần"
    rmdir "$claim" 2>/dev/null
    silent
fi

# Chỉ review PR của người trong nhà. Repo public trong allowlist thì bất kỳ
# ai fork cũng kích được một phiên claude chạy bằng credential của bạn.
case "${PR_REVIEW_TRUSTED_ONLY:-1}:$assoc" in
    1:OWNER|1:MEMBER|1:COLLABORATOR|0:*) ;;
    *) note "TỪ CHỐI: tác giả PR có quyền $assoc"; rmdir "$claim" 2>/dev/null; silent ;;
esac

# Job tự hỏi GitHub xem sha của mình còn là HEAD không trước khi đăng comment.
PR_REVIEW_SHA="$sha" setsid bash "$SELF" --job "$repo" "$pr" "$claim" \
    >>"$LOG" 2>&1 </dev/null &

silent
