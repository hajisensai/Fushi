#!/usr/bin/env python3
"""GitHub Release 下载统计脚本。

用法:
    python gh_download_stats.py                          # 默认 hajisensai/hibiki
    python gh_download_stats.py owner/repo               # 指定仓库
    python gh_download_stats.py owner/repo --token TOKEN  # 带 token（私有仓库 / 提高限额）
"""

import argparse
import json
import sys
from urllib.request import Request, urlopen
from urllib.error import HTTPError

DEFAULT_REPO = "hajisensai/hibiki"
API_BASE = "https://api.github.com"


def fetch_releases(repo: str, token: str | None = None) -> list[dict]:
    url = f"{API_BASE}/repos/{repo}/releases?per_page=100"
    headers = {"Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    all_releases: list[dict] = []
    page = 1
    while True:
        paged = f"{url}&page={page}"
        req = Request(paged, headers=headers)
        try:
            with urlopen(req) as resp:
                data = json.loads(resp.read())
        except HTTPError as e:
            print(f"HTTP {e.code}: {e.reason}", file=sys.stderr)
            if e.code == 404:
                print(f"仓库 {repo} 不存在或是私有仓库（需 --token）", file=sys.stderr)
            sys.exit(1)

        if not data:
            break
        all_releases.extend(data)
        page += 1

    return all_releases


def print_stats(releases: list[dict], repo: str) -> None:
    total = 0
    print(f"\n{'='*60}")
    print(f"  {repo} — Release 下载统计")
    print(f"{'='*60}\n")

    if not releases:
        print("  暂无 Release。")
        return

    for rel in releases:
        tag: str = rel["tag_name"]
        name: str = rel.get("name") or tag
        pre: str = " [pre-release]" if rel["prerelease"] else ""
        draft: str = " [draft]" if rel["draft"] else ""
        date: str = rel["published_at"][:10] if rel["published_at"] else "未发布"
        assets: list[dict] = rel.get("assets", [])

        release_total = sum(a["download_count"] for a in assets)
        total += release_total

        print(f"  {name} ({tag}){pre}{draft}  —  {date}  —  合计: {release_total}")
        for asset in assets:
            dl: int = asset["download_count"]
            size_mb = asset["size"] / (1024 * 1024)
            print(f"    {dl:>6}  {asset['name']}  ({size_mb:.1f} MB)")
        if not assets:
            print(f"    (无附件)")
        print()

    print(f"{'─'*60}")
    print(f"  总下载量: {total}")
    print(f"  Release 数: {len(releases)}")
    print(f"{'─'*60}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="GitHub Release 下载统计")
    parser.add_argument("repo", nargs="?", default=DEFAULT_REPO, help="owner/repo（默认 hajisensai/hibiki）")
    parser.add_argument("--token", "-t", help="GitHub personal access token（私有仓库必须）")
    args = parser.parse_args()

    releases = fetch_releases(args.repo, args.token)
    print_stats(releases, args.repo)


if __name__ == "__main__":
    main()
