// SRS 事件库归 Rust 的 srs.db（docs/specs/2026-10-23-srs-rust-store.md §1 / §6）：
//
// 1. 9 张 srs_* 表名只许出现在 SRS 子系统与搬迁 / 老形态兼容代码里——app 其它地方直接写 SQL 碰
//    它们，就是绕过 SrsDatabase / Rust 连接去读写主库（表已不在那里），或者把 Dart 的 SQLite
//    接到了 srs.db 上（POSIX 上两份 SQLite 同开一个文件会互相清掉文件锁）。
// 2. 主库的 Drift 声明（tables.dart / @DriftDatabase 清单）不得再声明 Srs* 表。
// 3. Rust 源码（代码，不算注释）不得出现 `fushi.db`：Rust 绝不打开主库。
//
// 新增白名单条目要说明它为什么必须直接碰表名。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';

/// srs.db 的 SRS 表：9 张老表（与 fushi_core `kLegacySrsTableDdl` 的键相同）+ srs.db 自己的有效复习投影。
const List<String> _kSrsTables = <String>[
  'srs_entities',
  'srs_field_edits',
  'srs_review_logs',
  'srs_unknown_events',
  'srs_event_local',
  'srs_local_state',
  'srs_sent_batches',
  'srs_notes_cache',
  'srs_cards_cache',
  'srs_stat_reviews',
];

/// 允许写 SRS 表名的文件（相对仓库根，`/` 分隔）→ 理由。
const Map<String, String> _kAllowed = <String, String>{
  // SrsDatabase 的表声明与生成代码（查询构造器；语句在 Rust 的连接上执行）。
  'packages/fushi_core/lib/src/database/srs_tables.dart': 'SrsDatabase 表声明',
  'packages/fushi_core/lib/src/database/srs_database.g.dart': '生成代码',
  // 主库迁移阶梯：老库仍按当年的形状建出旧表（kLegacySrsTableDdl），供一次性搬迁。
  'packages/fushi_core/lib/src/database/database.dart': '迁移阶梯',
  'packages/fushi_core/lib/src/database/database_srs.part.dart': '老表 DDL / 索引',
  // SRS 子系统本体（SQL 跑在 srs.db 的 Rust 连接上）与一次性搬迁。
  'packages/fushi_engine/lib/srs/srs_db_store.dart': 'SRS 存储',
  'packages/fushi_engine/lib/srs/srs_legacy_store_migration.dart': '一次性搬迁',
  'packages/fushi_engine/lib/srs/srs_backup_merge.dart': '备份合并（新老两种来源）',
  // 同步关联：本机 profile 并入所选 profile（改写后经 Rust 合并路径落库，SQL 跑在 srs.db 的连接上）。
  'packages/fushi_engine/lib/srs/srs_profile_merge.dart': 'profile 并入',
  'packages/fushi_engine/lib/srs/srs_legacy_lapis_migration.dart': 'SRS 子系统',
  'packages/fushi_engine/lib/srs/srs_stats.dart': 'SRS 子系统',
  'packages/fushi_engine/lib/srs/srs_backup_snapshot.dart':
      'SRS 备份读快照（Rust 只读会话上）',
  'packages/fushi_engine/lib/srs/srs_note_type_store.dart': 'SRS 子系统',
  // 重复笔记建议：按笔记缓存的词形键 / 读音键分组（SrsDbStore 扩展，SQL 跑在 srs.db 的连接上）。
  'packages/fushi_engine/lib/srs/srs_duplicate_notes.dart': 'SRS 子系统',
  // 通用备份里老形态（SRS 表还在主库 / 老备份主库条目里）的唯一处置点。
  'fushi/lib/src/sync/backup_srs_tables.dart': '老形态备份兼容',
};

/// 仓库根（测试在 fushi/ 下跑）。
final Directory _repo = Directory.current.parent;

String _rel(File f) =>
    p.relative(f.path, from: _repo.path).replaceAll(r'\', '/');

Iterable<File> _dartFiles(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .where((File f) => f.path.endsWith('.dart'));

/// 掩掉 Rust 的注释（`//`、`///`、`//!`、`/* */` 与 Dart 同形，共用 [maskComments]）。
String _maskRustComments(String src) => maskComments(src);

void main() {
  final RegExp tableName = RegExp('\\b(${_kSrsTables.join('|')})\\b');

  test('srs_* 表名只出现在 SRS 子系统 / 搬迁 / 老形态兼容代码里', () {
    final List<Directory> roots = <Directory>[
      Directory(p.join(_repo.path, 'fushi', 'lib')),
      for (final FileSystemEntity e in Directory(
        p.join(_repo.path, 'packages'),
      ).listSync())
        if (e is Directory && Directory(p.join(e.path, 'lib')).existsSync())
          Directory(p.join(e.path, 'lib')),
    ];
    final List<String> offenders = <String>[];
    final Set<String> seenAllowed = <String>{};
    int scanned = 0;
    for (final Directory root in roots) {
      for (final File f in _dartFiles(root)) {
        scanned++;
        final String rel = _rel(f);
        final String src = f.readAsStringSync();
        if (!tableName.hasMatch(src)) continue;
        if (_kAllowed.containsKey(rel)) {
          seenAllowed.add(rel);
          continue;
        }
        final int line =
            '\n'
                .allMatches(src.substring(0, tableName.firstMatch(src)!.start))
                .length +
            1;
        offenders.add('$rel:$line');
      }
    }
    expect(scanned, greaterThan(1000), reason: '扫描面不对（cwd 应是 fushi/）');
    expect(offenders, isEmpty, reason: '这些文件直接写了 SRS 表名：$offenders');
    // 白名单不留死条目：文件删了 / 不再碰表名时一并删掉，免得把后来者的绕行合法化。
    expect(
      _kAllowed.keys.toSet().difference(seenAllowed),
      isEmpty,
      reason: '白名单里有已不碰 SRS 表名的文件',
    );
  });

  test('SRS 子系统不用 Dart 的 sqlite3 开库（srs.db 只由 Rust 打开）', () {
    // apkg/ 打开的是 Anki 的 .anki2 / collection 文件（不是 srs.db），照常用 Dart 的 sqlite3。
    final Directory srs = Directory(
      p.join(_repo.path, 'packages', 'fushi_engine', 'lib', 'srs'),
    );
    final List<String> offenders = <String>[
      for (final File f in _dartFiles(srs))
        if (!_rel(f).contains('/srs/apkg/') &&
            maskComments(
              f.readAsStringSync(),
            ).contains("import 'package:sqlite3/"))
          _rel(f),
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          '要另开一条读 srs.db 的连接就用 SrsCore.beginRead（Rust 只读会话）：'
          '两份 SQLite 同开一个文件会在 POSIX 上互相清掉文件锁。$offenders',
    );
  });

  test('主库的 Drift 声明里没有 Srs* 表', () {
    final String tables = File(
      p.join(
        _repo.path,
        'packages',
        'fushi_core',
        'lib',
        'src',
        'database',
        'tables.dart',
      ),
    ).readAsStringSync();
    expect(
      RegExp(r'class\s+Srs\w*\s+extends\s+Table').hasMatch(tables),
      isFalse,
      reason: 'SRS 表归 srs.db（SrsDatabase / srs_tables.dart），不进主库 schema',
    );
    final String database = File(
      p.join(
        _repo.path,
        'packages',
        'fushi_core',
        'lib',
        'src',
        'database',
        'database.dart',
      ),
    ).readAsStringSync();
    final RegExpMatch? decl = RegExp(
      r'@DriftDatabase\(\s*tables:\s*\[([\s\S]*?)\]',
    ).firstMatch(database);
    expect(decl, isNotNull, reason: '找不到 FushiDatabase 的 @DriftDatabase 清单');
    expect(
      RegExp(r'\bSrs\w+').hasMatch(decl!.group(1)!),
      isFalse,
      reason: 'FushiDatabase 的 @DriftDatabase 清单不得包含 Srs* 表',
    );
  });

  test('Rust 的 fushi_fsrs 源码（不算注释）不出现 fushi.db', () {
    final Directory src = Directory(
      p.join(_repo.path, 'native', 'fushi_fsrs', 'src'),
    );
    final List<File> rust = src
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.rs'))
        .toList();
    expect(rust, isNotEmpty);
    final List<String> offenders = <String>[
      for (final File f in rust)
        if (_maskRustComments(f.readAsStringSync()).contains('fushi.db'))
          _rel(f),
    ];
    expect(offenders, isEmpty, reason: 'Rust 绝不打开主库：$offenders');
  });

  test('变异自检：守卫的匹配器确实认得出违规写法', () {
    expect(
      tableName.hasMatch("customSelect('SELECT * FROM srs_entities')"),
      isTrue,
    );
    expect(
      tableName.hasMatch('srs_entities_profile_kind'),
      isFalse,
      reason: '索引名不是表名',
    );
    expect(
      _maskRustComments(
        '/// opens fushi.db\nlet p = "fushi.db";',
      ).contains('fushi.db'),
      isTrue,
    );
    expect(
      _maskRustComments(
        '//! never fushi.db\n/* fushi.db */ let x = 1;',
      ).contains('fushi.db'),
      isFalse,
    );
  });
}
