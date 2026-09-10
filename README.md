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

Tạo shim `~/.hermes/scripts/pr-review.sh` trỏ về repo. Sau đó 5 bước thủ công:

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
# ... dán secret vào GitHub ở bước 4, xong thì:
# rm ~/.hermes/state/pr-review/webhook-secret
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

**5. Cho phép repo** — fail-closed, file rỗng thì mọi PR bị từ chối:

```bash
echo "CongBinh99999/pr-review-agent" >> ~/.hermes/state/pr-review/repos.allow
```

Tunnel cho môi trường dev (`cloudflared` đã có sẵn trên máy):

```bash
cloudflared tunnel --url http://localhost:8644
```

## Vận hành

```bash
tail -f ~/.hermes/state/pr-review/review.log   # log job review
hermes logs -f                                  # log gateway
hermes webhook list                             # xem route
python3 test_pr_review.py                       # self-check nhanh
python3 test_pr_review.py --canary              # + kiểm hàng rào tool (~6 phút)
```

## Hành vi

- **Chống trùng** theo `head_sha`, claim tạo bằng `mkdir` nên atomic — hai
  delivery song song cùng một sha chỉ có một cái chạy.
- **Claude hỏng** → comment ⚠️ trên PR kèm cách chạy lại; claim giữ nguyên nên
  redeliver không đẻ comment trùng.
- **`gh` hỏng** → không comment được bằng chính công cụ đang hỏng. Job tự thử
  lại 3 lần (nghỉ 30s rồi 60s); Hermes đã trả 200 cho GitHub trước khi job
  chạy nên GitHub sẽ không bao giờ redeliver, retry phải nằm trong job. Lần
  thử cuối vẫn cố đăng comment ⚠️ (PR to làm `gh pr diff` quá hạn trong khi
  `gh pr comment` vẫn chạy được). Hết 3 lần thì nhả claim: đẩy commit mới hoặc
  chạy tay để thử lại.
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

- **Tối đa ~3 job song song** (`PR_REVIEW_MAX_JOBS`). Xấp xỉ, không phải trần
  cứng: nhiều delivery cùng lúc có thể cùng lùi. Vượt thì bỏ qua và ghi log —
  không có hàng đợi.
- **Chỉ review PR của OWNER / MEMBER / COLLABORATOR** (`author_association`).
  Đặt `PR_REVIEW_TRUSTED_ONLY=0` để review cả PR từ người ngoài — chỉ làm vậy
  nếu bạn tin vào hàng rào tool, vì khi đó bất kỳ ai fork cũng kích được một
  phiên `claude -p` chạy bằng credential của bạn.
- **`review.log` không tự xoay.** Muốn giới hạn thì dùng logrotate với
  `copytruncate` — hook không tự cắt vì làm vậy sẽ mất log của job đang chạy.
- **`--canary` phải chạy trước mỗi lần deploy.** Nó là thứ duy nhất chứng minh
  phiên review không đọc được file trên đĩa; bản `claude` mới đổi cờ cách ly là
  hàng rào thủng âm thầm. Không nằm trong self-check mặc định vì chạy 2 phiên
  `claude` thật.
- **Phiên review vẫn nhận `HOME` thật** (claude cần nó để đăng nhập), nên
  `~/.claude` và `~/.config/gh/hosts.yml` nằm trong tầm với *nếu* hàng rào tool
  thủng. Test canary `test_tool_fence` là thứ canh chuyện đó.
- Không review inline theo dòng, chỉ một comment tổng.
- State là file phẳng trong `~/.hermes/state/pr-review/`, mất khi xoá thư mục.
