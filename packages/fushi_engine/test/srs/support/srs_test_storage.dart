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

/// 打开的 srs.db（关闭由 [openTestSrsAt] 注册）。
///
/// srs.db 的读只有内核读命令（`srsRead` / [SrsDbStore] 的读方法）；测试要直接看表时用 [SrsCore.debugSelectRaw]
/// （测试专用的原始通道：ID 参数写 `srs_id(?)`，表达式列套 `srs_idt(...)`，直接选出的 ID 列已还原成文本）。
typedef TestSrs = ({SrsCore core});

/// 在 [path] 上直接打开复习库（Rust 独占连接）。读命令照常在内核命令 worker 的查询道上跑（与 app 相同）。
/// 注册清理：关 Rust 连接；不删文件（调用方管目录）。
///
/// 新代的 [SrsCore.open] 收的是**库目录**（里面放 `srs.gen.lock` / 代际文件），不是单个 `.db` 文件；调用方沿用
/// 旧写法传 `<tmp>/srs.db` 时，这里把它当成目录建出来（同一路径重开仍落到同一个库，不同文件名仍是不同的库）。
Future<TestSrs> openTestSrsAt(String path) async {
  // 已是文件（调用方抄进来的协议 3 夹具库）就不动：那类用例本身已过时，让它照实失败。
  if (!File(path).existsSync()) Directory(path).createSync(recursive: true);
  final SrsCore core = SrsCore.open(path);
  SrsCoreWorkers.of(core.libraryPath).setQueryConcurrency(core.readConcurrency);
  addTearDown(core.close);
  return (core: core);
}

/// 新建一个临时**库目录**（新代 [SrsCore.open] 收目录；里面放 `srs.gen.lock`、新代库 `srs4.db`、封存旧库 `srs.db`）。
/// 注册清理：删目录（Windows 句柄滞后删不掉时留给系统）。清理按注册的倒序跑，先注册目录、后开库，关库就在删目录之前。
Directory newTestSrsDir([String prefix = 'srs_test_']) {
  final Directory dir = Directory.systemTemp.createTempSync(prefix);
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
}) async {
  final Directory dir = newTestSrsDir(prefix);
  File(
    '${dir.path}${Platform.pathSeparator}srs.db',
  ).writeAsBytesSync(legacyBytes);
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
        'migrating the frozen protocol 3 fixture: ${out.code} ${out.reason}',
  );
  return openTestSrsIn(dir.path);
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
