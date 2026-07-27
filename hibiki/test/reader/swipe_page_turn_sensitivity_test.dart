import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

/// TODO-113: 翻页滑动灵敏度系数的持久化 + 阈值生效守卫。
///
/// 系数缩放 JS `_gestureEnd` 的距离阈值（基础 44px / 快速短滑 22px）。reader 注入
/// 脚本 `reader_hibiki_page._buildReaderSetupScript` 与本测试共用纯函数
/// [ReaderSettings.swipePageTurnDistThresholds]，所以「改系数 → 阈值变」在 UI 与 JS
/// 两侧一致；真正的触摸翻页手感走 WebView，归设备集成验证。
void main() {
  Future<ReaderSettings> defaultSettings(HibikiDatabase db) async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    return settings;
  }

  test('swipePageTurnSensitivity defaults to 1.0', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    expect(settings.swipePageTurnSensitivity, 1.0);
  });

  test('setSwipePageTurnSensitivity round-trips through DB', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    await settings.setSwipePageTurnSensitivity(1.5);

    final ReaderSettings reloaded = await defaultSettings(db);
    expect(reloaded.swipePageTurnSensitivity, 1.5);
  });

  test('sensitivity is clamped to [0.3, 2.0] on read and write', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    await settings.setSwipePageTurnSensitivity(5.0);
    expect(settings.swipePageTurnSensitivity, 2.0);

    await settings.setSwipePageTurnSensitivity(0.0);
    expect(settings.swipePageTurnSensitivity, 0.3);
  });

  group('swipePageTurnDistThresholds (the JS-injected effect)', () {
    test('sensitivity 1.0 is the default light 44 / 22', () {
      final ({int dist, int fastDist}) t =
          ReaderSettings.swipePageTurnDistThresholds(1.0);
      expect(t.dist, 44);
      expect(t.fastDist, 22);
    });

    test('higher sensitivity raises both thresholds (more deliberate swipe)',
        () {
      final ({int dist, int fastDist}) low =
          ReaderSettings.swipePageTurnDistThresholds(1.0);
      final ({int dist, int fastDist}) high =
          ReaderSettings.swipePageTurnDistThresholds(2.0);
      expect(high.dist, greaterThan(low.dist));
      expect(high.fastDist, greaterThan(low.fastDist));
      expect(high.dist, 88);
      expect(high.fastDist, 44);
    });

    test('lower sensitivity lowers both thresholds (more sensitive swipe)', () {
      final ({int dist, int fastDist}) t =
          ReaderSettings.swipePageTurnDistThresholds(0.5);
      expect(t.dist, lessThan(44));
      expect(t.fastDist, lessThan(22));
      expect(t.dist, 22);
      expect(t.fastDist, 11);
    });

    test('tapSlopPx is a fixed 10 and NOT scaled by sensitivity', () {
      // 查词轨迹半径与翻页距离阈值解耦：无论灵敏度怎么调，原地轻点判定恒为 10px。
      expect(ReaderSettings.tapSlopPx, 10);
    });
  });
}
