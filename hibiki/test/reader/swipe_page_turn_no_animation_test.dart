import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

/// TODO-114: 删除「滑动翻页动画」守卫。
///
/// reader 正文翻页（分页/连续）从来没有 CSS transition/animation/scroll-behavior：
/// 分页模式翻页是 `hoshiReader.assignPagePosition` 直接赋值 scrollTop/scrollLeft（瞬时）。
/// 用户看到的「滑动动画」是 WebView 把触摸拖动当原生 pan，让页面跟手位移再被 snap
/// 回弹。根因修复 = 分页模式 body `touch-action: none`，触摸不再被翻译成原生滚动，
/// 翻页只由 onSwipe 检测后瞬时跳页。连续模式本质就是滚动阅读，保留原生滚动。
void main() {
  Future<ReaderSettings> defaultSettings(HibikiDatabase db) async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    return settings;
  }

  test('paginated layout disables native touch panning (touch-action: none)',
      () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    final String css = ReaderContentStyles.css(settings: settings);

    expect(css, contains('touch-action: none'));
  });

  test('paginated page-turn CSS has no scroll/transition animation', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    final String css = ReaderContentStyles.css(settings: settings);

    expect(css, isNot(contains('scroll-behavior')));
    expect(css, isNot(contains('transition:')));
    expect(css, isNot(contains('@keyframes')));
  });

  test('continuous mode keeps native scrolling (no touch-action: none)',
      () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);
    await settings.setViewMode('continuous');

    final String css = ReaderContentStyles.css(settings: settings);

    expect(css, isNot(contains('touch-action: none')));
  });

  test(
      'reader page swipe threshold is parameterized, not a hard-coded literal 72',
      () {
    // Source-scan guard: the swipe-detection branch must read the
    // sensitivity-scaled $swipeDistThreshold, not the old literal threshold.
    // If someone reverts to `absDx >= 72`, this fails.
    final File page = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    );
    final String src = page.readAsStringSync();

    expect(
      src,
      contains(r'absDx >= $swipeDistThreshold'),
      reason:
          'swipe distance threshold must use the injected sensitivity value',
    );
    expect(
      src,
      isNot(contains('absDx >= 72 ||')),
      reason: 'the hard-coded 72px swipe threshold must be gone',
    );
    expect(
      src,
      contains('ReaderSettings.swipePageTurnDistThresholds'),
      reason:
          'reader page must derive thresholds from the shared pure function',
    );
  });
}
