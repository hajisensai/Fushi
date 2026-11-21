"""构建符号索引（SQLite）：Dart 走 analyzer（bin/dart_index.dart），Rust 走 `rust-analyzer lsif`。

用法（在要索引的那份 checkout 里，通常是 tool/symindex/refresh.ps1 维护的 develop 专用 worktree）：
  python tool/symindex/build.py [--repo .] [--db <路径>] [--skip-dart] [--skip-rust]

索引记录构建时的 HEAD（base_sha），查询端（sym.py）据此把「当前 worktree 相对 base 改过的文件」
里的索引结果丢掉、改用实时 grep 补上，所以索引旧一点也不会给出错误行号。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path
from typing import Iterator

HERE: Path = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from symdb import default_db_path  # noqa: E402

DART: str = os.environ.get('FUSHI_DART', 'D:/flutter_sdk/flutter_3.47.6/bin/cache/dart-sdk/bin/dart.exe')
RUST_ANALYZER: str = os.environ.get('FUSHI_RUST_ANALYZER', os.path.expanduser('~/.cargo/bin/rust-analyzer'))
SCHEMA: str = """
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE file(id INTEGER PRIMARY KEY, path TEXT UNIQUE);
CREATE TABLE sym(id INTEGER PRIMARY KEY, name TEXT, kind TEXT, container TEXT, file INTEGER, line INTEGER, lang TEXT);
CREATE TABLE ref(sym INTEGER, file INTEGER, line INTEGER);
"""
INDEXES: str = """
CREATE INDEX sym_name ON sym(name);
CREATE INDEX sym_name_nocase ON sym(name COLLATE NOCASE);
CREATE INDEX ref_sym ON ref(sym);
"""


def git(repo: Path, *args: str) -> str:
    return subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()


def workspace_packages(repo: Path) -> list[str]:
    """根 pubspec.yaml 的 workspace 成员。"""
    out: list[str] = []
    inside: bool = False
    for line in (repo / 'pubspec.yaml').read_text(encoding='utf-8').splitlines():
        if line.startswith('workspace:'):
            inside = True
            continue
        if inside:
            m = re.match(r'^\s+-\s+(\S+)', line)
            if m:
                out.append(m.group(1))
            elif line.strip() and not line.startswith((' ', '#')):
                break
    return [p for p in out if (repo / p / 'pubspec.yaml').exists()]


class Loader:
    """把定义 / 引用写进 SQLite，文件路径去重成整数 id。"""

    def __init__(self, con: sqlite3.Connection) -> None:
        self.con = con
        self.files: dict[str, int] = {}
        self.next_sym: int = 1
        self.syms: int = 0
        self.refs: int = 0

    def fid(self, path: str) -> int:
        i: int | None = self.files.get(path)
        if i is None:
            i = len(self.files) + 1
            self.files[path] = i
            self.con.execute('INSERT INTO file(id, path) VALUES (?, ?)', (i, path))
        return i

    def add_sym(self, name: str, kind: str, container: str, path: str, line: int, lang: str) -> int:
        sid: int = self.next_sym
        self.next_sym += 1
        self.con.execute('INSERT INTO sym VALUES (?,?,?,?,?,?,?)', (sid, name, kind, container, self.fid(path), line, lang))
        self.syms += 1
        return sid

    def add_refs(self, rows: list[tuple[int, str, int]]) -> None:
        self.con.executemany('INSERT INTO ref VALUES (?,?,?)', [(s, self.fid(f), l) for s, f, l in rows])
        self.refs += len(rows)


def index_dart(repo: Path, loader: Loader) -> None:
    tool: Path = HERE  # 用本脚本旁边的索引器，被索引的 checkout 可以还没有 tool/symindex
    if not (tool / '.dart_tool' / 'package_config.json').exists():
        subprocess.run([DART, 'pub', 'get'], cwd=tool, check=True, stdout=subprocess.DEVNULL)
    pkgs: list[str] = workspace_packages(repo)
    with tempfile.TemporaryDirectory() as td:
        tsv: Path = Path(td) / 'dart.tsv'
        subprocess.run([DART, 'run', 'bin/dart_index.dart', str(repo), str(tsv), *pkgs], cwd=tool, check=True)
        remap: dict[str, int] = {}
        batch: list[tuple[int, str, int]] = []
        with tsv.open(encoding='utf-8') as f:
            for line in f:
                parts: list[str] = line.rstrip('\n').split('\t')
                if parts[0] == 'D':
                    remap[parts[1]] = loader.add_sym(parts[2], parts[3], parts[4], parts[5], int(parts[6]), 'dart')
                elif parts[0] == 'R':
                    batch.append((remap[parts[1]], parts[2], int(parts[3])))
                    if len(batch) >= 50_000:
                        loader.add_refs(batch)
                        batch = []
        loader.add_refs(batch)


_CODE_BLOCK = re.compile(r'```rust\n(.*?)\n```', re.S)
_RUST_KIND = re.compile(r'\b(fn|struct|enum|trait|type|const|static|mod|union|macro_rules!)\s')


def rust_kind(hover: str) -> tuple[str, str] | None:
    """从 hover 文本推出 (种类, 所属)。局部变量（只有一个代码块、没有关键字）返回 None。"""
    blocks: list[str] = _CODE_BLOCK.findall(hover)
    if not blocks:
        return None
    sig: str = blocks[-1]
    container: str = blocks[0].strip().split('::')[-1] if len(blocks) >= 2 else ''
    m = _RUST_KIND.search(sig)
    if m:
        return m.group(1).rstrip('!'), container
    if len(blocks) >= 2:
        return 'field', container
    return None


def lsif_items(path: Path) -> Iterator[dict]:
    with path.open(encoding='utf-8') as f:
        for line in f:
            yield json.loads(line)


def index_rust_crate(repo: Path, crate: Path, loader: Loader, seen: set[tuple[str, int, str]]) -> None:
    with tempfile.TemporaryDirectory() as td:
        out: Path = Path(td) / 'crate.lsif'
        with out.open('wb') as fo:
            subprocess.run([RUST_ANALYZER, 'lsif', str(crate)], stdout=fo, stderr=subprocess.DEVNULL, check=True)
        docs: dict[int, str] = {}
        ranges: dict[int, tuple[int, int, int]] = {}  # id -> (line0, char0, endchar)
        range_doc: dict[int, int] = {}
        nxt: dict[int, int] = {}
        defres: dict[int, int] = {}
        refres: dict[int, int] = {}
        hover_of: dict[int, int] = {}
        hovers: dict[int, str] = {}
        items_def: dict[int, list[int]] = {}
        items_ref: dict[int, list[int]] = {}
        root_prefix: str = str(repo).replace('\\', '/').rstrip('/') + '/'
        for o in lsif_items(out):
            lab: str = o['label']
            if o['type'] == 'vertex':
                if lab == 'document':
                    p: str = urllib.parse.unquote(o['uri'][len('file:///'):])
                    if p.lower().startswith(root_prefix.lower()):
                        docs[o['id']] = p[len(root_prefix):]
                elif lab == 'range':
                    ranges[o['id']] = (o['start']['line'], o['start']['character'], o['end']['character'])
                elif lab == 'hoverResult':
                    c = o['result']['contents']
                    hovers[o['id']] = c.get('value', '') if isinstance(c, dict) else json.dumps(c)
            else:
                if lab == 'contains':
                    for v in o['inVs']:
                        range_doc[v] = o['outV']
                elif lab == 'next':
                    nxt[o['outV']] = o['inV']
                elif lab == 'textDocument/definition':
                    defres[o['outV']] = o['inV']
                elif lab == 'textDocument/references':
                    refres[o['outV']] = o['inV']
                elif lab == 'textDocument/hover':
                    hover_of[o['outV']] = o['inV']
                elif lab == 'item':
                    tgt: dict[int, list[int]] = items_def if o.get('property') in (None, 'definitions') else items_ref
                    tgt.setdefault(o['outV'], []).extend(o['inVs'])
        lines_cache: dict[str, list[str]] = {}

        def text_at(path: str, r: tuple[int, int, int]) -> str:
            if path not in lines_cache:
                lines_cache[path] = (repo / path).read_text(encoding='utf-8', errors='replace').splitlines()
            ls: list[str] = lines_cache[path]
            return ls[r[0]][r[1]:r[2]] if r[0] < len(ls) else ''

        def loc(rid: int) -> tuple[str, tuple[int, int, int]] | None:
            d: int | None = range_doc.get(rid)
            if d is None or d not in docs or rid not in ranges:
                return None
            return docs[d], ranges[rid]

        for rs, dr in defres.items():
            defs: list[int] = items_def.get(dr, [])
            if not defs:
                continue
            dl = loc(defs[0])
            if dl is None:
                continue
            hk = rust_kind(hovers.get(hover_of.get(rs, -1), ''))
            if hk is None:
                continue
            name: str = text_at(dl[0], dl[1])
            if not re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', name):
                continue
            key: tuple[str, int, str] = (dl[0], dl[1][0], name)
            if key in seen:
                continue
            seen.add(key)
            sid: int = loader.add_sym(name, hk[0], hk[1], dl[0], dl[1][0] + 1, 'rust')
            rows: list[tuple[int, str, int]] = []
            def_set: set[int] = set(defs)
            for rr in items_ref.get(refres.get(rs, -1), []):
                if rr in def_set:
                    continue
                rl = loc(rr)
                if rl is not None:
                    rows.append((sid, rl[0], rl[1][0] + 1))
            loader.add_refs(rows)


def index_rust(repo: Path, loader: Loader) -> None:
    seen: set[tuple[str, int, str]] = set()
    for cargo in sorted((repo / 'native').glob('*/Cargo.toml')):
        t0: float = time.time()
        before: int = loader.syms
        try:
            index_rust_crate(repo, cargo.parent, loader, seen)
        except subprocess.CalledProcessError as e:
            print(f'  rust {cargo.parent.name}: rust-analyzer lsif 失败（{e.returncode}），跳过', file=sys.stderr)
            continue
        print(f'  rust {cargo.parent.name}: +{loader.syms - before} symbols, {time.time() - t0:.0f}s', file=sys.stderr)


def build(repo: Path, db: Path, skip_dart: bool, skip_rust: bool) -> None:
    db.parent.mkdir(parents=True, exist_ok=True)
    tmp: Path = db.with_suffix('.building')
    tmp.unlink(missing_ok=True)
    con: sqlite3.Connection = sqlite3.connect(tmp)
    con.executescript(SCHEMA)
    loader: Loader = Loader(con)
    t0: float = time.time()
    if not skip_dart:
        index_dart(repo, loader)
        print(f'dart done: {loader.syms} symbols, {loader.refs} refs, {time.time() - t0:.0f}s', file=sys.stderr)
    if not skip_rust:
        index_rust(repo, loader)
    con.executescript(INDEXES)
    meta: dict[str, str] = {
        'base_sha': git(repo, 'rev-parse', 'HEAD'),
        'built_at': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'langs': ','.join(l for l, s in (('dart', skip_dart), ('rust', skip_rust)) if not s),
    }
    con.executemany('INSERT INTO meta VALUES (?, ?)', list(meta.items()))
    con.commit()
    con.close()
    os.replace(tmp, db)
    print(f'symindex: {loader.syms} symbols, {loader.refs} refs, {len(loader.files)} files, {time.time() - t0:.0f}s -> {db}', file=sys.stderr)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--repo', default='.')
    ap.add_argument('--db', default=None)
    ap.add_argument('--skip-dart', action='store_true')
    ap.add_argument('--skip-rust', action='store_true')
    ap.add_argument('--if-changed', action='store_true', help='索引的 base_sha 已等于 HEAD 时直接退出')
    ap.add_argument('--check', action='store_true', help='只检查：已是最新退出 0，需要重建退出 10')
    a = ap.parse_args()
    repo: Path = Path(git(Path(a.repo), 'rev-parse', '--show-toplevel'))
    db: Path = Path(a.db) if a.db else default_db_path()
    current: bool = is_current(db, git(repo, 'rev-parse', 'HEAD'))
    if a.check:
        sys.exit(0 if current else 10)
    if a.if_changed and current:
        print('symindex: 已是最新', file=sys.stderr)
        return
    build(repo, db, a.skip_dart, a.skip_rust)


def is_current(db: Path, head: str) -> bool:
    """索引存在且 base_sha 等于 head。"""
    if not db.exists():
        return False
    con: sqlite3.Connection = sqlite3.connect(f'file:{db.as_posix()}?mode=ro', uri=True)
    try:
        row = con.execute("SELECT value FROM meta WHERE key = 'base_sha'").fetchone()
    finally:
        con.close()
    return bool(row) and row[0] == head


if __name__ == '__main__':
    main()
