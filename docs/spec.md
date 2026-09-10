# Spec: pr-review-agent

## WHY

Team đang review PR thủ công — tốn thời gian, chất lượng không nhất quán.
Cần phản hồi tự động sớm, trước khi người review thật vào xem: client mở PR
trên GitHub → Claude Code phân tích diff → review xuất hiện thành comment.

## WHAT

Hermes gateway (đã chạy sẵn trên máy) làm cửa nhận webhook. Claude Code làm
reviewer. Không dựng service HTTP riêng.

```
GitHub PR event
      ↓
hermes :8644/webhooks/pr-review     verify X-Hub-Signature-256, lọc events=pull_request
      ↓
scripts/hermes-hook.sh              lọc action, chống trùng, setsid tách nền, in [SILENT]
      ↓  (ngoài request path)
pr_review.py                        gh pr diff → cắt bớt → claude -p → gh pr comment
```

`[SILENT]` khiến Hermes bỏ qua event sau khi script chạy xong — **không agent
LLM nào của Hermes được kích hoạt**. Hermes thuần là transport.

### Vì sao không tự viết service webhook

Đọc `~/.hermes/hermes-agent/gateway/platforms/webhook.py`, Hermes đã có sẵn:

| Việc | Vị trí |
|---|---|
| HTTP listener + route `/webhooks/<name>` | `webhook.py`, port 8644 |
| Verify `X-Hub-Signature-256` đúng chuẩn GitHub | `webhook.py:1110` |
| Lọc theo event type (`X-GitHub-Event`) | `webhook.py:736` |
| Rate limit | `webhook.py:715` |
| Gọi script ngoài, payload GitHub thô qua stdin | `webhook_filters.py:247` |

Viết lại những thứ này bằng FastAPI là làm lại việc đã xong.

## CONSTRAINTS

- Python stdlib, không dependency. Hai CLI ngoài: `gh`, `claude`.
- Hook chạy **đồng bộ** trong request path của Hermes, timeout 30s, và Hermes
  dùng `capture_output=True`. Tiến trình nền phải `setsid` + redirect cả 3 fd,
  nếu không Hermes treo tới hết timeout.
- Script bắt buộc là file thật dưới `~/.hermes/scripts/` — Hermes resolve
  symlink rồi từ chối đường dẫn nằm ngoài (`webhook_filters.py:66`). Vì vậy
  `install.sh` sinh một shim `exec` trỏ ngược về repo.
- Hook **không nhận được HTTP header**, nên không có `X-GitHub-Delivery`.
  Chống trùng dùng `head_sha` — key này tốt hơn: retry của GitHub gửi lại đúng
  payload cũ nên cùng sha, còn push mới thì khác sha. Claim tạo bằng `mkdir`
  (atomic) và gắn với từng sha, để job của sha cũ không nhả claim của sha mới.
- **Diff là dữ liệu do người ngoài kiểm soát.** Phiên `claude -p` phải chạy
  `--restricted --strict-mcp-config`, danh sách chặn tool, cwd là thư mục rỗng,
  và diff bọc giữa hai mốc mang nonce ngẫu nhiên. `--allowedTools ""` KHÔNG
  chặn được gì — đã kiểm bằng file mồi.
- Webhook secret sinh bằng `openssl rand`, lưu trong
  `~/.hermes/webhook_subscriptions.json` (chmod 600), không nằm trong repo.
- Gateway đang phục vụ bot Feishu production. Bật webhook platform cần restart
  gateway — chấp nhận vài giây gián đoạn.

## OUT OF SCOPE

- Tự sửa code / tạo commit thay reviewer.
- Gate merge, required status check.
- Multi-repo, multi-tenant.
- Inline comment theo từng dòng — chỉ một comment tổng.
- MCP server. MCP là giao thức agent *gọi ra*, không nhận được webhook đẩy vào.
  Khi nào cần review on-demand từ phiên chat thì bọc `pr_review.py` thành MCP
  tool sau, lõi đã sẵn.
- Queue thật (Redis/Celery). State là file phẳng trong
  `~/.hermes/state/pr-review/`.

## TASKS

| # | Task | File | Done when | Trạng thái |
|---|---|---|---|---|
| 1 | CLI review: lấy diff, cắt bớt, gọi Claude, đăng comment | `pr_review.py` | `./pr_review.py owner/repo N` đăng được comment lên PR thật | ✅ |
| 2 | Hook: lọc action, chống trùng, tách nền, `[SILENT]` | `scripts/hermes-hook.sh` | Cùng `head_sha` chỉ chạy 1 lần; push mới huỷ job cũ; hook thoát <1s | ✅ |
| 3 | Cài vào Hermes + nối end-to-end | `install.sh`, `README.md` | Mở PR thật → sau vài phút thấy comment review | ✅ PR #1, `opened` 126s / `synchronize` 141s |
| 4 | Cách ly phiên review khỏi diff không tin cậy | `pr_review.py` | File mồi trên đĩa không đọc được từ phiên review | ✅ đã kiểm |

Self-check: `python3 test_pr_review.py`
