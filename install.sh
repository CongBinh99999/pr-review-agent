#!/usr/bin/env bash
# Cài hook vào Hermes. Chỉ tạo một shim trỏ ngược về repo — logic vẫn nằm
# trong repo và chịu version control. Hermes bắt buộc script phải là file
# thật dưới ~/.hermes/scripts (nó resolve symlink rồi từ chối đường dẫn ngoài).
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
SHIM="$HERMES_HOME/scripts/pr-review.sh"

mkdir -p "$HERMES_HOME/scripts" "$HERMES_HOME/state/pr-review"
ALLOW="$HERMES_HOME/state/pr-review/repos.allow"
[ -f "$ALLOW" ] || : > "$ALLOW"
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$REPO_DIR/scripts/hermes-hook.sh" > "$SHIM"
chmod +x "$SHIM"

echo "Đã cài shim: $SHIM -> $REPO_DIR/scripts/hermes-hook.sh"
echo "Allowlist repo: $ALLOW ($(grep -c . "$ALLOW" 2>/dev/null || echo 0) repo)"
echo
echo "Còn 4 bước thủ công (xem README.md):"
echo "  1. Bật webhook platform trong $HERMES_HOME/config.yaml"
echo "  2. hermes gateway restart"
echo "  3. hermes webhook subscribe pr-review --events pull_request --script pr-review.sh --secret <SECRET>"
echo "  4. Thêm webhook trên GitHub, chỉ chọn event Pull requests"
echo "  5. Ghi repo được phép vào $ALLOW, mỗi dòng một owner/repo"
