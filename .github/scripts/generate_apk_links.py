#!/usr/bin/env python3
"""Generate Server/links.md from APK files in the repository."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
from urllib.parse import quote

REPOSITORY = "daxiaamu/oplusmutools"
JSDELIVR_MAX_BYTES = 20_000_000


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--commit", default=os.environ.get("GITHUB_SHA"))
    parser.add_argument("--root", type=Path, default=Path("Server"))
    parser.add_argument("--output", type=Path, default=Path("Server/links.md"))
    args = parser.parse_args()

    if not args.commit:
        parser.error("--commit or GITHUB_SHA is required")

    commit = args.commit.strip()
    apk_files = sorted(
        (path for path in args.root.rglob("*") if path.is_file() and path.suffix.lower() == ".apk"),
        key=lambda path: path.relative_to(args.root).as_posix().casefold(),
    )
    if not apk_files:
        raise SystemExit("No APK files found under Server")

    lines = [
        "# APK 下载链接",
        "",
        "本文件由 GitHub Actions 自动生成。每次 `Server/**/*.apk` 发生变化时都会重新扫描。",
        "",
        f"所有地址固定到包含本次 APK 集合的提交 `{commit}`，不依赖分支。",
        "",
        "> CDN 属于第三方服务，缓存刷新时间和可用性不受本仓库控制。下载后建议核对 SHA-256。jsDelivr 的 GitHub CDN 默认不支持大于 20 MB 的单文件。",
        "",
    ]

    for path in apk_files:
        relative = path.relative_to(args.root).as_posix()
        encoded = quote(relative, safe="/-_.~")
        size = path.stat().st_size
        size_mib = size / (1024 * 1024)
        base_path = f"Server/{encoded}"

        lines.extend(
            [
                f"## `{relative}`",
                "",
                f"- 文件大小：{size_mib:.2f} MiB",
                f"- GitHub Raw：[下载](https://raw.githubusercontent.com/{REPOSITORY}/{commit}/{base_path})",
            ]
        )
        if size <= JSDELIVR_MAX_BYTES:
            lines.append(
                f"- jsDelivr：[下载](https://cdn.jsdelivr.net/gh/{REPOSITORY}@{commit}/{base_path})"
            )
        else:
            lines.append("- jsDelivr：不可用（文件超过其 GitHub CDN 默认 20 MB 限制）")

        lines.extend(
            [
                f"- Statically：[下载](https://cdn.statically.io/gh/{REPOSITORY}@{commit}/{base_path})",
                f"- StaticDelivr：[下载](https://cdn.staticdelivr.com/gh/{REPOSITORY}/{commit}/{base_path})",
                f"- GitHack：[下载](https://rawcdn.githack.com/{REPOSITORY}/{commit}/{base_path})",
                f"- SHA-256：`{sha256(path)}`",
                "",
            ]
        )

    lines.extend(
        [
            "## CDN 地址规则",
            "",
            f"- GitHub Raw：`https://raw.githubusercontent.com/{REPOSITORY}/{commit}/Server/文件路径`",
            f"- jsDelivr：`https://cdn.jsdelivr.net/gh/{REPOSITORY}@{commit}/Server/文件路径`",
            f"- Statically：`https://cdn.statically.io/gh/{REPOSITORY}@{commit}/Server/文件路径`",
            f"- StaticDelivr：`https://cdn.staticdelivr.com/gh/{REPOSITORY}/{commit}/Server/文件路径`",
            f"- GitHack：`https://rawcdn.githack.com/{REPOSITORY}/{commit}/Server/文件路径`",
            "",
        ]
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(lines))


if __name__ == "__main__":
    main()
