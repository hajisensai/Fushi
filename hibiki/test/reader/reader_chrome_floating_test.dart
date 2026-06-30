import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/reader/reader_chrome_floating.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-975: 阅读器顶部进度/底栏 悬浮化 + 关进度回收空白。
///
/// reader 页含真实 InAppWebView，整页 widget 测试挂不起来；故拆成
///  ① 纯函数真值表（预留高 / 可见性 / 时长归一）——挤压↔悬浮模型的单一真相源；
///  ② 偏好持久化（per-reader 分层 + 默认值 = 老用户零行为变化）；
///  ③ 源码扫描守卫——钉死「预留高经派生 getter 单一真相、悬浮显隐不重锚、改预留高
///     走重锚通道、5 处三元式已收敛」等结构不变式（撤回任一即红）。
void main() {
  group('pure reserve / visibility helpers (TODO-975)', () {
    const double infoStrip = 18; // _infoFontSize(12) * 1.5
    const double chromeH = 56;

    test('top reserve: off -> 0 (requirement A: 关进度回收空白)', () {
      expect(
        topProgressReserve(
            showTopProgress: false,
            floating: false,
            infoStripHeight: infoStrip),
        0,
        reason: '顶部进度关闭时预留必须为 0（旧实现无条件加 18px → 留空白，本次根因修复）',
      );
    });

    test('top reserve: squeeze + shown -> infoStripHeight', () {
      expect(
        topProgressReserve(
            showTopProgress: true, floating: false, infoStripHeight: infoStrip),
        infoStrip,
      );
    });

    test('top reserve: floating -> 0 (浮于正文上，不占预留)', () {
      expect(
        topProgressReserve(
            showTopProgress: true, floating: true, infoStripHeight: infoStrip),
        0,
      );
    });

    test('bottom reserve: not occupying -> 0', () {
      expect(
        bottomChromeReserve(
            barOccupiesLayout: false, floating: false, chromeHeight: chromeH),
        0,
      );
    });

    test('bottom reserve: squeeze + occupying -> chromeHeight', () {
      expect(
        bottomChromeReserve(
            barOccupiesLayout: true, floating: false, chromeHeight: chromeH),
        chromeH,
      );
    });

    test('bottom reserve: floating -> 0 even when occupying', () {
      expect(
        bottomChromeReserve(
            barOccupiesLayout: true, floating: true, chromeHeight: chromeH),
        0,
      );
    });

    test('top visible: squeeze follows showTopProgress (transient ignored)',
        () {
      expect(
        topProgressVisible(
            showTopProgress: true, floating: false, transientVisible: false),
        isTrue,
      );
      expect(
        topProgressVisible(
            showTopProgress: false, floating: false, transientVisible: true),
        isFalse,
      );
    });

    test('top visible: floating gated on transientVisible', () {
      expect(
        topProgressVisible(
            showTopProgress: true, floating: true, transientVisible: false),
        isFalse,
        reason: '悬浮态默认隐藏，未唤出不绘制',
      );
      expect(
        topProgressVisible(
            showTopProgress: true, floating: true, transientVisible: true),
        isTrue,
        reason: '悬浮态唤出后绘制',
      );
    });

    test('autoHide millis: default 3000, clamps to 1000..10000', () {
      expect(kDefaultAutoHideChromeMillis, 3000);
      expect(normalizeAutoHideChromeMillis(3000), 3000);
      expect(normalizeAutoHideChromeMillis(0), 1000);
      expect(normalizeAutoHideChromeMillis(500), 1000);
      expect(normalizeAutoHideChromeMillis(99999), 10000);
      expect(normalizeAutoHideChromeMillis(5000), 5000);
    });
  });

  group('preferences default to zero behavior change for old users', () {
    setUp(() => ReaderHibikiSource.readerSettings = null);
    tearDown(() => ReaderHibikiSource.readerSettings = null);

    test('topProgressFloating defaults false; autoHide defaults 3000',
        () async {
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      expect(source.topProgressFloating, isFalse);
      expect(source.autoHideChromeMillis, 3000);
    });

    test('topProgressFloating round-trips through per-reader ReaderSettings',
        () async {
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      final ReaderSettings perBook = ReaderSettings(db);
      await perBook.refreshFromDb();
      ReaderHibikiSource.readerSettings = perBook;

      expect(source.topProgressFloating, isFalse);
      source.toggleTopProgressFloating();
      await Future<void>.delayed(Duration.zero);
      expect(perBook.topProgressFloating, isTrue);
      expect(source.topProgressFloating, isTrue);
      expect(await db.getPref('src:reader_ttu:top_progress_floating'), 'true');
    });

    test('autoHideChromeMillis round-trips + normalizes a bad stored value',
        () async {
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final ReaderSettings perBook = ReaderSettings(db);
      await perBook.refreshFromDb();
      ReaderHibikiSource.readerSettings = perBook;

      await perBook.setAutoHideChromeMillis(4000);
      expect(perBook.autoHideChromeMillis, 4000);
      expect(
          await db.getPref('src:reader_ttu:auto_hide_chrome_millis'), '4000');

      // 越界存值（旧脏数据）读取时归一回区间。
      await db.setPref('src:reader_ttu:auto_hide_chrome_millis', '99999');
      await perBook.refreshFromDb();
      expect(perBook.autoHideChromeMillis, 10000);
    });

    test('two books do not cross-contaminate top floating', () async {
      final dbA = HibikiDatabase.forTesting(NativeDatabase.memory());
      final dbB = HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(dbA.close);
      addTearDown(dbB.close);

      final ReaderSettings bookA = ReaderSettings(dbA);
      final ReaderSettings bookB = ReaderSettings(dbB);
      await bookA.refreshFromDb();
      await bookB.refreshFromDb();

      await bookA.toggleTopProgressFloating();
      expect(bookA.topProgressFloating, isTrue);
      expect(bookB.topProgressFloating, isFalse, reason: 'per-reader 偏好不得跨书泄漏');
    });
  });

  group('source-scan structural guards (TODO-975)', () {
    final String src = readReaderPageSource();

    test('reserve truth source: _readerTopOffset uses _topProgressReserve', () {
      expect(
        src.contains(
            '_readerTopOffset => _stableTopInset + _topProgressReserve'),
        isTrue,
        reason: '顶部预留必须经派生 getter（关进度回收空白），不得无条件加 18px',
      );
      expect(
        src.contains(
            '_readerBottomReserve => _bottomChromeReserve + _stableBottomInset'),
        isTrue,
        reason: '底栏预留必须经派生 getter（悬浮归零），单一真相源',
      );
    });

    test('floating reveal/hide does NOT re-anchor (悬浮显隐不改预留高)', () {
      final String reveal = _slice(
        src,
        '  bool _handleFloatingChromeReveal() {',
        '  /// TODO-693:',
      );
      expect(reveal.contains('_chromeTransientVisible'), isTrue);
      expect(reveal.contains('_armChromeAutoHide'), isTrue);
      expect(
        reveal.contains('_reanchor') || reveal.contains('_applyChromeInsets'),
        isFalse,
        reason: '悬浮唤出/收起只改 transient 旗，不改预留高 → 绝不重锚/重下 inset',
      );
    });

    test('reserve-changing chrome prefs go through the re-anchor channel', () {
      expect(
        src.contains('ReaderHibikiSource.onChromeReanchorLive = ()'),
        isTrue,
        reason: '改预留高的 chrome 偏好必须注册 onChromeReanchorLive 重锚通道',
      );
      expect(
        src.contains('_applyChromeInsetsAndReanchor'),
        isTrue,
        reason: '重锚通道必须重下 inset + 复用样式重锚保住连续模式滚动位置',
      );
    });

    test('auto-hide timer is cancelled in dispose (no leak)', () {
      expect(src.contains('_chromeAutoHideTimer?.cancel()'), isTrue);
    });
  });

  group('first-load chrome inset re-apply (BUG-467 regression)', () {
    // 回归——TODO-975 把底栏预留 _bottomChromeReserve 门控进 `_hasEverLoaded &&
    // _showChrome`，但初始 WebView HTML 在 _hasEverLoaded=false 时求 chromeBottomInset
    // → 漏底栏高；内容就绪后从未补下 chrome insets → 竖排正文画进底栏（「文字去到底栏」）。
    // 修复=在每个内容首次就绪落点补 _reapplyChromeInsetsAfterFirstLoad()→_applyChromeInsets。
    final String src = readReaderPageSource();

    test('_reapplyChromeInsetsAfterFirstLoad exists and re-pushes insets', () {
      expect(
        src.contains('void _reapplyChromeInsetsAfterFirstLoad()'),
        isTrue,
        reason: 'BUG-467：必须有「内容首次就绪补下 chrome insets」的辅助方法',
      );
      final String body = _slice(
        src,
        'void _reapplyChromeInsetsAfterFirstLoad() {',
        '  /// TODO-975：预留高发生变化',
      );
      expect(
        body.contains('_applyChromeInsets()'),
        isTrue,
        reason: '辅助方法必须真重下 chrome insets（喂 WebView 此刻已正确的底栏预留）',
      );
    });

    test('all three content-ready flip points re-apply insets', () {
      // _hasEverLoaded 翻 true 的真实内容落点都必须补发，否则首屏底栏漏预留复活。
      final int calls = RegExp(r'_reapplyChromeInsetsAfterFirstLoad\(\)')
          .allMatches(src)
          .length;
      // 1 处定义体内不调用自身 + 3 处调用点（onRestoreComplete 正常/兜底 + spreadReady）。
      expect(
        calls,
        greaterThanOrEqualTo(3),
        reason: 'BUG-467：onRestoreComplete 正常路径 + 兜底超时 + spreadReady 三处'
            '都必须在 _hasEverLoaded 翻 true 后补下 chrome insets',
      );
    });
  });
}

String _slice(String source, String start, String end) {
  final int s = source.indexOf(start);
  expect(s, isNonNegative, reason: 'Missing start: $start');
  final int e = source.indexOf(end, s + start.length);
  expect(e, isNonNegative, reason: 'Missing end: $end');
  return source.substring(s, e);
}
