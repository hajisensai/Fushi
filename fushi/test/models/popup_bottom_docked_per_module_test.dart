import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-4713：底部停靠改成每个模块独立可选，不再是「总开关 ∧ 细分开关（默认 ON）」。
///
/// 只用 [AppModel] / [PreferencesRepository] 的公开 API 与原始偏好行断言，覆盖：
/// 模块开关互不牵连、不受 `popup_bottom_docked` 门控；旧语义数据（含老 Profile 快照 /
/// 老备份恢复回来的）读出的有效值与旧版一致，第一次写入时原样物化成新语义。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<AppModel> _appModel(
  FushiDatabase db, {
  Map<String, Object> seed = const <String, Object>{},
}) async {
  for (final MapEntry<String, Object> e in seed.entries) {
    await db.setPref(e.key, PrefCodec.encode(e.value));
  }
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir = Directory.systemTemp.createTempSync(
    'fushi_popup_dock_per_module_',
  );
  addTearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  return AppModel(testPlatformServices())
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db);
}

Map<ModuleId, bool> _effective(AppModel appModel) => <ModuleId, bool>{
  for (final ModuleId m in PreferencesRepository.kPopupBottomDockedModules)
    m: appModel.popupBottomDockedFor(m),
};

void main() {
  test('fresh install: docking one module needs no master switch and leaves '
      'every other module and the non-module hosts alone', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _appModel(db);

    expect(_effective(appModel).values, everyElement(isFalse));
    expect(appModel.popupBottomDockedFor(null), isFalse);

    await appModel.setPopupBottomDockedIn(ModuleId.books, true);

    expect(_effective(appModel), <ModuleId, bool>{
      ModuleId.books: true,
      ModuleId.manga: false,
      ModuleId.video: false,
      ModuleId.games: false,
    });
    expect(appModel.popupBottomDockedFor(null), isFalse);
    expect(appModel.popupBottomDocked, isFalse);
  });

  test('the non-module switch no longer gates the modules', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _appModel(db);

    await appModel.setPopupBottomDockedIn(ModuleId.video, true);
    await appModel.setPopupBottomDocked(true);
    await appModel.setPopupBottomDocked(false);

    expect(appModel.popupBottomDockedFor(ModuleId.video), isTrue);
    expect(appModel.popupBottomDockedFor(ModuleId.books), isFalse);
    expect(appModel.popupBottomDockedFor(null), isFalse);
  });

  test('legacy data with the master switch OFF keeps every module undocked '
      'when one module is turned on', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    // 旧版：总开关关着，细分开关里有显式 ON 的（以前开过总开关时留下的）。
    final AppModel appModel = await _appModel(
      db,
      seed: <String, Object>{
        'popup_bottom_docked': false,
        'popup_bottom_docked_manga': true,
      },
    );

    expect(
      _effective(appModel).values,
      everyElement(isFalse),
      reason: '升级后读出的有效值与旧版一致：总开关关着 = 哪里都不停靠',
    );

    await appModel.setPopupBottomDockedIn(ModuleId.video, true);

    expect(_effective(appModel), <ModuleId, bool>{
      ModuleId.books: false,
      ModuleId.manga: false,
      ModuleId.video: true,
      ModuleId.games: false,
    });
    expect(appModel.popupBottomDockedFor(null), isFalse);
  });

  test('legacy data with the master switch ON keeps each module\'s effective '
      'value when the non-module switch is turned off', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _appModel(
      db,
      seed: <String, Object>{
        'popup_bottom_docked': true,
        'popup_bottom_docked_video': false,
      },
    );
    final Map<ModuleId, bool> legacy = <ModuleId, bool>{
      ModuleId.books: true,
      ModuleId.manga: true,
      ModuleId.video: false,
      ModuleId.games: true,
    };
    expect(_effective(appModel), legacy);
    expect(appModel.popupBottomDockedFor(null), isTrue);

    await appModel.setPopupBottomDocked(false);

    expect(_effective(appModel), legacy, reason: '查词页那条开关不再牵连各模块');
    expect(appModel.popupBottomDockedFor(null), isFalse);

    // 物化后的值真落盘：重新装载仓库读到同一份。
    final PreferencesRepository reloaded = PreferencesRepository(db);
    await reloaded.loadFromDb();
    for (final MapEntry<ModuleId, bool> e in legacy.entries) {
      expect(reloaded.popupBottomDockedIn(e.key), e.value, reason: '${e.key}');
    }
    expect(reloaded.popupBottomDocked, isFalse);
  });

  test('an old profile snapshot / backup applied after the upgrade is read '
      'with the semantics it was saved under', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _appModel(db);
    await appModel.setPopupBottomDockedIn(ModuleId.books, true);

    // 应用老快照 = 快照里没有的键被删、有的键整体覆盖：语义标记随之消失。
    await db.deletePref('popup_bottom_docked_per_module');
    await db.setPref('popup_bottom_docked', PrefCodec.encode(false));
    await db.setPref('popup_bottom_docked_books', PrefCodec.encode(true));
    final AppModel afterRestore = await _appModel(db);

    expect(
      _effective(afterRestore).values,
      everyElement(isFalse),
      reason: '老快照里总开关关着，小说的细分 ON 在旧语义下不生效',
    );

    // 恢复后第一次只开视频：旧语义的有效值（全关）原样物化，小说那条遗留的细分 ON
    // 不能借机「复活」；视频单独生效，不需要总开关（修复前总开关关着时视频开不了）。
    await afterRestore.setPopupBottomDockedIn(ModuleId.video, true);
    expect(_effective(afterRestore), <ModuleId, bool>{
      ModuleId.books: false,
      ModuleId.manga: false,
      ModuleId.video: true,
      ModuleId.games: false,
    });
    expect(afterRestore.popupBottomDockedFor(null), isFalse);
  });
}
