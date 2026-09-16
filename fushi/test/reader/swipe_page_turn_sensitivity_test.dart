import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/reader/reader_settings.dart';

/// TODO-113 / BUG-滑动翻页不够灵敏：翻页滑动灵敏度的持久化 + 阈值生效守卫。
///
/// 灵敏度缩放 JS `_gestureEnd` 的三个阈值（基础 24px 距离 / 12px 快速短滑 / 300px·s⁻¹
/// 速度门）。reader 注入脚本与本测试共用纯函数
/// [ReaderSettings.swipePageTurnDistThresholds]，所以「改灵敏度 → 阈值变」在 UI 与 JS
/// 两侧一致；真正的触摸翻页手感走 WebView，归设备集成验证。
///
/// **语义方向是这组测试的第一主题**：这个值以前是「阈值倍数」（越大越迟钝），与它在
/// 设置页上的标题「滑动翻页灵敏度」正好相反。翻正之后，「更大 = 更灵敏 = 阈值更小」
/// 必须成为被钉死的不变式，否则很容易在后续重构里悄悄翻回去。
void main() {
  Future<ReaderSettings> defaultSettings(FushiDatabase db) async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    return settings;
  }

  test('swipePageTurnSensitivity defaults to 1.0', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    expect(settings.swipePageTurnSensitivity, 1.0);
  });

  test('setSwipePageTurnSensitivity round-trips through DB', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    await settings.setSwipePageTurnSensitivity(1.5);

    final ReaderSettings reloaded = await defaultSettings(db);
    expect(reloaded.swipePageTurnSensitivity, 1.5);
  });

  test('sensitivity is clamped to [0.5, 3.0] on read and write', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    await settings.setSwipePageTurnSensitivity(9.0);
    expect(settings.swipePageTurnSensitivity, 3.0);

    await settings.setSwipePageTurnSensitivity(0.0);
    expect(settings.swipePageTurnSensitivity, 0.5);
  });

  group('legacy "threshold multiplier" values migrate by reciprocal', () {
    // 旧 key 存的是阈值倍数：2.0 = 阈值翻倍 = 迟钝一倍 = 新语义的灵敏度 0.5。
    // 不换算直接沿用会把老用户的设置整个翻反（最迟钝变成最灵敏）。
    Future<ReaderSettings> withLegacy(
      FushiDatabase db,
      double multiplier,
    ) async {
      await db.setPref(
        'src:reader_fushi:${ReaderSettings.legacySwipeSensitivityMultiplierKey}',
        '$multiplier',
      );
      return defaultSettings(db);
    }

    test('legacy 2.0 (twice as blunt) reads back as sensitivity 0.5', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final ReaderSettings settings = await withLegacy(db, 2.0);

      expect(settings.swipePageTurnSensitivity, 0.5);
    });

    test('legacy 0.5 (twice as keen) reads back as sensitivity 2.0', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final ReaderSettings settings = await withLegacy(db, 0.5);

      expect(settings.swipePageTurnSensitivity, 2.0);
    });

    test('legacy 1.0 stays 1.0 (the no-op case, most users)', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final ReaderSettings settings = await withLegacy(db, 1.0);

      expect(settings.swipePageTurnSensitivity, 1.0);
    });

    test('writing the new key wins over a stale legacy value', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final ReaderSettings settings = await withLegacy(db, 2.0);

      await settings.setSwipePageTurnSensitivity(2.5);

      final ReaderSettings reloaded = await defaultSettings(db);
      expect(reloaded.swipePageTurnSensitivity, 2.5);
    });
  });

  group('swipePageTurnDistThresholds (the JS-injected effect)', () {
    test('sensitivity 1.0 is the Hoshi-aligned 24 / 12 / 300', () {
      final ({int dist, int fastDist, int fastVelocity}) t =
          ReaderSettings.swipePageTurnDistThresholds(1.0);
      expect(t.dist, 24);
      expect(t.fastDist, 12);
      expect(t.fastVelocity, 300);
    });

    test(
      'higher sensitivity lowers every threshold (a shorter swipe turns)',
      () {
        final ({int dist, int fastDist, int fastVelocity}) low =
            ReaderSettings.swipePageTurnDistThresholds(1.0);
        final ({int dist, int fastDist, int fastVelocity}) high =
            ReaderSettings.swipePageTurnDistThresholds(2.0);
        expect(high.dist, lessThan(low.dist));
        expect(high.fastDist, lessThan(low.fastDist));
        expect(high.fastVelocity, lessThan(low.fastVelocity));
        expect(high.dist, 12);
        expect(high.fastVelocity, 150);
      },
    );

    test(
      'lower sensitivity raises every threshold (a longer swipe is needed)',
      () {
        final ({int dist, int fastDist, int fastVelocity}) t =
            ReaderSettings.swipePageTurnDistThresholds(0.5);
        expect(t.dist, greaterThan(24));
        expect(t.fastDist, greaterThan(12));
        expect(t.fastVelocity, greaterThan(300));
        expect(t.dist, 48);
        expect(t.fastDist, 24);
        expect(t.fastVelocity, 600);
      },
    );

    test('the keenest setting still never turns below the tap slop', () {
      // 翻页阈值一旦跌到查词轨迹半径以下，「点词」就会被翻页整片吃掉：tap 判的是
      // 轨迹半径、swipe 判的是净位移，而轨迹半径恒 ≥ 净位移。
      final ({int dist, int fastDist, int fastVelocity}) keenest =
          ReaderSettings.swipePageTurnDistThresholds(
        ReaderSettings.maxSwipePageTurnSensitivity,
      );
      expect(keenest.dist, greaterThan(ReaderSettings.tapSlopPx));
    });

    test('tapSlopPx is a fixed 10 and NOT scaled by sensitivity', () {
      // 查词轨迹半径与翻页距离阈值解耦：无论灵敏度怎么调，原地轻点判定恒为 10px。
      expect(ReaderSettings.tapSlopPx, 10);
    });

    test('the default is keener than the pre-fix default was', () {
      // 回归护栏：改动前灵敏度 1.0 意味着 44px / 22px / 900px·s⁻¹。要是有人把基础值
      // 调回去，这条会红——「默认手感必须比修复前更灵敏」是这次改动的全部意义。
      final ({int dist, int fastDist, int fastVelocity}) t =
          ReaderSettings.swipePageTurnDistThresholds(
        ReaderSettings.defaultSwipePageTurnSensitivity,
      );
      expect(t.dist, lessThan(44));
      expect(t.fastDist, lessThan(22));
      expect(t.fastVelocity, lessThan(900));
    });
  });

  group('ReaderFushiSource 的无 settings 回退路径不得写旧倍数 key', () {
    // `ReaderFushiSource` 与 [ReaderSettings] 落在同一个 `src:reader_fushi:` 偏好
    // 命名空间上，但前者在 `readerSettings == null` 的 entry point（`:popup` /
    // 悬浮查词）另有一条自己的读写分支。语义翻正后这条分支若仍读写旧的「阈值倍数」
    // key，写进去的**新语义**值会被 [ReaderSettings] 当 legacy 倍数再取一次倒数，
    // 设置整个翻反（最灵敏 3.0 → 1/3 → 钳回 0.5 最迟钝），正是换新 key 要防的事。
    // Tests run with CWD = `fushi/`.
    final File source = File('lib/src/media/sources/reader_fushi_source.dart');

    test('reader_fushi_source.dart exists', () {
      expect(source.existsSync(), isTrue);
    });

    test('两侧共用同一组 key 常量，源码里不留裸字面量', () {
      final String src = source.readAsStringSync();
      expect(
        src.contains("'swipe_page_turn_sensitivity'"),
        isFalse,
        reason: 'BUG-2563：旧倍数 key 只读不写，且必须经 '
            'ReaderSettings.legacySwipeSensitivityMultiplierKey 引用，'
            '不得在 source 里写裸字面量——两处各写一份必然漂移。',
      );
      expect(
        src.contains('ReaderSettings.swipeSensitivityKey'),
        isTrue,
        reason: 'BUG-2563：回退分支必须读写语义翻正后的新 key。',
      );
      expect(
        src.contains('ReaderSettings.legacySwipeSensitivityMultiplierKey'),
        isTrue,
        reason: 'BUG-2563：回退分支读不到新 key 时必须按倒数换算旧值，'
            '否则 `:popup` 侧读出的手感与阅读器进程相反。',
      );
    });
  });
}
