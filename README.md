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

Tạo shim `~/.hermes/scripts/pr-review.sh` trỏ về repo. Sau đó 4 bước thủ công:

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
umask 077
mkdir -p ~/.hermes/state/pr-review
openssl rand -hex 32 > ~/.hermes/state/pr-review/webhook-secret
 hermes webhook subscribe pr-review \
    --events pull_request \
    --script pr-review.sh \
    --secret "$(cat ~/.hermes/state/pr-review/webhook-secret)" \
    --description "Claude Code review PR"
```

Dấu cách đầu dòng `hermes` là cố ý — với `HISTCONTROL=ignorespace` thì lệnh
không vào shell history. Secret vẫn hiện thoáng qua trong `ps` lúc chạy: Hermes
chỉ nhận secret qua tham số dòng lệnh, không có đường env/stdin. Đọc lại secret
bằng `cat ~/.hermes/state/pr-review/webhook-secret` khi cần dán vào GitHub.

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

- **Chống trùng** theo `head_sha`, claim tạo bằng `mkdir` nên atomic — hai
  delivery song song cùng một sha chỉ có một cái chạy.
- **Job hỏng** (gh lỗi, claude timeout) → comment ⚠️ báo hỏng ngay trên PR kèm
  cách chạy lại. Claim vẫn giữ, nên GitHub redeliver không đẻ comment trùng;
  muốn thử lại thì đẩy commit mới hoặc chạy `./pr_review.py` bằng tay.
- **Push mới cho cùng PR** → huỷ job đang chạy, chỉ review sha mới nhất.
- **Diff > 1500 dòng hoặc > 120k ký tự** → chỉ review phần đầu, comment ghi rõ
  cắt vì lý do nào.
- **Diff là dữ liệu không tin cậy.** Nó được bọc giữa hai mốc mang nonce ngẫu
  nhiên (mốc cố định thì một file trong PR chỉ cần chứa đúng dòng đó là thoát
  ra), và phiên review chạy `--restricted --strict-mcp-config` với danh sách
  chặn tool, cwd trỏ vào thư mục rỗng. Đã kiểm bằng file mồi: phiên không đọc
  được file trên đĩa.
- **`claude -p` treo quá 15 phút** → job bị giết, ghi log, không comment.

## Vì sao hook phải thoát ngay

Hermes chạy `--script` **đồng bộ** trong request path, timeout 30s, và dùng
`capture_output=True`. Một tiến trình nền chạy bằng `&` mà vẫn giữ stdout sẽ
khiến Hermes treo tới hết timeout. Nên hook bắt buộc `setsid` + redirect cả ba
fd, rồi in `[SILENT]` để Hermes bỏ qua event (không kích hoạt agent LLM nào).

## Giới hạn đã biết

- **Một repo.** Về kỹ thuật nhiều repo trỏ chung một route thì vẫn chạy (hook
  đọc `full_name` từ payload), nhưng chưa kiểm và không có giới hạn số job chạy
  song song — đừng coi là đã hỗ trợ.
- Không review inline theo dòng, chỉ một comment tổng.
- State là file phẳng trong `~/.hermes/state/pr-review/`, mất khi xoá thư mục.
