// 服务端复习库换代的端到端（G10-3）：真原生库、真协议 3 `srs.db`（两个 profile，其一只在投影表里），服务端启动后
// 自动无头迁移、提交、开库；之前被杀留下的半成品不挡续做；迁完后重启直接开新代库、不再迁移。
//
// 夹具 fixtures/srs_protocol3_two_profiles.db.gz：协议 3（schema 29）的库，生成器源码在同目录的
// srs_protocol3_two_profiles_generator.rs.txt（贴进 native/fushi_fsrs/src/store/gen4/prepare_tests.rs 末尾跑）。
import 'dart:io';

import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_server/src/server_srs.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsReviewLog;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_rwkv.dart';

/// 夹具里有笔记与复习的 profile（native 测试常量 `P`）。
const String kMain = '0193a1b2-0000-7000-8000-00000000beef';

/// 夹具里只在协议 3 投影表里的 profile（一副牌组、一条旧复习日志）。
const String kOrphan = '0193a1b2-0000-7000-8000-00000000cafe';

/// 孤儿 profile 那条旧复习日志所在的卡（生成器里 `legacy_log(..., ORPHAN, ..., "…c9", ...)`）。
const String kOrphanLoggedCard = '0193a1b2-0000-7000-8000-0000000000c9';

void main() {
  late Directory tmp;
  late Directory support;
  late ServerSrs srs;
  const ServerSrsConfig config = ServerSrsConfig(
    profiles: <String>[kMain, kOrphan],
  );

  ServerSrs make() => ServerSrs(
    rwkvHttpClient: noNetworkHttpClient,
    support: support,
    syncData: Directory(p.join(tmp.path, 'interconnect'))
      ..createSync(recursive: true),
    deviceId: 'server-device',
    hostId: 'server-srs-migration-e2e',
    config: () => config,
    engine: () => null,
    migrationPollInterval: const Duration(milliseconds: 20),
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_srs_e2e_');
    support = Directory(p.join(tmp.path, 'support'))..createSync();
    final List<int> db = gzip.decode(
      File(
        p.join('test', 'fixtures', 'srs_protocol3_two_profiles.db.gz'),
      ).readAsBytesSync(),
    );
    File(SrsStorage.legacyPathIn(support.path)).writeAsBytesSync(db);
    srs = make();
  });

  tearDown(() async {
    await srs.stop();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  test('协议 3 库目录：启动自动迁移并提交，迁完的库可用；重启不再迁移', () async {
    // 上一个进程迁到一半被杀：留下的迁移临时库与前提补完副本（内容是坏的）。内核取锁后先清掉，从头重来。
    File(
      p.join(support.path, 'srs4.db-migrating'),
    ).writeAsStringSync('left by a killed run');
    File(
      p.join(support.path, 'srs.db-gen4-prepare'),
    ).writeAsStringSync('left by a killed run');
    final List<int> legacyBefore = File(
      SrsStorage.legacyPathIn(support.path),
    ).readAsBytesSync();
    expect(legacyBefore, isNotEmpty);

    await srs.start();
    // 迁移在后台跑：start 已返回，等结论。
    for (int i = 0; i < 1500 && srs.migrationRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(srs.migrationRunning, isFalse);
    await srs.applyConfig();
    final ServerSrsGeneration gen = srs.generation;
    expect(gen.state, ServerSrsGenState.ready, reason: '${gen.toJson()}');
    expect(gen.verdict, 'committed');
    expect(srs.upgradeRefusal, isNull);
    expect(File(SrsStorage.gen4PathIn(support.path)).existsSync(), isTrue);
    // 旧库原位封存、不删。
    expect(File(SrsStorage.legacyPathIn(support.path)).existsSync(), isTrue);
    expect(
      File(p.join(support.path, 'srs.db-gen4-prepare')).existsSync(),
      isFalse,
    );
    for (final String uid in <String>[kMain, kOrphan]) {
      expect(
        srs.profile(uid)!.state,
        isNot(
          anyOf(
            ServerSrsProfileState.upgrading,
            ServerSrsProfileState.upgradeBlocked,
            ServerSrsProfileState.failed,
          ),
        ),
        reason: '$uid: ${srs.profile(uid)!.lastError}',
      );
    }
    await srs.stop();

    // 迁完的新代库：卡片与复习记录都在（另开一份句柄读，服务端已停）。
    final SrsStorage storage = await SrsStorage.open(directory: support.path);
    addTearDown(storage.close);
    final SrsDbStore main = await SrsDbStore.open(
      core: storage.core,
      profileUid: kMain,
      deviceId: 'check',
    );
    expect(await main.userNoteCount(), 3);
    // 复习记录：一条本机复习（r1）+ 一条协议 1 时代的旧日志，迁移后都还在。
    final List<String> mainCards = <String>[
      for (final SrsCardCacheRow c in await main.allCardRows()) c.id,
    ];
    final Map<String, List<SrsReviewLog>> mainLogs = await main.logsOfCards(
      mainCards,
    );
    expect(
      mainLogs.values.fold<int>(
        0,
        (int n, List<SrsReviewLog> l) => n + l.length,
      ),
      2,
      reason: '$mainLogs',
    );
    // 只在投影表里的那份（孤儿 uid）：牌组与它那条旧日志也迁过来了。
    final SrsDbStore orphan = await SrsDbStore.open(
      core: storage.core,
      profileUid: kOrphan,
      deviceId: 'check',
    );
    expect((await orphan.deckTree()).decks, isNotEmpty);
    final Map<String, List<SrsReviewLog>> orphanLogs = await orphan.logsOfCards(
      <String>[kOrphanLoggedCard],
    );
    expect(orphanLogs[kOrphanLoggedCard], hasLength(1), reason: '$orphanLogs');
    await storage.close();

    // 重启：目录已是新代，直接开库、不迁移。
    srs = make();
    await srs.start();
    expect(srs.migrationRunning, isFalse);
    expect(srs.generation.state, ServerSrsGenState.ready);
    expect(srs.generation.verdict, isNull, reason: '这个进程没跑过迁移');
    expect(srs.profile(kMain)!.state, isNot(ServerSrsProfileState.failed));
  });
}
