"""符号索引的公共部分：索引位置、查询、以及「改动文件自动降级」的判定。"""
from __future__ import annotations

import os
import re
import sqlite3
import subprocess
from dataclasses import dataclass
from pathlib import Path

CODE_EXT: tuple[str, ...] = ('.dart', '.rs')
# meta 键：构建时没收全的目录（逗号分隔，相对仓库根），见 HBK-AUDIT-018
INCOMPLETE_KEY: str = 'incomplete_dirs'


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


def git_paths(repo: Path, *args: str) -> list[str] | None:
    """跑一条输出文件清单的 git 命令（调用方须带 -z），按 NUL 切出原始路径；失败返回 None。

    不能按行读：默认 core.quotePath 会把非 ASCII 路径（中文文件名）转义成 "\\344\\270\\255..."，
    与索引里存的实际路径对不上（HBK-AUDIT-017）。-z 输出原样字节，也不受文件名里的换行 / 引号影响。
    """
    r = git(repo, *args)
    if r.returncode != 0:
        return None
    return [p for p in r.stdout.split('\0') if p]


def changed_files(repo: Path, base: str) -> set[str] | None:
    """当前 worktree（含未提交、未跟踪、删除）相对 base 改过的文件；base 不可用或 git 失败时返回 None（整体降级）。"""
    if git(repo, 'cat-file', '-e', f'{base}^{{commit}}').returncode != 0:
        return None
    diff: list[str] | None = git_paths(repo, 'diff', '--name-only', '-z', '--no-renames', base)
    untracked: list[str] | None = git_paths(repo, 'ls-files', '-z', '-o', '--exclude-standard')
    if diff is None or untracked is None:
        return None
    return set(diff) | set(untracked)


def files_under(repo: Path, dirs: list[str]) -> set[str]:
    """当前 worktree 里 dirs 下的全部文件（跟踪 + 未跟踪），用于把索引没收全的目录整体当改动处理。"""
    if not dirs:
        return set()
    out: list[str] | None = git_paths(repo, 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', *dirs)
    if out is None:
        raise RuntimeError(f'git ls-files 失败：{dirs}')
    return set(out)


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

    def incomplete_dirs(self) -> list[str]:
        """构建时失败、没收进索引的目录（如 lsif 失败的 crate）；旧索引没有这个键视为无。"""
        v: str | None = self.meta(INCOMPLETE_KEY)
        return [d for d in v.split(',') if d] if v else []

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
