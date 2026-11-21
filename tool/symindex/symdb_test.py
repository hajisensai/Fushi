"""tool/symindex 的单元测试：改动文件判定（自动降级的依据）、实时整词搜索、Rust hover 解析、查询。

  python3 tool/symindex/symdb_test.py
"""
from __future__ import annotations

import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE: Path = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build  # noqa: E402
from symdb import Index, changed_files, live_grep, split_fresh  # noqa: E402


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
