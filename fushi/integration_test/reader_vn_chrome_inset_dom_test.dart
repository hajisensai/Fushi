import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/media.dart';
import 'package:fushi/src/epub/epub_importer.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';

import 'helpers/focus_driver.dart';
import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'test_helpers.dart';

/// BUG-1688 回归 —— VN（视觉小说）view-mode 忽略 chrome inset / 页面尺寸（real-DOM）。
///
/// 根因：VN shell 是 hoshi a 移植过来的第三种 view-mode，它的 host-compat shim 把
/// `setChromeInsets` 直接写成 `return null` 的空壳，而 VN 自己的 `initialize()` 也
/// 从没像分页/连续 shell 那样从 `C.chromeTopInset / C.chromeBottomInset` 写
/// `--chrome-top-inset / --chrome-bottom-inset`。于是 `_vnLayoutCss` 里
/// `.fushi-vn-stage` 的 `padding-top: calc(...vh + var(--chrome-top-inset, 0px))`
/// 恒取 0px 兜底值：VN 舞台按**整个视口**排版，顶部进度条/顶栏与底栏（iOS 上还要
/// 叠刘海与 home indicator）直接压在正文上。
///
/// 同源第二处：`fitScreensToViewport` 的量尺 `createScreenMeasurement` 用
/// `var(--page-width, 100vw) / var(--page-height, 100vh)` 撑开，而这两个变量只有
/// 分页/连续 shell 的 `initialize` 会写，VN 下同样落到 100vw/100vh 兜底；且
/// `updatePageSize(width, height)` 整个忽略入参。量尺比真实 `.fushi-vn-screen`
/// 大出整条 chrome 预留带 → 每屏都被塞到"刚好填满整个视口"，于是**每一屏**的首尾行
/// 都落进被 chrome 覆盖的区域。这就是"iOS 上 VN 模式基本不可用"的几何根因。
///
/// 第三处（**iOS 专属，且是 iOS 上最先炸的一条**）：VN 的 `initialize()` 从没跑分页/
/// 连续 shell 都跑的 `_sharedInitViewport`——即重写 `width=device-width` 的视口 meta。
/// 缺了它 WKWebView 按默认 **980 CSS px** 布局再整体缩放到设备宽：iPhone 真机实测
/// `innerWidth=980 / innerHeight=1743`，而 Dart 下发的是 `dartPageWidth=375 /
/// chromeTopInset=44`（逻辑像素），两个坐标系差 ~2.6 倍——正文被缩到约四成大小，
/// 所有按 px 下发的量也全被按错单位解释。Android 的 WebView 默认就是 device-width、
/// 桌面窗口又普遍 ≥980，所以这个缺口**只在 iOS 上显形**。
///
/// 本测试在 live WebView 上锁三条不变式（读 DOM 几何，不依赖截图）：
///   0. `window.innerWidth` 必须等于 Dart 下发的 `--page-width`（两个坐标系重合）；
///   1. VN 首载稳定后 `--chrome-top-inset` 必须 >= 顶部进度条预留（18px），
///      即 inset 真的被推进了 VN 文档；
///   2. VN 当前屏 `.fushi-vn-screen` 的可视区间必须完整落在
///      `[chromeTopInset, innerHeight - chromeBottomInset]` 这条安全带内，
///      即正文不被顶栏/底栏覆盖。
///
/// Run（macOS）：
///   flutter test integration_test/reader_vn_chrome_inset_dom_test.dart -d macos
/// Run（iOS 真机，需 DEVELOPMENT_TEAM 已配好）：
///   flutter test integration_test/reader_vn_chrome_inset_dom_test.dart -d <udid>
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'BUG-1688: VN view-mode honours the reader chrome insets - the VN screen '
      'never renders under the top/bottom chrome',
      timeout: const Timeout(Duration(minutes: 5)),
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[VNINSET] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue, reason: 'Home within 90s');
      await tester.pump(const Duration(seconds: 2));

      // 与 BUG-470 的顶部 inset 测试同理：挤压（非悬浮）模式才真占 18px 预留，
      // 那正是"正文被顶栏压住"能被几何断言捕获的场景。
      expect(ReaderFushiSource.instance.showTopProgressBar, isTrue,
          reason: '顶部阅读进度必须默认开启（本测试的触发条件）。');
      if (ReaderFushiSource.instance.topProgressFloating) {
        ReaderFushiSource.instance.toggleTopProgressFloating();
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(ReaderFushiSource.instance.topProgressFloating, isFalse,
          reason: '本测试需挤压（非悬浮）模式——挤压模式才会占预留带。');

      // 开书**之前**切到 VN view-mode：view_mode 是单一 app 级偏好，per-book
      // ReaderSettings 首载时读它来选 shell（webview.part.dart 的 s.isVnMode）。
      await ReaderFushiSource.instance.setReaderViewMode('vn');
      await tester.pump(const Duration(milliseconds: 500));
      expect(ReaderFushiSource.instance.readerViewMode, 'vn',
          reason: 'VN view-mode 必须在开书前生效，否则装的是分页 shell。');

      await enableFocusNavigation(tester);
      final FocusDriver driver = FocusDriver(tester);

      await _openBooksTab(tester, driver);
      final String bookKey = await _seedTestBook(tester);
      await _openBooksTab(tester, driver);

      // 不断言书架卡片可见：`_activateBook` 走 `AppModel.openMedia`（与卡片 onTap
      // 同一调用）直接把阅读器 push 上栈，书架列表的懒加载/去重命名与本测试无关。
      await _activateBook(tester, bookKey);
      await tester.pump(const Duration(seconds: 3));

      for (int i = 0;
          i < 40 && find.byType(ReaderFushiPage).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.byType(ReaderFushiPage), findsOneWidget,
          reason: 'ReaderFushiPage must mount after openMedia.');

      const Key webViewKey = ValueKey<String>('fushi_webview');
      bool webViewPresent = false;
      for (int i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(webViewKey).evaluate().isNotEmpty) {
          webViewPresent = true;
          break;
        }
        if (i % 20 == 0) debugPrint('[VNINSET] waiting for WebView i=$i');
      }
      expect(webViewPresent, isTrue, reason: 'WebView present');

      const Key contentReadyKey = ValueKey<String>('fushi_content_ready');
      bool contentReady = false;
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
          contentReady = true;
          break;
        }
      }
      expect(contentReady, isTrue, reason: 'Reader content ready within 60s');

      final eval = ReaderFushiPage.debugEvaluateJavascript;
      expect(eval, isNotNull,
          reason: 'Reader debug JS hook must be set (debug/profile build).');

      Future<Map<String, dynamic>> readVnGeometry() async {
        final Object? raw = await eval!(jsVnGeometryProbe);
        final dynamic decoded = jsonDecode(raw.toString());
        return decoded == null
            ? <String, dynamic>{}
            : (decoded as Map<String, dynamic>);
      }

      const double kExpectedReservePx = 18.0;
      Map<String, dynamic> geo = <String, dynamic>{};
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        geo = await readVnGeometry();
        debugPrint('[VNINSET] poll#$i $geo');
        if (geo['vnShell'] == true &&
            geo['screenTop'] != null &&
            ((geo['chromeTopInset'] as num?)?.toDouble() ?? 0) >=
                kExpectedReservePx - 1.0) {
          break;
        }
      }

      debugPrint('[VNINSET] FINAL $geo');

      expect(geo['vnShell'], isTrue,
          reason: 'VN shell 必须真的装上了（找不到 .fushi-vn-stage 说明装的不是 '
              'VN shell，本测试的前提不成立）。实读=$geo');

      final double chromeTopInset =
          (geo['chromeTopInset'] as num?)?.toDouble() ?? -1;
      final double chromeBottomInset =
          (geo['chromeBottomInset'] as num?)?.toDouble() ?? -1;
      final double screenTop = (geo['screenTop'] as num?)?.toDouble() ?? -1;
      final double screenBottom =
          (geo['screenBottom'] as num?)?.toDouble() ?? -1;
      final double innerHeight = (geo['innerHeight'] as num?)?.toDouble() ?? -1;

      // 不变式 0（iOS 上最先炸的那条）：WebView 的 CSS 像素空间必须与 Dart 的逻辑
      // 像素空间重合。缺 `width=device-width` 视口 meta 时 WKWebView 按默认 980 CSS px
      // 布局再整体缩放——iOS 真机实测 `innerWidth=980 / innerHeight=1743` 对
      // `dartPageWidth=375 / dartPageHeight=667`，两个坐标系差 ~2.6 倍：正文缩到约四成
      // 大小，且所有按 px 下发的量（chrome 预留、页面盒、caret inset）全被按错单位解释。
      final double innerWidth = (geo['innerWidth'] as num?)?.toDouble() ?? -1;
      final double pageWidth = (geo['pageWidth'] as num?)?.toDouble() ?? -1;
      expect(pageWidth, greaterThan(0), reason: 'BUG-1688：VN 必须写 --page-width');
      expect((innerWidth - pageWidth).abs(), lessThanOrEqualTo(1.0),
          reason: 'BUG-1688：WebView 视口宽 ($innerWidth CSS px) 必须与 Dart 下发的 '
              '--page-width ($pageWidth 逻辑 px) 一致。不一致 = VN 少注入了 '
              'width=device-width 视口 meta（分页/连续 shell 的 _sharedInitViewport），'
              'WKWebView 退回 980px 布局——iOS 上 VN 不可用的主因。');

      // 不变式 1：VN 文档必须真的收到了 chrome inset。
      expect(chromeTopInset, greaterThanOrEqualTo(kExpectedReservePx - 1.0),
          reason: 'BUG-1688：VN 首载稳定后 --chrome-top-inset 必须 >= 顶部进度条'
              '预留（${kExpectedReservePx}px）。实读=$chromeTopInset。若≈0 说明 VN '
              'shell 的 setChromeInsets 仍是空壳、initialize 也没写这两个变量。');

      // 不变式 2：当前 VN 屏必须完整落在 chrome 安全带内。
      expect(screenTop, greaterThanOrEqualTo(chromeTopInset - 1.0),
          reason: 'BUG-1688：VN 屏顶 ($screenTop) 必须 >= --chrome-top-inset '
              '($chromeTopInset)——否则首行被顶栏压住。');
      expect(screenBottom,
          lessThanOrEqualTo(innerHeight - chromeBottomInset + 1.0),
          reason: 'BUG-1688：VN 屏底 ($screenBottom) 必须 <= 视口高 ($innerHeight) '
              '- --chrome-bottom-inset ($chromeBottomInset)——否则末行被底栏压住。');

      await takeScreenshot(binding, 'bug1688_vn_chrome_inset_verified');

      final NavigatorState nav =
          Navigator.of(tester.element(find.byType(Scaffold).first));
      nav.pop();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      // 还原 view-mode，别把 VN 留给后续测试 / 本机偏好。
      await ReaderFushiSource.instance.setReaderViewMode('paginated');
      await tester.pump(const Duration(milliseconds: 300));

      assertStrictErrors(errors);
      debugPrint('[VNINSET] === BUG-1688 VN CHROME-INSET TEST PASSED ===');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

/// 读 VN 舞台几何：注入的 chrome inset、当前屏 `.fushi-vn-screen` 的 client rect、
/// 以及屏内实际渲染文本的首尾行 rect（后者用于取证，断言只用屏 rect）。
const String jsVnGeometryProbe = r'''
(function(){
  function num(v){ var n = parseFloat(v); return isFinite(n) ? n : 0; }
  var cs = getComputedStyle(document.documentElement);
  var stage = document.querySelector('.fushi-vn-stage');
  var screen = document.querySelector('.fushi-vn-screen');
  var content = document.querySelector('.fushi-vn-content');
  var out = {
    vnShell: !!stage,
    chromeTopInset: num(cs.getPropertyValue('--chrome-top-inset')),
    chromeBottomInset: num(cs.getPropertyValue('--chrome-bottom-inset')),
    pageWidth: num(cs.getPropertyValue('--page-width')),
    pageHeight: num(cs.getPropertyValue('--page-height')),
    innerWidth: window.innerWidth,
    innerHeight: window.innerHeight
  };
  if (screen) {
    var sr = screen.getBoundingClientRect();
    out.screenTop = sr.top;
    out.screenBottom = sr.bottom;
    out.screenHeight = sr.height;
  }
  if (content) {
    var cr = content.getBoundingClientRect();
    out.contentTop = cr.top;
    out.contentBottom = cr.bottom;
    out.contentText = (content.textContent || '').trim().substr(0, 12);
  }
  return JSON.stringify(out);
})()
''';

/// Books 标签置前（home 可能默认别的 tab；书架列表也会懒加载）。
Future<void> _openBooksTab(WidgetTester tester, FocusDriver driver) async {
  final List<Finder> navTargets = findPrimaryNavigationTargets();
  if (navTargets.isEmpty) return;
  final bool focused = await driver.focusWidget(navTargets.first);
  expect(focused, isTrue, reason: 'Books tab must be reachable by focus');
  await driver.activate();
  await tester.pump(const Duration(milliseconds: 500));
}

/// 导入一本全新合成 EPUB（无有声书），返回其 book key。
Future<String> _seedTestBook(WidgetTester tester) async {
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
  final AppModel appModel = container.read(appProvider);
  for (int i = 0; i < 120 && !appModel.isInitialised; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(appModel.isInitialised, isTrue,
      reason: 'AppModel must be initialised before importing a book');

  final Uint8List bytes = EpubGenerator().generate();
  final String bookKey = await EpubImporter.import(
    db: appModel.database,
    bytes: bytes,
    fileName: 'test_vn_chrome_inset.epub',
  );
  debugPrint('[VNINSET] Imported test EPUB as book key=$bookKey');

  container.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
  await tester.pumpAndSettle();
  return bookKey;
}

/// 确定性打开书架书（与 reader_top_progress_inset_dom_test 同一手法，TODO-783）。
Future<void> _activateBook(WidgetTester tester, String bookKey) async {
  final BuildContext appContext =
      tester.element(find.byType(MaterialApp).first);
  final ProviderContainer container = ProviderScope.containerOf(appContext);
  final AppModel appModel = container.read(appProvider);

  final ConsumerStatefulElement appElement = tester
      .element(find.byType(app.FushiReaderApp)) as ConsumerStatefulElement;
  final WidgetRef ref = appElement;

  final MediaItem? item =
      await ReaderFushiSource.instance.mediaItemForBookKey(bookKey);
  expect(item, isNotNull,
      reason: 'Seeded book must resolve to a MediaItem (key=$bookKey)');

  unawaited(appModel.openMedia(
    ref: ref,
    mediaSource: ReaderFushiSource.instance,
    item: item!,
  ));
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}
