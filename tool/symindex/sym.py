"""按符号名查定义 / 引用（Dart + Rust），替代跨目录的 grep -rn。

  python tool/symindex/sym.py def  <名字> [--in <所属类/模块>] [--kind <种类>]
  python tool/symindex/sym.py refs <名字> [--in <所属>] [--kind <种类>] [--limit 80]
  python tool/symindex/sym.py find <子串> [--limit 40]

结果按语义解析（同名但无关的符号、注释和字符串里的同名文字不会混进来）。索引建在 develop 上
（tool/symindex/refresh.ps1 定时刷新）；当前 worktree 相对索引 base 改过的文件，其索引结果自动
丢弃，改为在这些文件里实时整词搜索，标 [live]（未经语义解析）。索引缺失或 base 不可用时整体
降级成 git grep，并在第一行说明。
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from symdb import Hit, Index, Sym, changed_files, default_db_path, live_grep, split_fresh  # noqa: E402


def repo_root() -> Path:
    r = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit('sym.py: 不在 git 仓库里')
    return Path(r.stdout.strip())


def fallback_grep(repo: Path, name: str, why: str, limit: int) -> None:
    print(f'[降级] {why}，改用 git grep（未经语义解析）')
    r = subprocess.run(['git', '-C', str(repo), 'grep', '-n', '-w', '-I', name, '--', '*.dart', '*.rs'],
                       capture_output=True, text=True, encoding='utf-8', errors='replace')
    lines: list[str] = r.stdout.splitlines()
    for l in lines[:limit]:
        print(l[:200])
    if len(lines) > limit:
        print(f'... 另有 {len(lines) - limit} 处')


def fmt_sym(s: Sym) -> str:
    owner: str = f'{s.container}.' if s.container else ''
    return f'{s.file}:{s.line}  {s.kind} {owner}{s.name}  [{s.lang}]'


def print_hits(hits: list[Hit], limit: int) -> None:
    by_file: dict[str, list[int]] = defaultdict(list)
    for h in hits:
        by_file[h.file].append(h.line)
    shown: int = 0
    for f, ls in by_file.items():
        if shown >= limit:
            print(f'  ... 另有 {len(by_file) - list(by_file).index(f)} 个文件')
            break
        print(f'  {f}:{",".join(map(str, ls[:12]))}{" ..." if len(ls) > 12 else ""}')
        shown += 1


def main() -> None:
    # Windows 下管道输出默认按本地代码页（cp936）写，agent 读到的中文会乱码
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['def', 'refs', 'find'])
    ap.add_argument('name')
    ap.add_argument('--in', dest='container', default=None)
    ap.add_argument('--kind', default=None)
    ap.add_argument('--limit', type=int, default=80)
    a = ap.parse_args()
    repo: Path = repo_root()
    db: Path = default_db_path()
    if not db.exists():
        fallback_grep(repo, a.name, f'索引不存在（{db}）', a.limit)
        return
    ix: Index = Index(db)
    base: str = ix.meta('base_sha') or ''
    changed: set[str] | None = changed_files(repo, base)
    if changed is None:
        fallback_grep(repo, a.name, f'索引 base {base[:10]} 在本仓找不到', a.limit)
        return
    print(f'# 索引 base {base[:10]}（{ix.meta("built_at")}），本 worktree 相对它改了 {len(changed)} 个文件')

    if a.cmd == 'find':
        for s in ix.find(a.name, a.limit):
            print(('[改动] ' if s.file in changed else '') + fmt_sym(s))
        return

    syms: list[Sym] = ix.defs(a.name, a.container, a.kind)
    fresh_syms: list[Sym] = [s for s in syms if s.file not in changed]
    stale_syms: list[Sym] = [s for s in syms if s.file in changed]
    if not syms:
        print('（索引里没有这个名字的定义）')
    for s in fresh_syms:
        print(fmt_sym(s))
        if a.cmd == 'refs':
            hits: list[Hit] = ix.refs(s.id)
            fresh, _ = split_fresh([h.file for h in hits], changed)
            fresh_set: set[str] = set(fresh)
            kept: list[Hit] = [h for h in hits if h.file in fresh_set]
            print(f'  {len(kept)} 处引用（另有 {len(hits) - len(kept)} 处落在改动文件里，见下方 [live]）' if len(kept) != len(hits) else f'  {len(kept)} 处引用')
            print_hits(kept, a.limit)
    for s in stale_syms:
        print(f'[改动文件，行号可能已变] {fmt_sym(s)}')
    # 改动文件里实时整词搜索：覆盖索引之后新加 / 挪动的定义与引用
    live = live_grep(repo, a.name, sorted(changed))
    if live:
        print(f'[live] 改动文件里的实时整词匹配（{len(live)} 处，未经语义解析）：')
        for f, l, t in live[:a.limit]:
            print(f'  {f}:{l}  {t}')


if __name__ == '__main__':
    main()
