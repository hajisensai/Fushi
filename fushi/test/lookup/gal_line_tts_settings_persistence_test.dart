import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/lookup/gal_line_tts.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/models/preferences_repository.dart';

/// 浮窗控制器只在启动时按游戏模块门 start 一次：本次启动后才打开游戏模块（或启动链
/// 失败）时它没启动，但设置页照样可见。台词 TTS 设置必须照样读到已存值、写穿偏好，
/// 不能像以前那样经 `_appModel?.prefsRepo` 静默丢掉。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late GalHookSessionController session;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    session = GalHookSessionController(isWindows: true);
  });

  tearDown(() async {
    await session.close();
    await db.close();
  });

  test('未启动的浮窗：接上偏好后读到已存设置，写入落盘', () async {
    await prefs.setPref(
      kGalLineTtsSettingsPrefKey,
      const GalLineTtsSettings(autoPlayEnabled: true, volume: 0.4).encode(),
    );
    final GalHookTextOverlayController controller =
        GalHookTextOverlayController.test(session: session);

    // 没有任何偏好来源：漏接线要响，不静默丢。
    await expectLater(
      controller.setLineTtsSettings(const GalLineTtsSettings(volume: 0.9)),
      throwsStateError,
    );
    expect(controller.lineTtsSettings.volume, 1.0);

    controller.attachLineTtsPreferences(prefs);
    expect(controller.lineTtsSettings.autoPlayEnabled, isTrue);
    expect(controller.lineTtsSettings.volume, 0.4);

    await controller.setLineTtsSettings(
      controller.lineTtsSettings.copyWith(volume: 0.7),
    );
    final GalLineTtsSettings stored = GalLineTtsSettings.decode(
      prefs.getPref(kGalLineTtsSettingsPrefKey, defaultValue: ''),
    );
    expect(stored.volume, 0.7);
    expect(stored.autoPlayEnabled, isTrue);

    // 再次接线不覆盖内存里已是最新的设置。
    controller.attachLineTtsPreferences(prefs);
    expect(controller.lineTtsSettings.volume, 0.7);
  });
}
