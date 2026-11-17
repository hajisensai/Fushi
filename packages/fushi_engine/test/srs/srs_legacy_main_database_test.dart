// 主库 `fushi.db` 里残留的协议 1 SRS 表（2026-10-23 之前的形态，docs/specs/2026-10-23-srs-rust-store.md §3）。
//
// 新代没有把这些表搬进 SRS 库的入口：协议 3 的搬迁命令（`ffsrs_store_legacy_*`）与 Dart 的 `srsMigrateLegacyStore`
// 已随 G7-6 删掉。对用户最稳妥的行为由 [SrsStorage.open] 的 `legacy` 守卫给出：主库里还有协议 1 的表、而库目录里
// 从没有过 SRS 库时**明确拒绝**（[SrsLegacyMainDatabasePending]，app 给升级提示页），不建空库把那些卡片藏起来，
// 主库里的表一行不动。这里锁住这条守卫。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late FushiDatabase db;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    for (final String ddl in kLegacySrsTableDdl.values) {
      await db.customStatement(ddl);
    }
  });
  tearDown(() => db.close());

  Future<int> legacyEntities() async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM srs_entities').get())
          .single
          .read<int>('n');

  test('主库还有协议 1 的 SRS 表、库目录是空的：明确拒绝打开，不建空库，旧表一行不动', () async {
    await db.customStatement(
      'INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) '
      "VALUES ('e', 'p', 'deck', '{}', 0)",
    );
    final Directory dir = newTestSrsDir('srs_legacy_main_');
    expect(
      await srsLegacyMainDatabasePending(db: db, directory: dir.path),
      isTrue,
    );
    await expectLater(
      SrsStorage.open(directory: dir.path, legacy: db),
      throwsA(isA<SrsLegacyMainDatabasePending>()),
    );
    expect(
      File(SrsStorage.gen4PathIn(dir.path)).existsSync(),
      isFalse,
      reason: '建了空的新代库，下次打开就再也认不出这份没搬的数据',
    );
    expect(dir.listSync(), isEmpty);
    expect(await legacyEntities(), 1);
  });

  test('主库里没有协议 1 的表：照常打开（全新安装 / 旧版早已搬完删表）', () async {
    for (final String table in kLegacySrsTableDdl.keys) {
      await db.customStatement('DROP TABLE IF EXISTS $table');
    }
    final Directory dir = newTestSrsDir('srs_legacy_main_');
    expect(
      await srsLegacyMainDatabasePending(db: db, directory: dir.path),
      isFalse,
    );
    final SrsStorage st = await SrsStorage.open(
      directory: dir.path,
      legacy: db,
    );
    addTearDown(st.close);
    expect(File(SrsStorage.gen4PathIn(dir.path)).existsSync(), isTrue);
  });

  test('库目录里已有 SRS 库（搬过、只是删旧表没成功）：守卫不拦', () async {
    // 旧版搬迁的标记与数据同一个事务进 srs.db：目录里有 srs.db / srs4.db 就说明搬过，主库里剩下的表只是没删掉。
    final Directory v3 = newTestSrsDir('srs_legacy_main_');
    File(SrsStorage.legacyPathIn(v3.path)).writeAsBytesSync(<int>[]);
    expect(
      await srsLegacyMainDatabasePending(db: db, directory: v3.path),
      isFalse,
    );

    final Directory gen4 = newTestSrsDir('srs_legacy_main_');
    final SrsStorage st = await SrsStorage.open(directory: gen4.path);
    await st.close();
    expect(
      await srsLegacyMainDatabasePending(db: db, directory: gen4.path),
      isFalse,
    );
    final SrsStorage again = await SrsStorage.open(
      directory: gen4.path,
      legacy: db,
    );
    addTearDown(again.close);
  });
}
