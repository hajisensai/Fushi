// SRS 事件库归 Rust 的 srs.db（docs/specs/2026-10-23-srs-rust-store.md §1 / §6）：
//
// 1. srs_* 表名（代码，不算注释）只许出现在老形态兼容代码里：主库迁移阶梯、一次性搬迁、老形态备份——它们碰的
//    是 fushi.db 里的旧表。srs.db 的表结构与 SQL 只在内核里（native/fushi_fsrs/src/store/schema.rs、reads.rs）：
//    Dart 读 srs.db 只发读命令（packages/fushi_engine/lib/srs/srs_reads.dart），写只发内核命令。
// 2. Dart 侧没有 srs.db 的 SQL 句柄：srs.db 上的 Drift 视图（SrsDatabase / srsIdType / 执行器）已删，不许回来。
// 3. 主库的 Drift 声明（tables.dart / @DriftDatabase 清单）不得再声明 Srs* 表。
// 4. Rust 源码（代码，不算注释）不得出现 `fushi.db`：Rust 绝不打开主库。
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

/// 允许在代码里写 SRS 表名的文件（相对仓库根，`/` 分隔）→ 理由。都只碰 fushi.db 里老形态的旧表。
const Map<String, String> _kAllowed = <String, String>{
  // 主库迁移阶梯：老库仍按当年的形状建出旧表（kLegacySrsTableDdl），供一次性搬迁。
  'packages/fushi_core/lib/src/database/database.dart': '迁移阶梯',
  'packages/fushi_core/lib/src/database/database_srs.part.dart': '老表 DDL / 索引',
  // 一次性搬迁：从主库老表读出、经内核命令灌进 srs.db。
  'packages/fushi_engine/lib/srs/srs_legacy_store_migration.dart': '一次性搬迁',
  // 备份合并的老形态来源（SRS 表在备份主库里，ATTACH 进来读）。
  'packages/fushi_engine/lib/srs/srs_backup_merge.dart': '老形态备份来源',
  // 通用备份里老形态（SRS 表还在主库 / 老备份主库条目里）的唯一处置点。
  'fushi/lib/src/sync/backup_srs_tables.dart': '老形态备份兼容',
};

/// srs.db 的 Drift 视图与 Dart 侧 SQL 执行器的名字（已删；出现即回退）。
final RegExp _kSrsDbSqlHandle = RegExp(
  r'\b(SrsDatabase|srsIdType|SrsIdType|srsInlineExecutor|srsDatabaseConnection|'
  r'SrsInlineExecutor|SrsReadOnlyExecutor|kSrsReadOnlyExecutor|'
  r'kSrsNotSnapshotQuery|execQuery|snapshotQuery)\b|srs_database_executor\.dart',
);

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

  test('srs_* 表名只出现在老形态兼容代码里（srs.db 的 SQL 只在内核）', () {
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
        final String src = maskComments(f.readAsStringSync());
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

  test('Dart 侧没有 srs.db 的 SQL 句柄（Drift 视图 / 执行器已删）', () {
    final List<Directory> roots = <Directory>[
      Directory(p.join(_repo.path, 'fushi', 'lib')),
      for (final FileSystemEntity e in Directory(
        p.join(_repo.path, 'packages'),
      ).listSync())
        if (e is Directory && Directory(p.join(e.path, 'lib')).existsSync())
          Directory(p.join(e.path, 'lib')),
    ];
    final List<String> offenders = <String>[
      for (final Directory root in roots)
        for (final File f in _dartFiles(root))
          if (_kSrsDbSqlHandle.hasMatch(maskComments(f.readAsStringSync())))
            _rel(f),
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          'srs.db 的读走内核读命令（srs_reads.dart），写走内核命令；'
          '不许在 Dart 侧再接 SQL：$offenders',
    );
    expect(
      File(
        p.join(
          _repo.path,
          'packages',
          'fushi_engine',
          'lib',
          'srs',
          'srs_reads.dart',
        ),
      ).existsSync(),
      isTrue,
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
      reason: 'SRS 表归 srs.db（表结构只在内核 store/schema.rs），不进主库 schema',
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
      tableName.hasMatch(
        maskComments('/// reads srs_entities\nfinal int x = 1;'),
      ),
      isFalse,
      reason: '注释里提到表名不算',
    );
    expect(_kSrsDbSqlHandle.hasMatch('final SrsDatabase db;'), isTrue);
    expect(
      _kSrsDbSqlHandle.hasMatch("import 'srs_database_executor.dart';"),
      isTrue,
    );
    expect(_kSrsDbSqlHandle.hasMatch('SrsDatabaseFileName'), isFalse);
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
