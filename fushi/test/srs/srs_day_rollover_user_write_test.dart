// 日界的写入与采纳（所有者 2026-11-10 拍板「日界小时随 profile 同步」，PR #3130 拍板点 1）：
//
// - 用户在统计设置里改日界（[AppModel.setStatDayResetHourByUser]）：本机统计日界 + 当前配置复习的翻日时刻字段，
//   后者随同步 v2 传到别的设备；写完通知复习界面重读。
// - 此刻写不进复习（模块关着）：给这份配置记待写标记，复习库下次激活时补写（[AppModel.flushPendingDayRollover]，
//   经 [SrsProfileStores.onActivated]），之后的同步拉入不会把这次修改改回旧值。
// - 同步拉入后（[AppModel.adoptSyncedDayRollover]）：只有生效的是本机没见过的修改才改本机统计日界，不写回复习。
// - 首次开复习补的默认 4 点（[AppModel.setStatDayResetHour]）只改本机，从不写进复习。
//
// 真实主库（内存）+ 真实 srs.db + Rust 内核，按 app 的方式经 SrsProfileStores 开激活副本。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/srs/srs_profile_stores.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

const String _uid = 'profile-day-rollover';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel app;
  late SrsStorage storage;
  late SrsProfileStores stores;
  late SrsDbStore store;
  late int notified;
  late bool srsOff;
  Future<void>? lastFlush;

  /// 与 srsStoreProvider 同形：经 [SrsProfileStores.activate] 打开激活副本。
  Future<SrsDbStore> activate() => stores.activate(
    _uid,
    () => SrsDbStore.open(
      db: storage.db,
      core: storage.core,
      profileUid: _uid,
      deviceId: 'dev',
      engine: const SrsTestEngine(),
      fallbackRolloverHour: () => app.statDayResetHour,
    ),
  );

  /// 模拟「复习模块关掉 → 改日界 → 再打开」：关掉时 srs.db 不再开放、激活副本作废；打开时重新激活。
  Future<void> turnSrsOff() async {
    srsOff = true;
    await stores.releaseAll();
  }

  Future<void> turnSrsOn() async {
    srsOff = false;
    store = await activate();
    // onActivated 不等补写做完（激活不被它拖慢）：测试等它。
    await lastFlush;
  }

  Object? pendingOf() =>
      prefs.getPref('$kSrsDayRolloverPendingPrefKeyPrefix$_uid');

  setUp(() async {
    FushiDatabase.statDayResetHour = 0;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory tmp = Directory.systemTemp.createTempSync(
      'fushi_day_rollover_',
    );
    app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tmp);
    addTearDown(() async {
      FushiDatabase.statDayResetHour = 0;
      await db.close();
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 句柄滞后：临时目录留给系统清理。
      }
    });

    srsOff = false;
    storage = await openSrsTestStorage();
    final Directory support = Directory.systemTemp.createTempSync(
      'fushi_day_rollover_srs_',
    );
    stores = SrsProfileStores(
      SrsProfileStoresDeps(
        storage: () async => srsOff ? null : storage,
        deviceId: () async => 'dev',
        supportRoot: () async => support,
        engine: () => const SrsTestEngine(),
      ),
    );
    // app 启动时 ensureDefaultProfile 建的那份配置。
    await db.insertProfile(
      ProfilesCompanion.insert(
        name: 'Default',
        uid: const Value<String?>(_uid),
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    expect(await db.resolveActiveProfileUid(), _uid);
    notified = 0;
    // 与 main.dart 同样的接线。
    stores.onActivated = (SrsDbStore s) =>
        lastFlush = app.flushPendingDayRollover(s);
    app
      ..srsProfileStoresReader = (() => stores)
      ..srsCardsAddedNotifier = () => notified++;
    store = await activate();
  });

  test('用户改日界：本机统计日界 + 复习翻日时刻字段都写上，并通知复习界面重读', () async {
    await app.setStatDayResetHourByUser(6);
    expect(app.statDayResetHour, 6);
    expect(FushiDatabase.statDayResetHour, 6);
    expect((await store.syncedDayRollover())?.hour, 6);
    expect((await store.dayContext()).rolloverHour, 6);
    expect(notified, 1);
    expect(pendingOf(), anyOf(isNull, -1), reason: '写进去了就没有待写标记');
  });

  test('只有默认值（首次开复习补 4 点）：只改本机，复习字段一直为空', () async {
    await app.setStatDayResetHour(4);
    expect(app.statDayResetHour, 4);
    expect(pendingOf(), isNull, reason: '默认值不记待写标记');
    await turnSrsOff();
    await turnSrsOn();
    expect(await store.syncedDayRollover(), isNull);
    expect(
      (await store.dayContext()).rolloverHour,
      4,
      reason: '没有字段时回落到本机统计日界',
    );
  });

  test('复习模块关着时改日界：开启后字段是新值，同步拉入不会把本机改回旧值', () async {
    await app.setStatDayResetHourByUser(6);
    final SrsDayRollover? old = await store.syncedDayRollover();
    expect(old?.hour, 6);

    await turnSrsOff();
    await app.setStatDayResetHourByUser(2);
    expect(app.statDayResetHour, 2);
    expect(pendingOf(), 2, reason: '写不进复习：记下待写标记');

    // 模块还关着时来了一次「拉入」，profile 里仍是旧的 6：不能改回去。
    await app.adoptSyncedDayRollover(_uid, () async => old);
    expect(app.statDayResetHour, 2);

    await turnSrsOn();
    expect((await store.syncedDayRollover())?.hour, 2, reason: '激活时补写了');
    expect(pendingOf(), -1, reason: '补写后清掉标记');

    // 开启后的同步拉入：生效的就是刚补写的那条，本机不动。
    await app.adoptSyncedDayRollover(_uid, store.syncedDayRollover);
    expect(app.statDayResetHour, 2);
    expect((await store.dayContext()).rolloverHour, 2);
  });

  test('同步拉入：只有新来的修改才改本机统计日界，同一条修改不会反复覆盖本机', () async {
    await app.setStatDayResetHourByUser(6);
    // 别的设备改成 3（这里直接写一条修改记录代替同步落库）。
    await store.editField(
      SrsEntityKind.profile,
      _uid,
      SrsFieldKeys.dayRolloverHour,
      3,
    );
    final int ops = (await store.sync2Status())['ops']! as int;
    await app.adoptSyncedDayRollover(_uid, store.syncedDayRollover);
    expect(app.statDayResetHour, 3);
    expect(FushiDatabase.statDayResetHour, 3);
    expect(
      (await store.sync2Status())['ops'],
      ops,
      reason: '单向：本机偏好跟上，不产生新的复习操作',
    );

    // 本机之后只动了本机偏好（比如首次开复习补默认值），下一轮拉入里还是那条修改：不覆盖。
    await app.setStatDayResetHour(5);
    await app.adoptSyncedDayRollover(_uid, store.syncedDayRollover);
    expect(app.statDayResetHour, 5);
  });

  test('用户改日界与同步拉入后的采纳同时发生：采纳排在用户写完之后、现读生效值，本机与复习不分叉', () async {
    await app.setStatDayResetHourByUser(4);
    // 别的设备改成 3，刚拉进来、本机还没采纳（这里直接写一条修改记录代替同步落库）。
    await store.editField(
      SrsEntityKind.profile,
      _uid,
      SrsFieldKeys.dayRolloverHour,
      3,
    );

    // 用户此刻在统计设置里改成 6，同一时刻这次拉入的采纳也开始了（都不先 await）。
    final Future<void> user = app.setStatDayResetHourByUser(6);
    final Future<void> pulled = app.adoptSyncedDayRollover(
      _uid,
      store.syncedDayRollover,
    );
    await Future.wait(<Future<void>>[user, pulled]);

    expect((await store.syncedDayRollover())?.hour, 6, reason: '复习字段是用户的新值');
    expect(app.statDayResetHour, 6, reason: '采纳没有拿用户改之前的那条修改把本机改回 3');
    expect(FushiDatabase.statDayResetHour, 6);
    expect((await store.dayContext()).rolloverHour, app.statDayResetHour);

    // 之后的拉入里生效的仍是用户那条（本机写下、已见）：不再变。
    await app.adoptSyncedDayRollover(_uid, store.syncedDayRollover);
    expect(app.statDayResetHour, 6);
  });

  test('远程复习库显式不支持日界读写（不落到 noSuchMethod）', () {
    final String src = File(
      'lib/src/srs/srs_remote_store_client.dart',
    ).readAsStringSync();
    for (final String member in <String>[
      'Future<SrsDayRollover?> syncedDayRollover()',
      'Future<SrsDayRollover?> setDayRolloverHour(int hour)',
    ]) {
      final int at = src.indexOf(member);
      expect(at, greaterThan(0), reason: '$member 要在 SrsRemoteStore 里显式声明');
      expect(
        src.substring(at, at + 200),
        contains('UnsupportedError'),
        reason: '$member 给出明确的不支持错误',
      );
    }
  });
}
