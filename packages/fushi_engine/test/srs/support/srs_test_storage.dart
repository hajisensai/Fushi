import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow;
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, kLegacySrsTableDdl;
import 'package:fushi_engine/srs/srs_core_workers.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart'
    show
        SrsCore,
        SrsEntityKind,
        SrsGen4Migration,
        SrsGen4MigrationOutcome,
        SrsGen4MigrationVerdict,
        SrsNoteView,
        SrsOpenMode;
import 'package:test/test.dart';

/// 在临时目录里建一份 srs.db（磁盘文件，WAL；Rust 独占连接）。
/// 注册 [addTearDown]：关闭存储后删目录，删除失败（Windows 句柄滞后）吞掉。
Future<SrsStorage> openTestSrsStorage() async {
  final Directory dir = Directory.systemTemp.createTempSync('srs_test_db_');
  final SrsStorage storage = await SrsStorage.open(directory: dir.path);
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

/// 打开的复习库（关闭由 [openTestSrsIn] 注册）。
///
/// 读只有内核读命令（`srsRead` / [SrsDbStore] 的读方法）；测试要直接看表时用 [SrsCore.debugSelectRaw]
/// （测试专用的原始通道：ID 参数写 `srs_id(?)`，表达式列套 `srs_idt(...)`，直接选出的 ID 列已还原成文本）。
typedef TestSrs = ({SrsCore core});

/// [parent] 下名为 [name] 的子库目录（同一个临时目录里要开几个互不相干的库时用；清理跟着 [parent]）。
String testSrsSubdir(Directory parent, String name) {
  final Directory d = Directory('${parent.path}${Platform.pathSeparator}$name')
    ..createSync(recursive: true);
  return d.path;
}

/// 新建一个临时**库目录**（新代 [SrsCore.open] 收目录；里面放 `srs.gen.lock`、新代库 `srs4.db`、封存旧库 `srs.db`）。
/// 注册清理：删目录（Windows 句柄滞后删不掉时留给系统）。清理按注册的倒序跑，先注册目录、后开库，关库就在删目录之前。
Directory newTestSrsDir([String prefix = 'srs_test_', String? root]) {
  final Directory dir = (root == null ? Directory.systemTemp : Directory(root))
      .createTempSync(prefix);
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄晚释放；临时目录留给系统清理。
    }
  });
  return dir;
}

/// 在库目录 [dir] 上打开新代复习库（[SrsCore.open]，缺省主进程 Primary；同一目录重开落到同一个库）。注册清理：关库。
///
/// 只拿 [SrsCore] 发命令（不经 [SrsDbStore]）的测试，第一条按集合的命令之前要先 [bindTestProfile]；经
/// [SrsDbStore.open] 打开的不用（它自己先取身份、再登记缓存配置）。
TestSrs openTestSrsIn(String dir, {SrsOpenMode mode = SrsOpenMode.primary}) {
  final SrsCore core = SrsCore.open(dir, mode: mode);
  SrsCoreWorkers.of(core.libraryPath).setQueryConcurrency(core.readConcurrency);
  addTearDown(core.close);
  return (core: core);
}

/// 新代开库的前两步，给只用 [SrsCore] 的测试：`identity`（主进程上没有就建集合、绑定与本机身份——新代里每条按
/// profile 的命令都要绑定，没绑定报 [SrsProfileUnboundException]）+ `cache_config_set`（派生层要的默认牌组 / 内置
/// 笔记类型默认值，[srsCacheConfigFor]）。与 [SrsDbStore.open] 同一顺序。返回 identity 回包（`device` / `collection` / `dir`）。
Map<String, Object?> bindTestProfile(
  SrsCore core,
  String profileUid, {
  int? nowMs,
}) {
  final Map<String, Object?> id = core.sync2(<String, Object?>{
    'op': 'identity',
    'profile': profileUid,
    'now': nowMs ?? DateTime.now().millisecondsSinceEpoch,
  }).map;
  core.sync2(<String, Object?>{
    'op': 'cache_config_set',
    'profile': profileUid,
    'caches': srsCacheConfigFor(profileUid),
    'now': nowMs ?? DateTime.now().millisecondsSinceEpoch,
  });
  return id;
}

/// 把一份协议 3 的旧库文件（冻结夹具，[legacyBytes]）放进新库目录当封存旧库 `srs.db`，跑一次换代迁移
/// （[SrsGen4Migration.run]，缓存配置按旧库里每个 profile 给 [srsCacheConfigFor]），断言提交，再打开新代库。
/// 这是用户升级时走的同一条路：协议 3 时代冻结下来的向量库，迁移之后用新代的读命令再对一遍。
Future<TestSrs> openMigratedTestSrs(
  List<int> legacyBytes, {
  String prefix = 'srs_migrated_',
  int? nowMs,
}) {
  final Directory dir = newTestSrsDir(prefix);
  File(
    '${dir.path}${Platform.pathSeparator}srs.db',
  ).writeAsBytesSync(legacyBytes);
  return _migrateAndOpen(dir, nowMs);
}

/// 真实数据基准用，一律在副本上跑（不动 [source]）：[source] 是新代**库目录**就把其中的文件拷进临时库目录再开；
/// 是一份协议 3 的 `srs.db` 文件（旧版 app 的复习库）就拷进临时库目录当封存旧库，走换代迁移
/// （[openMigratedTestSrs] 同一条路）再打开——新代的 [SrsCore.open] 不收单个 `.db` 文件。[tmpRoot] 给大库指定
/// 临时目录所在的盘（缺省系统临时目录）。
Future<TestSrs> openRealDataTestSrs(
  String source, {
  String? tmpRoot,
  int? nowMs,
}) {
  final Directory dir = newTestSrsDir('srs_real_data_', tmpRoot);
  if (Directory(source).existsSync()) {
    copyTestSrsLibrary(source, dir.path);
    return Future<TestSrs>.value(openTestSrsIn(dir.path));
  }
  File(source).copySync('${dir.path}${Platform.pathSeparator}srs.db');
  return _migrateAndOpen(dir, nowMs);
}

/// 把新代库目录 [from] 里的文件（代际锁、`srs4.db` 与它的 WAL 等）拷进 [to]（库目录是平的，不含子目录）。
void copyTestSrsLibrary(String from, String to) {
  for (final FileSystemEntity e in Directory(from).listSync()) {
    if (e is File) {
      e.copySync('$to${Platform.pathSeparator}${e.uri.pathSegments.last}');
    }
  }
}

Future<TestSrs> _migrateAndOpen(Directory dir, int? nowMs) async {
  final List<String> uids = await SrsGen4Migration.legacyProfiles(dir.path);
  final SrsGen4MigrationOutcome out = await SrsGen4Migration.run(
    dir.path,
    caches: <String, Map<String, Object?>>{
      for (final String u in uids) u: srsCacheConfigFor(u),
    },
    nowMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
  );
  expect(
    out.verdict,
    SrsGen4MigrationVerdict.committed,
    reason:
        'migrating the frozen protocol 3 fixture: ${out.code} ${out.reason} '
        '${out.reportPath} ${jsonEncode(out.report)}',
  );
  return openTestSrsIn(dir.path);
}

/// 派生表 [table]（新代的 `notes` / `cards` / `stats`）的全部行，经测试原始通道读、按行内容排序（与行序无关）。
List<String> derivedTableRows(SrsCore core, String table) {
  final List<String> rows = <String>[
    for (final Map<String, Object?> r in core.debugSelectRaw(
      'SELECT * FROM $table',
    ))
      jsonEncode(r, toEncodable: (Object? v) => v.toString()),
  ]..sort();
  return rows;
}

/// 锁住「整层重建真的按真相重算派生层」：先记下 [table] 的全部行，再经原始通道执行 [damage]（改坏 / 删掉派生行，
/// 必须真改到行），确认表已不同，然后 [SrsDbStore.rebuildCaches]，断言表逐行复原。
///
/// 只比「重建前后某个读命令同值」测不出重建坏掉（重建什么都不做也同值）；派生层没有公开写命令，改坏它只能走原始
/// 通道。返回重建前的行，调用方可再比公开读命令。
Future<List<String>> expectRebuildRestores(
  SrsDbStore s,
  String table,
  String damage,
) async {
  final List<String> before = derivedTableRows(s.core, table);
  expect(before, isNotEmpty, reason: '$table has no rows to damage');
  s.core.debugExecRaw(damage);
  expect(
    derivedTableRows(s.core, table),
    isNot(before),
    reason: 'damage did not change $table: $damage',
  );
  await s.rebuildCaches();
  expect(
    derivedTableRows(s.core, table),
    before,
    reason:
        'rebuild_caches must recompute $table from the truth after: $damage',
  );
  return before;
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
