import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/reader/reader_settings.dart';

/// 鼠标滚轮翻页节流间隔（毫秒）的持久化守卫。
///
/// 旧实现把节流写死成 250ms（偏快），现改为可调、默认 450ms（更慢）。JS 端
/// `reader_hibiki_page._buildReaderSetupScript` 把 `s.wheelPageTurnInterval`
/// 注入到 `setTimeout(..., N)`，真正的翻页节流效果走 WebView，归设备集成验证。
void main() {
  Future<ReaderSettings> defaultSettings(FushiDatabase db) async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    return settings;
  }

  test('wheelPageTurnInterval defaults to 450ms', () async {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    expect(settings.wheelPageTurnInterval, 450);
  });

  test('reading default does not persist a synthetic preference row', () async {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    expect(settings.wheelPageTurnInterval, 450);

    final Map<String, String> prefs = await db.getAllPrefs();
    expect(
      prefs.containsKey('src:reader_ttu:wheel_page_turn_interval'),
      isFalse,
      reason: 'a synchronous getter must not start an unawaitable DB write; '
          'tests and app shutdown can close the DB before that write finishes',
    );
  });

  test('setWheelPageTurnInterval round-trips through DB', () async {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    await settings.setWheelPageTurnInterval(700);

    final ReaderSettings reloaded = await defaultSettings(db);
    expect(reloaded.wheelPageTurnInterval, 700);
  });
}
