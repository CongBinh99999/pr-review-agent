# pr-review-agent

Tự động review pull request bằng Claude Code, kết quả đăng thành comment trên PR.

Hermes làm cửa nhận webhook (HTTP, verify HMAC, lọc event). Claude Code làm
reviewer. Không có service HTTP riêng nào phải nuôi.

```
GitHub PR  →  hermes :8644/webhooks/pr-review  →  verify HMAC  →  events=pull_request
                                                        ↓
                                   scripts/hermes-hook.sh   (payload JSON qua stdin)
                                   lọc action · chống trùng · setsid tách nền · [SILENT]
                                                        ↓
                                   pr_review.py
                                   gh pr diff  →  claude -p  →  gh pr comment
```

Sơ đồ đầy đủ: [`docs/pr-review-flow.html`](docs/pr-review-flow.html) · Spec: [`docs/spec.md`](docs/spec.md)

## Yêu cầu

`python3`, `gh` (đã `gh auth login`), `claude` (đã đăng nhập), và một Hermes
gateway đang chạy. Không có dependency Python nào.

## Dùng tay (không cần Hermes)

```bash
./pr_review.py CongBinh99999/pr-review-agent 12
```

## Gắn vào Hermes

```bash
./install.sh
```

Tạo shim `~/.hermes/scripts/pr-review.sh` trỏ về repo. Sau đó 3 bước thủ công:

**1. Bật webhook platform** — thêm vào `~/.hermes/config.yaml`:

```yaml
platforms:
  webhook:
    enabled: true
    extra:
      port: 8644
```

**2. Restart gateway** (bot Feishu sẽ ngắt vài giây):

```bash
hermes gateway restart
```

**3. Tạo route:**

```bash
SECRET=$(openssl rand -hex 32)
hermes webhook subscribe pr-review \
    --events pull_request \
    --script pr-review.sh \
    --secret "$SECRET" \
    --description "Claude Code review PR"
echo "$SECRET"
```

**4. Trỏ GitHub vào** — Settings → Webhooks → Add webhook:

| Trường | Giá trị |
|---|---|
| Payload URL | `https://<tunnel>/webhooks/pr-review` |
| Content type | `application/json` |
| Secret | `$SECRET` ở trên |
| Events | Chỉ `Pull requests` |

Tunnel cho môi trường dev (`cloudflared` đã có sẵn trên máy):

```bash
cloudflared tunnel --url http://localhost:8644
```

## Vận hành

```bash
tail -f ~/.hermes/state/pr-review/review.log   # log job review
hermes logs -f                                  # log gateway
hermes webhook list                             # xem route
python3 test_pr_review.py                       # self-check
```

## Hành vi

- **Chống trùng** theo `head_sha`. GitHub retry gửi lại đúng payload cũ → bỏ qua.
- **Push mới cho cùng PR** → huỷ job đang chạy, chỉ review sha mới nhất.
- **Diff > 1500 dòng** → chỉ review phần đầu, comment ghi rõ đã cắt.
- **`claude -p` treo quá 15 phút** → job bị giết, ghi log, không comment.

## Vì sao hook phải thoát ngay

Hermes chạy `--script` **đồng bộ** trong request path, timeout 30s, và dùng
`capture_output=True`. Một tiến trình nền chạy bằng `&` mà vẫn giữ stdout sẽ
khiến Hermes treo tới hết timeout. Nên hook bắt buộc `setsid` + redirect cả ba
fd, rồi in `[SILENT]` để Hermes bỏ qua event (không kích hoạt agent LLM nào).

## Giới hạn đã biết

- Một repo. Nhiều repo thì mỗi repo một route, hoặc bỏ filter và đọc `full_name`.
- Không review inline theo dòng, chỉ một comment tổng.
- State là file phẳng trong `~/.hermes/state/pr-review/`, mất khi xoá thư mục.
