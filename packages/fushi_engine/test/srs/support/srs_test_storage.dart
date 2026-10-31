import 'dart:io';

import 'package:drift/drift.dart'
    show
        ApplyInterceptor,
        ApplyInterceptorConnection,
        BooleanExpressionOperators,
        DatabaseConnection,
        QueryExecutor,
        QueryInterceptor,
        QueryRow;
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, SrsDatabase, kLegacySrsTableDdl;
import 'package:fushi_engine/srs/srs_database_executor.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart'
    show SrsCore, SrsEntityKind, SrsNoteView;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 在临时目录里建一份 srs.db（磁盘文件，WAL；Rust 独占连接），Drift 执行器跑在当前 isolate。
/// 注册 [addTearDown]：关闭存储后删目录，删除失败（Windows 句柄滞后）吞掉。
Future<SrsStorage> openTestSrsStorage() async {
  final Directory dir = Directory.systemTemp.createTempSync('srs_test_db_');
  final SrsStorage storage = await SrsStorage.open(
    path: p.join(dir.path, kSrsDatabaseFileName),
    inline: true,
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

/// 打开的 srs.db 视图（带可选语句拦截器的用例用；关闭由 [openTestSrsAt] 注册）。
typedef TestSrs = ({SrsDatabase db, SrsCore core});

/// 在 [path] 上直接打开 srs.db（Rust 独占连接 + 同 isolate 的 Drift 执行器）。
/// [inline] 为 false 时走后台 isolate（与 app 相同）。[interceptor] 非空时包在 Drift 执行器外面，用来数语句往返。
/// 注册清理：先关 Drift 再关 Rust 连接；不删文件（调用方管目录）。
Future<TestSrs> openTestSrsAt(
  String path, {
  QueryInterceptor? interceptor,
  bool inline = true,
}) async {
  final SrsCore core = SrsCore.open(path);
  final SrsDatabase db;
  if (inline) {
    QueryExecutor executor = srsInlineExecutor(core);
    if (interceptor != null) executor = executor.interceptWith(interceptor);
    db = SrsDatabase(executor);
  } else {
    // 与 app 同一种连接：语句跨 isolate 往返。
    DatabaseConnection conn = srsDatabaseConnection(core);
    if (interceptor != null) conn = conn.interceptWith(interceptor);
    db = SrsDatabase(conn);
  }
  addTearDown(() async {
    await db.close();
    core.close();
  });
  return (db: db, core: core);
}

/// 模拟 2026-10-23 之前的老形态：在 [legacy]（主库形态的 FushiDatabase）上用旧表定义建出 9 张
/// srs_* 表，再把 [from]（srs.db 视图）里的行原样抄进去。只抄老表有的列：srs.db 之后加的列
/// （schema v4 的 `srs_notes_cache.media_refs` 等）老形态里本来就没有。
Future<void> copySrsRowsToLegacyTables(
  SrsDatabase from,
  FushiDatabase legacy,
) async {
  for (final MapEntry<String, String> t in kLegacySrsTableDdl.entries) {
    await legacy.customStatement(t.value);
    final Set<String> legacyCols = <String>{
      for (final QueryRow c
          in await legacy.customSelect('PRAGMA table_info(${t.key})').get())
        c.read<String>('name'),
    };
    for (final QueryRow r
        in await from.customSelect('SELECT * FROM ${t.key}').get()) {
      final List<String> cols = <String>[
        for (final String c in r.data.keys)
          if (legacyCols.contains(c)) c,
      ];
      await legacy.customStatement(
        'INSERT INTO ${t.key} (${cols.join(', ')}) '
        'VALUES (${List<String>.filled(cols.length, '?').join(', ')})',
        <Object?>[for (final String c in cols) r.data[c]],
      );
    }
  }
}

/// [s] 的 profile 里有身份记录的全部笔记（含已删除），按 id 分块物化。只给测试用：生产代码没有整库物化
/// 笔记的入口（AnkiConnect / 统计 / 浏览都走原生命令）。
Future<List<SrsNoteView>> allNotesOf(SrsDbStore s) async {
  final List<String> ids = <String>[
    for (final r
        in await (s.db.select(s.db.srsEntities)..where(
              (t) =>
                  t.profileUid.equals(s.profileUid) &
                  t.kind.equals(SrsEntityKind.note.wire),
            ))
            .get())
      r.id,
  ];
  return <SrsNoteView>[
    for (final SrsNoteView? n in (await s.notes(ids)).values) ?n,
  ];
}
