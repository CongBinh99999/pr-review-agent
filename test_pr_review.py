#!/usr/bin/env python3
"""Self-check: python3 test_pr_review.py

Kiểm hai chỗ dễ vỡ: cắt diff, và hook (chống trùng + tách tiến trình nền).
"""

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).parent
HOOK = HERE / "scripts" / "hermes-hook.sh"


def test_cap_diff():
    sys.path.insert(0, str(HERE))
    from pr_review import cap_diff

    short = "\n".join(f"line {i}" for i in range(10))
    out, cut = cap_diff(short, max_lines=1500)
    assert out == short and cut is False, "diff ngắn không được đụng vào"

    long = "\n".join(f"line {i}" for i in range(100))
    out, cut = cap_diff(long, max_lines=40)
    assert cut is True, "diff dài phải bị đánh dấu là đã cắt"
    assert out.startswith("line 0\n"), "phải giữ phần đầu"
    assert "line 39" in out and "line 40" not in out.split("[...")[0], "cắt sai chỗ"
    assert "đã cắt 60 dòng cuối" in out, "phải ghi rõ số dòng bị bỏ"
    print("ok  cap_diff")


def payload(sha, action="synchronize", pr=7):
    return json.dumps(
        {
            "action": action,
            "number": pr,
            "repository": {"full_name": "acme/widgets"},
            "pull_request": {"head": {"sha": sha}},
        }
    )


def fire(state, cli, body):
    """Gọi hook, trả (stdout, số giây chạy)."""
    env = {**os.environ, "PR_REVIEW_STATE": str(state), "PR_REVIEW_CLI": str(cli)}
    t0 = time.time()
    p = subprocess.run(
        ["bash", str(HOOK)], input=body, capture_output=True, text=True, env=env
    )
    return p.stdout.strip(), time.time() - t0


def test_hook():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        state, runs = tmp / "state", tmp / "runs"
        runs.mkdir()

        # CLI giả: ghi lại là đã chạy, rồi ngủ để test huỷ job cũ.
        cli = tmp / "fake-cli"
        cli.write_text(
            "#!/usr/bin/env bash\n"
            f"echo \"$2\" >> '{runs}/log'\n"
            "sleep 30\n"
        )
        cli.chmod(0o755)

        out, secs = fire(state, cli, payload("aaa"))
        assert out == "[SILENT]", f"hook phải in [SILENT], nhận: {out!r}"
        assert secs < 5, f"hook phải thoát ngay, mất {secs:.1f}s"
        time.sleep(1.0)
        assert (runs / "log").exists(), "job nền không chạy"
        assert len((runs / "log").read_text().split()) == 1

        # Cùng head_sha (GitHub retry) -> không chạy lần hai.
        assert fire(state, cli, payload("aaa"))[0] == "[SILENT]"
        time.sleep(1.0)
        assert len((runs / "log").read_text().split()) == 1, "chống trùng hỏng"

        # Action không quan tâm -> bỏ qua.
        assert fire(state, cli, payload("bbb", action="closed"))[0] == "[SILENT]"
        time.sleep(0.5)
        assert len((runs / "log").read_text().split()) == 1, "lọc action hỏng"

        # Push mới: job cũ bị huỷ, job mới chạy.
        old_pgid = int((state / "acme_widgets#7.pid").read_text())
        assert fire(state, cli, payload("ccc"))[0] == "[SILENT]"
        time.sleep(1.0)
        assert len((runs / "log").read_text().split()) == 2, "job mới không chạy"
        assert (
            subprocess.run(["kill", "-0", "--", f"-{old_pgid}"], capture_output=True).returncode
            != 0
        ), "job cũ chưa bị huỷ (last-write-wins hỏng)"

        # Dọn job đang chạy.
        new_pgid = int((state / "acme_widgets#7.pid").read_text())
        subprocess.run(["kill", "-TERM", "--", f"-{new_pgid}"], capture_output=True)
    print("ok  hook (chống trùng, lọc action, huỷ job cũ, thoát ngay)")


if __name__ == "__main__":
    test_cap_diff()
    test_hook()
    print("PASS")
