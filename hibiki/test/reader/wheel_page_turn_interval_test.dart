import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

/// 鼠标滚轮翻页节流间隔（毫秒）的持久化守卫。
///
/// 旧实现把节流写死成 250ms（偏快），现改为可调、默认 450ms（更慢）。JS 端
/// `reader_hibiki_page._buildReaderSetupScript` 把 `s.wheelPageTurnInterval`
/// 注入到 `setTimeout(..., N)`，真正的翻页节流效果走 WebView，归设备集成验证。
void main() {
  Future<ReaderSettings> defaultSettings(HibikiDatabase db) async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    return settings;
  }

  test('wheelPageTurnInterval defaults to 450ms', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    expect(settings.wheelPageTurnInterval, 450);
  });

  test('setWheelPageTurnInterval round-trips through DB', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    await settings.setWheelPageTurnInterval(700);

    final ReaderSettings reloaded = await defaultSettings(db);
    expect(reloaded.wheelPageTurnInterval, 700);
  });
}
