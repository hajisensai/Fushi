"""符号索引的公共部分：索引位置、查询、以及「改动文件自动降级」的判定。"""
from __future__ import annotations

import os
import re
import sqlite3
import subprocess
from dataclasses import dataclass
from pathlib import Path

CODE_EXT: tuple[str, ...] = ('.dart', '.rs')


def default_db_path() -> Path:
    env: str | None = os.environ.get('FUSHI_SYMINDEX_DB')
    if env:
        return Path(env)
    base: str = os.environ.get('LOCALAPPDATA') or os.path.expanduser('~/.cache')
    return Path(base) / 'fushi-symindex' / 'index.sqlite'


@dataclass(frozen=True)
class Sym:
    id: int
    name: str
    kind: str
    container: str
    file: str
    line: int
    lang: str


@dataclass(frozen=True)
class Hit:
    file: str
    line: int


def git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True, encoding='utf-8', errors='replace')


def changed_files(repo: Path, base: str) -> set[str] | None:
    """当前 worktree（含未提交、未跟踪）相对 base 改过的文件；base 不可用时返回 None（整体降级）。"""
    if git(repo, 'cat-file', '-e', f'{base}^{{commit}}').returncode != 0:
        return None
    diff = git(repo, 'diff', '--name-only', '--no-renames', base)
    if diff.returncode != 0:
        return None
    untracked = git(repo, 'ls-files', '-o', '--exclude-standard')
    out: set[str] = {l.strip() for l in diff.stdout.splitlines() if l.strip()}
    out |= {l.strip() for l in untracked.stdout.splitlines() if l.strip()}
    return out


def split_fresh(paths: list[str], changed: set[str]) -> tuple[list[str], list[str]]:
    """把结果路径分成 (仍有效, 已改动需降级)。"""
    fresh: list[str] = [p for p in paths if p not in changed]
    stale: list[str] = [p for p in paths if p in changed]
    return fresh, stale


def live_grep(repo: Path, name: str, files: list[str]) -> list[tuple[str, int, str]]:
    """在给定文件里实时找整词 name，返回 (文件, 行号, 行文本)。"""
    targets: list[str] = [f for f in files if f.endswith(CODE_EXT) and (repo / f).is_file()]
    hits: list[tuple[str, int, str]] = []
    pat: re.Pattern[str] = re.compile(r'(?<![A-Za-z0-9_$])' + re.escape(name) + r'(?![A-Za-z0-9_$])')
    for f in targets:
        try:
            text: str = (repo / f).read_text(encoding='utf-8', errors='replace')
        except OSError:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            if pat.search(line):
                hits.append((f, i, line.strip()[:160]))
    return hits


class Index:
    def __init__(self, path: Path) -> None:
        self.con: sqlite3.Connection = sqlite3.connect(f'file:{path.as_posix()}?mode=ro', uri=True)

    def close(self) -> None:
        self.con.close()

    def meta(self, key: str) -> str | None:
        row = self.con.execute('SELECT value FROM meta WHERE key = ?', (key,)).fetchone()
        return row[0] if row else None

    def _syms(self, where: str, args: tuple, limit: int = -1) -> list[Sym]:
        q: str = ('SELECT s.id, s.name, s.kind, s.container, f.path, s.line, s.lang FROM sym s JOIN file f ON f.id = s.file '
                  f'WHERE {where} ORDER BY f.path, s.line LIMIT ?')
        return [Sym(*r) for r in self.con.execute(q, (*args, limit))]

    def defs(self, name: str, container: str | None = None, kind: str | None = None) -> list[Sym]:
        where: str = 's.name = ?'
        args: list = [name]
        if container is not None:
            where += ' AND s.container = ?'
            args.append(container)
        if kind is not None:
            where += ' AND s.kind = ?'
            args.append(kind)
        return self._syms(where, tuple(args))

    def find(self, sub: str, limit: int) -> list[Sym]:
        return self._syms('s.name LIKE ? COLLATE NOCASE', (f'%{sub}%',), limit)

    def refs(self, sym_id: int) -> list[Hit]:
        q: str = 'SELECT f.path, r.line FROM ref r JOIN file f ON f.id = r.file WHERE r.sym = ? ORDER BY f.path, r.line'
        seen: set[tuple[str, int]] = set()
        out: list[Hit] = []
        for p, l in self.con.execute(q, (sym_id,)):
            if (p, l) not in seen:
                seen.add((p, l))
                out.append(Hit(p, l))
        return out
