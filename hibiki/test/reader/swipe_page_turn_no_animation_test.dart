import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';
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
    // TODO-589 batch8: swipe 阈值/连续模式 wheel(setup 脚本)已搬到
    // reader_hibiki/webview.part.dart，改读「主壳 + 全部 part」合并语料。
    final String src = readReaderPageSource();

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

  test(
      'continuous mode wheel: horizontal pass-through + vertical-writing '
      'explicit horizontal scroll (BUG-239 / TODO-345)', () {
    // BUG-239 同源回归守卫：连续模式靠浏览器原生滚动（滚动轴 = 书写轴），
    // 滚轮就是原生滚动主要驱动。wheel 监听里历史上无条件 preventDefault +
    // 回传 onSwipe（90% 整屏跳页），把连续模式的原生滚轮杀死、章内滚不动。
    //
    // TODO-345：横排连续滚动轴 = 纵向（与桌面滚轮 deltaY 默认轴一致），放行原生
    // 滚动即可。竖排连续滚动轴 = 横向（overflow-x 可滚 / overflow-y:hidden），但
    // 桌面滚轮只产生 deltaY，浏览器不会可靠地把垂直滚轮映射到横向轴 → 竖排连续
    // 模式滚轮滚不动。修复：连续模式分支里，竖排显式把滚轮 delta 投影到横向
    // scrollBy + preventDefault；横排仍放行原生滚动（不 onSwipe / 不 preventDefault）。
    //
    // 这里钉住：(1) 连续分支必须先于分页的 onSwipe 翻页通道；(2) 连续分支内必须
    // 有「仅竖排（isVertical）才显式 scrollBy({left: ...}) 横向滚动」；(3) 横排
    // 连续仍是早返回（不触发 onSwipe / preventDefault）。
    // TODO-589 batch8: swipe 阈值/连续模式 wheel(setup 脚本)已搬到
    // reader_hibiki/webview.part.dart，改读「主壳 + 全部 part」合并语料。
    final String src = readReaderPageSource();

    // 定位 wheel 监听块（从 addEventListener('wheel' 到其闭合 `}, {passive`)。
    final int wheelStart = src.indexOf("addEventListener('wheel'");
    expect(wheelStart, greaterThanOrEqualTo(0),
        reason: 'wheel listener must exist in the reader setup script');
    final int wheelEnd = src.indexOf('{passive: false});', wheelStart);
    expect(wheelEnd, greaterThan(wheelStart),
        reason: 'wheel listener must be a passive:false block');
    final String wheelBlock = src.substring(wheelStart, wheelEnd);

    // 连续模式分支必须存在，且先于分页 onSwipe 翻页通道（轴向冲突的根因门控）。
    final int guardIdx = wheelBlock.indexOf('if (hoshiContinuousMode)');
    expect(guardIdx, greaterThanOrEqualTo(0),
        reason: 'wheel must branch on continuous mode before the paginated '
            'onSwipe page-turn');

    final int swipeIdx = wheelBlock.indexOf("callHandler('onSwipe'");
    expect(swipeIdx, greaterThan(guardIdx),
        reason: 'continuous-mode branch must precede the onSwipe page-turn');

    // 连续分支内：竖排显式横向滚动（沿真实书写轴），桌面垂直滚轮才滚得动。
    final String continuousBranch = wheelBlock.substring(guardIdx, swipeIdx);
    expect(continuousBranch, contains('isVertical'),
        reason: 'continuous-mode wheel must gate the explicit scroll on '
            'vertical writing (horizontal mode stays native pass-through)');
    // TODO-629 ②: 竖排投影从逐事件 scrollBy(behavior:'auto') 离散跳改为 rAF 缓动
    // （累积 _vScrollTarget + requestAnimationFrame 每帧逼近 scrollLeft）。仍沿真实
    // 横向书写轴滚动，只是消除颗粒感；这里钉住「竖排投影累积进 rAF 缓动目标」不变量。
    expect(continuousBranch, contains('_vScrollTarget'),
        reason: 'vertical continuous mode must accumulate the projected wheel '
            'delta into the rAF easing target (not per-event scrollBy)');
    expect(
        continuousBranch, contains('requestAnimationFrame(_vScrollEaseStep)'),
        reason: 'vertical continuous wheel must be driven by rAF easing so the '
            'horizontal scroll along the writing axis is smooth, not discrete');
    expect(continuousBranch, isNot(contains("behavior: 'auto'")),
        reason:
            'the old per-event discrete scrollBy(behavior: auto) projection '
            'must be gone (TODO-629 ② 刷新率低/一格一格跳 根因)');
  });
}
