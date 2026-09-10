#!/usr/bin/env python3
"""Review một PR trên GitHub bằng Claude Code, đăng kết quả thành comment.

    pr_review.py <owner/repo> <pr_number>

Chỉ dùng stdlib + hai CLI có sẵn: `gh` và `claude`.
"""

import subprocess
import sys
import time

MAX_DIFF_LINES = 1500
CLAUDE_TIMEOUT = 900

INSTRUCTIONS = """Bạn là code reviewer. Diff của một pull request nằm ở stdin.
Viết review bằng tiếng Việt, ưu tiên theo thứ tự:

1. Bug và lỗi logic — nêu rõ file:dòng, và input nào làm nó sai.
2. Lỗ hổng bảo mật, secret bị hardcode, input không được validate.
3. Code thừa hoặc có thể đơn giản hoá đáng kể.

Bỏ qua style, format và cách đặt tên, trừ khi chúng gây hiểu nhầm thật sự.
Không tóm tắt lại diff, không khen. Mỗi phát hiện 1-3 dòng.
Nếu không có gì đáng nói, trả lời đúng một dòng: Không thấy vấn đề đáng lưu ý."""


def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def cap_diff(diff, max_lines=MAX_DIFF_LINES):
    """Cắt diff quá dài. Trả về (nội dung, đã_cắt)."""
    lines = diff.splitlines()
    if len(lines) <= max_lines:
        return diff, False
    dropped = len(lines) - max_lines
    kept = "\n".join(lines[:max_lines])
    return f"{kept}\n\n[... đã cắt {dropped} dòng cuối ...]", True


def run(argv, stdin=None, timeout=60):
    """Chạy lệnh, trả stdout hoặc None nếu lỗi/timeout."""
    try:
        p = subprocess.run(
            argv, input=stdin, capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        log(f"TIMEOUT {timeout}s: {' '.join(argv[:3])}")
        return None
    except FileNotFoundError:
        log(f"THIẾU LỆNH: {argv[0]}")
        return None
    if p.returncode != 0:
        log(f"LỖI rc={p.returncode}: {' '.join(argv[:3])} :: {p.stderr.strip()[:300]}")
        return None
    return p.stdout


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: pr_review.py <owner/repo> <pr_number>")
    repo, pr = sys.argv[1], sys.argv[2]
    started = time.time()
    log(f"BẮT ĐẦU repo={repo} pr={pr}")

    diff = run(["gh", "pr", "diff", pr, "--repo", repo], timeout=120)
    if diff is None:
        return 1
    if not diff.strip():
        log("BỎ QUA: diff rỗng")
        return 0

    body, truncated = cap_diff(diff)
    log(f"diff {len(diff.splitlines())} dòng, đã_cắt={truncated}")

    review = run(
        ["claude", "-p", INSTRUCTIONS, "--allowedTools", ""],
        stdin=body,
        timeout=CLAUDE_TIMEOUT,
    )
    if review is None:
        return 1
    review = review.strip()
    if not review:
        log("LỖI: claude trả về rỗng")
        return 1

    comment = f"🤖 **Claude Code review**\n\n{review}"
    if truncated:
        comment += (
            f"\n\n---\n_Diff dài hơn {MAX_DIFF_LINES} dòng — "
            "chỉ phần đầu được review._"
        )

    if run(
        ["gh", "pr", "comment", pr, "--repo", repo, "--body-file", "-"],
        stdin=comment,
    ) is None:
        return 1

    log(f"XONG sau {time.time() - started:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
