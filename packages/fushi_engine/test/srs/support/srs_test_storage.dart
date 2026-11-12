import 'dart:io';

import 'package:drift/drift.dart' show QueryRow;
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, kLegacySrsTableDdl;
import 'package:fushi_engine/srs/srs_core_workers.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart'
    show SrsCore, SrsEntityKind, SrsNoteView;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 在临时目录里建一份 srs.db（磁盘文件，WAL；Rust 独占连接）。
/// 注册 [addTearDown]：关闭存储后删目录，删除失败（Windows 句柄滞后）吞掉。
Future<SrsStorage> openTestSrsStorage() async {
  final Directory dir = Directory.systemTemp.createTempSync('srs_test_db_');
  final SrsStorage storage = await SrsStorage.open(
    path: p.join(dir.path, kSrsDatabaseFileName),
  );
  addTearDown(() async {
    await storage.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄尚未释放；临时目录留给系统清理。
    }
  });
  return storage;
}

/// 打开的 srs.db（关闭由 [openTestSrsAt] 注册）。
///
/// srs.db 的读只有内核读命令（`srsRead` / [SrsDbStore] 的读方法）；测试要直接看表时用 [SrsCore.debugSelectRaw]
/// （测试专用的原始通道：ID 参数写 `srs_id(?)`，表达式列套 `srs_idt(...)`，直接选出的 ID 列已还原成文本）。
typedef TestSrs = ({SrsCore core});

/// 在 [path] 上直接打开 srs.db（Rust 独占连接）。读命令照常在内核命令 worker 的查询道上跑（与 app 相同）。
/// 注册清理：关 Rust 连接；不删文件（调用方管目录）。
Future<TestSrs> openTestSrsAt(String path) async {
  final SrsCore core = SrsCore.open(path);
  SrsCoreWorkers.of(core.libraryPath).setQueryConcurrency(core.readConcurrency);
  addTearDown(core.close);
  return (core: core);
}

/// 模拟 2026-10-23 之前的老形态：在 [legacy]（主库形态的 FushiDatabase）上用旧表定义建出 9 张
/// srs_* 表，再把 [from]（srs.db）里的行原样抄进去（经测试通道读）。只抄老表有的列：srs.db 之后加的列
/// （schema v4 的 `srs_notes_cache.media_refs` 等）老形态里本来就没有。
Future<void> copySrsRowsToLegacyTables(
  SrsCore from,
  FushiDatabase legacy,
) async {
  for (final MapEntry<String, String> t in kLegacySrsTableDdl.entries) {
    await legacy.customStatement(t.value);
    final Set<String> legacyCols = <String>{
      for (final QueryRow c
          in await legacy.customSelect('PRAGMA table_info(${t.key})').get())
        c.read<String>('name'),
    };
    for (final Map<String, Object?> r in from.debugSelectRaw(
      'SELECT * FROM ${t.key}',
    )) {
      final List<String> cols = <String>[
        for (final String c in r.keys)
          if (legacyCols.contains(c)) c,
      ];
      await legacy.customStatement(
        'INSERT INTO ${t.key} (${cols.join(', ')}) '
        'VALUES (${List<String>.filled(cols.length, '?').join(', ')})',
        <Object?>[for (final String c in cols) r[c]],
      );
    }
  }
}

/// [s] 的 profile 里有身份记录的全部笔记（含已删除），按 id 分块物化。只给测试用：生产代码没有整库物化
/// 笔记的入口（AnkiConnect / 统计 / 浏览都走原生命令）。
Future<List<SrsNoteView>> allNotesOf(SrsDbStore s) async {
  final List<String> ids = (await s.readTable('entities', <String, Object?>{
    'kind': SrsEntityKind.note.wire,
    'bare': true,
  })).strings('id').toList();
  return <SrsNoteView>[
    for (final SrsNoteView? n in (await s.notes(ids)).values) ?n,
  ];
}
