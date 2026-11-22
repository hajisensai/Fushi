"""tool/symindex 的单元测试：改动文件判定（自动降级的依据）、实时整词搜索、Rust hover 解析、查询。

  python3 tool/symindex/symdb_test.py
"""
from __future__ import annotations

import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE: Path = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build  # noqa: E402
from symdb import Index, changed_files, files_under, live_grep, split_fresh  # noqa: E402


def sh(repo: Path, *args: str) -> str:
    return subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()


class ChangedFilesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo: Path = Path(self.tmp.name)
        sh(self.repo, 'init', '-q')
        sh(self.repo, 'config', 'user.email', 't@example.com')
        sh(self.repo, 'config', 'user.name', 't')
        (self.repo / 'a.dart').write_text('class Foo {}\n', encoding='utf-8')
        (self.repo / 'b.dart').write_text('Foo f = Foo();\n', encoding='utf-8')
        sh(self.repo, 'add', '.')
        sh(self.repo, 'commit', '-q', '-m', 'base')
        self.base: str = sh(self.repo, 'rev-parse', 'HEAD')

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_unchanged_worktree_has_no_changed_files(self) -> None:
        self.assertEqual(changed_files(self.repo, self.base), set())

    def test_committed_uncommitted_and_untracked_changes_all_count(self) -> None:
        (self.repo / 'a.dart').write_text('class Foo { int x = 0; }\n', encoding='utf-8')
        sh(self.repo, 'commit', '-q', '-am', 'later')
        (self.repo / 'b.dart').write_text('\nFoo f = Foo();\n', encoding='utf-8')
        (self.repo / 'c.dart').write_text('Foo g;\n', encoding='utf-8')
        self.assertEqual(changed_files(self.repo, self.base), {'a.dart', 'b.dart', 'c.dart'})

    def test_unknown_base_degrades_whole_query(self) -> None:
        self.assertIsNone(changed_files(self.repo, '0' * 40))

    def test_split_fresh_drops_results_in_changed_files(self) -> None:
        fresh, stale = split_fresh(['a.dart', 'b.dart', 'a.dart'], {'b.dart'})
        self.assertEqual(fresh, ['a.dart', 'a.dart'])
        self.assertEqual(stale, ['b.dart'])

    def test_live_grep_matches_whole_words_only(self) -> None:
        (self.repo / 'b.dart').write_text('Foo f;\nFooBar g;\n_Foo h;\nx.Foo();\n', encoding='utf-8')
        hits = live_grep(self.repo, 'Foo', ['b.dart', 'missing.dart', 'notes.md'])
        self.assertEqual([(f, l) for f, l, _ in hits], [('b.dart', 1), ('b.dart', 4)])


class ChineseChangedFilesTest(unittest.TestCase):
    """HBK-AUDIT-017：中文路径必须按原始路径进改动集合（git 默认 core.quotePath 会把它转义成 "\\344..."）。"""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo: Path = Path(self.tmp.name)
        sh(self.repo, 'init', '-q')
        sh(self.repo, 'config', 'user.email', 't@example.com')
        sh(self.repo, 'config', 'user.name', 't')
        (self.repo / '中文').mkdir()
        (self.repo / '中文' / '甲.dart').write_text('class Jia {}\n', encoding='utf-8')
        (self.repo / '中文' / '乙.dart').write_text('class Yi {}\n', encoding='utf-8')
        (self.repo / '删除.rs').write_text('fn gone() {}\n', encoding='utf-8')
        (self.repo / '暂存.dart').write_text('class Zan {}\n', encoding='utf-8')
        (self.repo / 'a.dart').write_text('class A {}\n', encoding='utf-8')
        sh(self.repo, 'add', '.')
        sh(self.repo, 'commit', '-q', '-m', 'base')
        self.base: str = sh(self.repo, 'rev-parse', 'HEAD')

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_cjk_tracked_untracked_deleted_and_staged(self) -> None:
        (self.repo / '中文' / '甲.dart').write_text('class Jia { void neuName() {} }\n', encoding='utf-8')
        (self.repo / '删除.rs').unlink()
        (self.repo / '暂存.dart').write_text('class Zan2 {}\n', encoding='utf-8')
        sh(self.repo, 'add', '暂存.dart')
        (self.repo / '中文' / '新文件.dart').write_text('class Xin {}\n', encoding='utf-8')
        self.assertEqual(changed_files(self.repo, self.base), {'中文/甲.dart', '删除.rs', '暂存.dart', '中文/新文件.dart'})

    def test_cjk_committed_change_drops_index_rows_and_live_grep_finds_new_identifier(self) -> None:
        (self.repo / '中文' / '乙.dart').write_text('class Yi {}\nvoid freshIdent() {}\n', encoding='utf-8')
        sh(self.repo, 'commit', '-q', '-am', 'later')
        changed = changed_files(self.repo, self.base)
        self.assertEqual(changed, {'中文/乙.dart'})
        fresh, stale = split_fresh(['中文/乙.dart', 'a.dart'], changed)
        self.assertEqual((fresh, stale), (['a.dart'], ['中文/乙.dart']))
        hits = live_grep(self.repo, 'freshIdent', sorted(changed))
        self.assertEqual([(f, l) for f, l, _ in hits], [('中文/乙.dart', 2)])


class RustHoverTest(unittest.TestCase):
    def test_function_with_module_container(self) -> None:
        hover = '```rust\nfushi_fsrs::anki_import_rules\n```\n\n```rust\npub fn anki_source_hlc(origin: &str) -> Option<String>\n```'
        self.assertEqual(build.rust_kind(hover), ('fn', 'anki_import_rules'))

    def test_struct_field_without_keyword(self) -> None:
        hover = '```rust\nfushi_fsrs::store::Card\n```\n\n```rust\npub due: i64\n```'
        self.assertEqual(build.rust_kind(hover), ('field', 'Card'))

    def test_local_variable_is_skipped(self) -> None:
        self.assertIsNone(build.rust_kind('```rust\nlet x: i32\n```'))


class QueryTest(unittest.TestCase):
    def test_defs_and_refs_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            db: Path = Path(td) / 'i.sqlite'
            con = sqlite3.connect(db)
            con.executescript(build.SCHEMA)
            ld = build.Loader(con)
            sid = ld.add_sym('Foo', 'class', '', 'a.dart', 1, 'dart')
            ld.add_sym('Foo', 'method', 'Bar', 'c.dart', 3, 'dart')
            ld.add_refs([(sid, 'b.dart', 1), (sid, 'b.dart', 1), (sid, 'b.dart', 2)])
            con.executescript(build.INDEXES)
            con.execute("INSERT INTO meta VALUES ('base_sha', 'x')")
            con.commit()
            con.close()
            ix = Index(db)
            self.assertEqual([(s.file, s.kind) for s in ix.defs('Foo')], [('a.dart', 'class'), ('c.dart', 'method')])
            self.assertEqual([s.file for s in ix.defs('Foo', container='Bar')], ['c.dart'])
            self.assertEqual([(h.file, h.line) for h in ix.refs(sid)], [('b.dart', 1), ('b.dart', 2)])
            self.assertEqual(ix.meta('base_sha'), 'x')
            self.assertEqual([s.file for s in ix.find('fo', 1)], ['a.dart'])
            ix.close()


class RustFailureTest(unittest.TestCase):
    """HBK-AUDIT-018：某个 crate 的 rust-analyzer lsif 失败时，索引不得声称对这个提交已是最新。"""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo: Path = Path(self.tmp.name) / 'repo'
        self.repo.mkdir()
        sh(self.repo, 'init', '-q')
        sh(self.repo, 'config', 'user.email', 't@example.com')
        sh(self.repo, 'config', 'user.name', 't')
        crate: Path = self.repo / 'native' / 'fushi_x'
        (crate / 'src').mkdir(parents=True)
        (crate / 'Cargo.toml').write_text('[package]\nname = "fushi_x"\n', encoding='utf-8')
        (crate / 'src' / 'lib.rs').write_text('pub fn only_in_rust() {}\n', encoding='utf-8')
        sh(self.repo, 'add', '.')
        sh(self.repo, 'commit', '-q', '-m', 'base')
        self.head: str = sh(self.repo, 'rev-parse', 'HEAD')
        self.db: Path = Path(self.tmp.name) / 'index.sqlite'
        self.saved: str = build.RUST_ANALYZER
        # 用 python 冒充 rust-analyzer：`python lsif <crate>` 打不开脚本 lsif，退出码 2，等同 lsif 子进程失败
        build.RUST_ANALYZER = sys.executable

    def tearDown(self) -> None:
        build.RUST_ANALYZER = self.saved
        self.tmp.cleanup()

    def test_failed_crate_is_recorded_and_index_is_not_current(self) -> None:
        with self.assertRaises(SystemExit) as cm:
            build.build(self.repo, self.db, skip_dart=True, skip_rust=False)
        self.assertNotEqual(cm.exception.code, 0)
        self.assertFalse(build.is_current(self.db, self.head))
        ix = Index(self.db)
        try:
            self.assertEqual(ix.meta('base_sha'), self.head)
            self.assertEqual(ix.incomplete_dirs(), ['native/fushi_x'])
        finally:
            ix.close()
        # 查询端把没收全的 crate 整体当改动文件：索引结果不当真，改走实时搜索
        self.assertEqual(files_under(self.repo, ['native/fushi_x']), {'native/fushi_x/Cargo.toml', 'native/fushi_x/src/lib.rs'})
        env: dict[str, str] = {**os.environ, 'FUSHI_SYMINDEX_DB': str(self.db)}
        out: str = subprocess.run([sys.executable, str(HERE / 'sym.py'), 'def', 'only_in_rust'], cwd=self.repo, env=env,
                                  capture_output=True, text=True, encoding='utf-8', check=True).stdout
        self.assertIn('索引未收全：native/fushi_x', out)
        self.assertIn('native/fushi_x/src/lib.rs:1  pub fn only_in_rust() {}', out)

    def test_complete_build_is_current(self) -> None:
        build.build(self.repo, self.db, skip_dart=True, skip_rust=True)
        self.assertTrue(build.is_current(self.db, self.head))
        ix = Index(self.db)
        try:
            self.assertEqual(ix.incomplete_dirs(), [])
        finally:
            ix.close()


class CjkRepoRootTest(unittest.TestCase):
    """仓库根路径含中文：build.py / sym.py 读 git rev-parse 输出须按 UTF-8 解码（Windows 默认 cp936 会解码失败崩掉）。"""

    def test_build_and_query_in_cjk_repo_root(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo: Path = Path(td) / '中文仓库'
            repo.mkdir()
            sh(repo, 'init', '-q')
            sh(repo, 'config', 'user.email', 't@example.com')
            sh(repo, 'config', 'user.name', 't')
            (repo / 'a.dart').write_text('class Foo {}\n', encoding='utf-8')
            sh(repo, 'add', '.')
            sh(repo, 'commit', '-q', '-m', 'base')
            db: Path = Path(td) / 'index.sqlite'
            env: dict[str, str] = {**os.environ, 'FUSHI_SYMINDEX_DB': str(db)}
            subprocess.run([sys.executable, str(HERE / 'build.py'), '--repo', str(repo), '--skip-dart', '--skip-rust'],
                           env=env, capture_output=True, check=True)
            self.assertTrue(build.is_current(db, sh(repo, 'rev-parse', 'HEAD')))
            (repo / 'a.dart').write_text('class Foo {}\nvoid liveOne() {}\n', encoding='utf-8')
            out: str = subprocess.run([sys.executable, str(HERE / 'sym.py'), 'def', 'liveOne'], cwd=repo, env=env,
                                      capture_output=True, text=True, encoding='utf-8', check=True).stdout
            self.assertIn('a.dart:2  void liveOne() {}', out)


class WorkspaceTest(unittest.TestCase):
    def test_reads_workspace_members_that_exist(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            (repo / 'pubspec.yaml').write_text('name: w\nworkspace:\n  - app\n  # c\n  - packages/gone\nenvironment:\n  sdk: x\n', encoding='utf-8')
            (repo / 'app').mkdir()
            (repo / 'app' / 'pubspec.yaml').write_text('name: app\n', encoding='utf-8')
            self.assertEqual(build.workspace_packages(repo), ['app'])


if __name__ == '__main__':
    unittest.main(verbosity=1)
