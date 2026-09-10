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
chmod 600 ~/.hermes/state/pr-review/webhook-secret
 hermes webhook subscribe pr-review \
    --events pull_request \
    --script pr-review.sh \
    --secret "$(cat ~/.hermes/state/pr-review/webhook-secret)" \
    --description "Claude Code review PR"
```

**Secret sẽ lộ, hãy biết trước điều đó.** Hermes chỉ nhận secret qua tham số
dòng lệnh (không có đường env/stdin), nên nó hiện trong `ps` lúc chạy và vào
shell history — dấu cách đầu dòng chỉ giúp nếu bạn đã bật `HISTCONTROL=ignorespace`
(bash) hoặc `setopt HIST_IGNORE_SPACE` (zsh, **không** bật sẵn). Đọc lại bằng
`cat ~/.hermes/state/pr-review/webhook-secret` để dán vào GitHub rồi xoá file
(`rm`; trên filesystem journaled/CoW thì `shred` không đảm bảo gì hơn). Bản
chính nằm trong `webhook_subscriptions.json`. Coi đây là secret của môi trường
dev — muốn chặt chẽ thì xoay secret khi lên production.

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
- **Claude hỏng** → comment ⚠️ trên PR kèm cách chạy lại; claim giữ nguyên nên
  redeliver không đẻ comment trùng.
- **`gh` hỏng** → không comment được bằng chính công cụ đang hỏng, nên job nhả
  claim (mã thoát 2) để lần delivery sau chạy lại.
- **Diff > 1500 dòng hoặc > 120k ký tự** → chỉ review phần đầu, comment ghi rõ
  cắt vì lý do nào.
- **Diff là dữ liệu không tin cậy.** Nó được bọc giữa hai mốc mang nonce ngẫu
  nhiên (mốc cố định thì một file trong PR chỉ cần chứa đúng dòng đó là thoát
  ra), và phiên review chạy `--restricted --strict-mcp-config --tools ""` —
  allowlist rỗng, không tool nào — với cwd trỏ vào thư mục rỗng và env chỉ gồm
  danh sách biến tối thiểu (token của gateway không đi vào). Đã kiểm bằng file
  mồi: phiên không đọc được file trên đĩa.
- **`claude -p` quá 15 phút** → job bị giết và comment ⚠️ báo hỏng lên PR.
- **Push mới khi job cũ đang chạy** → job cũ *vẫn chạy hết*, nhưng trước khi
  đăng comment nó hỏi GitHub xem sha của mình còn là HEAD không; không còn thì
  im lặng thoát. Huỷ hợp tác, không dùng `kill` — nên không có race pidfile và
  không bao giờ bắn nhầm process group.
- **Review quá 60k ký tự** → cắt bớt trước khi đăng, vì GitHub từ chối comment
  dài hơn 65536 ký tự.
- **PR đóng rồi mở lại** (`reopened`, cùng sha) → bỏ qua: review của sha đó vẫn
  còn nguyên trên PR.

## Vì sao hook phải thoát ngay

Hermes chạy `--script` **đồng bộ** trong request path, timeout 30s, và dùng
`capture_output=True`. Một tiến trình nền chạy bằng `&` mà vẫn giữ stdout sẽ
khiến Hermes treo tới hết timeout. Nên hook bắt buộc `setsid` + redirect cả ba
fd, rồi in `[SILENT]` để Hermes bỏ qua event (không kích hoạt agent LLM nào).

## Giới hạn đã biết

- **Repo phải nằm trong allowlist** `~/.hermes/state/pr-review/repos.allow`
  (mỗi dòng một `owner/repo`). Fail-closed: file rỗng thì không repo nào được
  review. Nhiều repo về kỹ thuật chạy được nhưng chưa kiểm và chưa giới hạn số
  job song song.
- **`review.log` không tự xoay.** Muốn giới hạn thì dùng logrotate với
  `copytruncate` — hook không tự cắt vì làm vậy sẽ mất log của job đang chạy.
- **Phiên review vẫn nhận `HOME` thật** (claude cần nó để đăng nhập), nên
  `~/.claude` và `~/.config/gh/hosts.yml` nằm trong tầm với *nếu* hàng rào tool
  thủng. Test canary `test_tool_fence` là thứ canh chuyện đó.
- Không review inline theo dòng, chỉ một comment tổng.
- State là file phẳng trong `~/.hermes/state/pr-review/`, mất khi xoá thư mục.
