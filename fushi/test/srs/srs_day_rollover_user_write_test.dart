// 日界的两条路（所有者 2026-11-10 拍板「日界小时随 profile 同步」）：
//
// - 用户在统计设置里改日界（[AppModel.setStatDayResetHourByUser]）：本机统计日界 + 当前配置复习的翻日时刻字段，
//   后者随同步 v2 传到别的设备；写完通知复习界面重读。
// - 同步带来了别的设备改的翻日时刻（[AppModel.adoptSyncedDayRolloverHour]）：只改本机统计日界，不写回复习，
//   不会来回同步。首次开复习补的默认 4 点（[AppModel.setStatDayResetHour]）同样只改本机。
//
// 真实主库（内存）+ 真实 srs.db + Rust 内核，按 app 的方式经 SrsProfileStores 开激活副本。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/srs/srs_profile_stores.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late AppModel app;
  late SrsDbStore store;
  late int notified;

  setUp(() async {
    FushiDatabase.statDayResetHour = 0;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
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

    final SrsStorage storage = await openSrsTestStorage();
    final Directory support = Directory.systemTemp.createTempSync(
      'fushi_day_rollover_srs_',
    );
    final SrsProfileStores stores = SrsProfileStores(
      SrsProfileStoresDeps(
        storage: () async => storage,
        deviceId: () async => 'dev',
        supportRoot: () async => support,
        engine: () => const SrsTestEngine(),
      ),
    );
    // app 启动时 ensureDefaultProfile 建的那份配置。
    await db.insertProfile(
      ProfilesCompanion.insert(
        name: 'Default',
        uid: const Value<String?>('profile-day-rollover'),
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    final String uid = await db.resolveActiveProfileUid();
    expect(uid, 'profile-day-rollover');
    store = await stores.activate(
      uid,
      () => SrsDbStore.open(
        db: storage.db,
        core: storage.core,
        profileUid: uid,
        deviceId: 'dev',
        engine: const SrsTestEngine(),
        fallbackRolloverHour: () => app.statDayResetHour,
      ),
    );
    notified = 0;
    app
      ..srsProfileStoresReader = (() => stores)
      ..srsCardsAddedNotifier = () => notified++;
  });

  test('用户改日界：本机统计日界 + 复习翻日时刻字段都写上，并通知复习界面重读', () async {
    await app.setStatDayResetHourByUser(6);
    expect(app.statDayResetHour, 6);
    expect(FushiDatabase.statDayResetHour, 6);
    expect(await store.syncedDayRolloverHour(), 6);
    expect((await store.dayContext()).rolloverHour, 6);
    expect(notified, 1);
  });

  test('默认值路径（首次开复习补 4 点）只改本机，不写复习字段', () async {
    await app.setStatDayResetHour(4);
    expect(app.statDayResetHour, 4);
    expect(await store.syncedDayRolloverHour(), isNull);
    expect(
      (await store.dayContext()).rolloverHour,
      4,
      reason: '没有字段时回落到本机统计日界',
    );
  });

  test('同步来的翻日时刻：只跟到本机统计日界，不写回复习', () async {
    await app.setStatDayResetHourByUser(6);
    final int ops = (await store.sync2Status())['ops']! as int;
    await app.adoptSyncedDayRolloverHour(3);
    expect(app.statDayResetHour, 3);
    expect(FushiDatabase.statDayResetHour, 3);
    expect(
      (await store.sync2Status())['ops'],
      ops,
      reason: '单向：本机偏好跟上，不产生新的复习操作',
    );
  });

  test('复习不可用（未注入）：只改本机统计日界', () async {
    app.srsProfileStoresReader = null;
    await app.setStatDayResetHourByUser(5);
    expect(app.statDayResetHour, 5);
    expect(await store.syncedDayRolloverHour(), isNull);
    expect(notified, 0);
  });
}
