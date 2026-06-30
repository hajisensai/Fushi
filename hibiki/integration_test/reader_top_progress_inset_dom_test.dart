import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/media.dart';
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

import 'helpers/focus_driver.dart';
import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'test_helpers.dart';

/// BUG-470 / TODO-975 回归 —— 顶部阅读进度首屏 inset 缺口（real-DOM 验证）。
///
/// 根因：顶部进度预留 (`_topProgressReserve`，默认 18px) 经 `_showTopProgress` 门控，
/// 而后者要求 `_progressTotalChars > 0`；该字段首次置值发生在 `_refreshProgress`，
/// **晚于**首载 setup 脚本注入 `--chrome-top-inset`（此刻 `_readerTopOffset` 只含系统
/// inset、漏掉 18px 进度条预留）。首载后再无路径在「进度由空→正」跃迁上重推 inset，
/// 于是正文首行被顶部进度条压住，直到下次样式/主题/旋屏触发 inset 重推才自愈。
///
/// 修复（navigation.part.dart `_refreshProgress`）：捕获 rebuild 前后的
/// `_showTopProgress`，仅在它 false→true 的上升沿补一次 `_applyChromeInsetsAndReanchor`，
/// 把含 18px 顶部预留的新 `--chrome-top-inset` 推进 WebView，使首行避开进度条。
///
/// 本测试在 live `InAppWebView` 上验证 BUG-470 的核心不变式：首载稳定后，正文第一个
/// 可见文本元素的 `getBoundingClientRect().top` **不小于**注入到 WebView 的
/// `--chrome-top-inset`（即顶部进度条预留确实被推进了文档、正文从预留带之下开始）。
/// 必须走**首载原始路径**（不改字号、不旋屏、不切主题），那正是回归触发条件。
///
/// 顶部进度条本身是 Flutter Positioned 叠层（不是 DOM 元素），它绘制在 WebView 视口
/// 顶部的 `_topProgressReserve` 高度内；唯一被传进 WebView、决定正文起始位置的量就是
/// `--chrome-top-inset`。所以「首行不被压住」⇔「首行 top >= --chrome-top-inset 且
/// --chrome-top-inset >= 进度条预留」。WebView 像素截图在后台可能白框，但本测试只断言
/// DOM 几何读数（可靠），不依赖截图。
///
/// Run（Windows 离屏 harness，默认非阻塞 + 自动挂代理）：
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1
///       integration_test/reader_top_progress_inset_dom_test.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'BUG-470: top progress reserve is pushed into the WebView on first load '
      '- first body line is not covered by the top progress strip',
      timeout: const Timeout(Duration(minutes: 5)),
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[TOPINSET] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue, reason: 'Home within 90s');
      await tester.pump(const Duration(seconds: 2));

      // 顶部进度默认 ON、非悬浮（show_top_progress_bar=true / top_progress_floating
      // =false，见 reader_hibiki_source.dart）——这正是 BUG-470 触发配置，无需改偏好。
      // 显式断言一次，免得默认值被悄悄改掉后测试静默失效。
      expect(ReaderHibikiSource.instance.showTopProgressBar, isTrue,
          reason: '顶部阅读进度必须默认开启（BUG-470 的触发条件）。若默认被改，'
              '此测试需显式经偏好开启 show_top_progress_bar。');
      expect(ReaderHibikiSource.instance.topProgressFloating, isFalse,
          reason: '顶部进度默认应为挤压（非悬浮）模式——挤压模式才会占 18px 预留，'
              '正是 BUG-470 关心的首载 inset 缺口场景。');

      final FocusDriver driver = FocusDriver(tester);

      // Books 标签置前 + 始终导入一本全新 EPUB（无有声书）并打开它，确定性走分页章节
      // 阅读器首载路径（不被书架既有书状态污染）。
      await _openBooksTab(tester, driver);
      final String bookKey = await _seedTestBook(tester);
      await _openBooksTab(tester, driver);

      // 书架条目按 media identifier（hoshi://book/<id>）取键，不是裸 row id。
      final String seededKey =
          'book_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}';
      final Finder seededEntry = find.byKey(ValueKey<String>(seededKey));
      for (int i = 0; i < 40 && seededEntry.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(seededEntry, findsOneWidget,
          reason: 'freshly seeded paginated book must appear on the shelf');

      // 经 AppModel.openMedia 确定性打开（与卡片 onTap 同一调用）。书架卡片的
      // Enter→activate 绑定只在卡片处于 HibikiFocusRoot 下才装上，测试书架没包它，
      // 故焦点驱动 Enter 是 no-op、阅读器永远打不开（见 reader_pagination_test.dart
      // _activateBook / TODO-783）。直接 openMedia 绕过焦点树。
      await _activateBook(tester, bookKey);
      await tester.pump(const Duration(seconds: 3));

      // 先断言 ReaderHibikiPage 真挂载，让「打开失败」显式暴露在这里，而非下游被
      // 误读成 WebView mount 超时。
      for (int i = 0;
          i < 40 && find.byType(ReaderHibikiPage).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.byType(ReaderHibikiPage), findsOneWidget,
          reason: 'ReaderHibikiPage must mount after openMedia — if this '
              'fails the reader never opened (not a WebView timeout).');

      // Cold WebView2 init on a freshly isolated profile (the Windows harness
      // creates an empty webview2-profile per run) can take a while; poll
      // generously and log progress to diagnose a missing WebView.
      const Key webViewKey = ValueKey<String>('hoshi_webview');
      bool webViewPresent = false;
      for (int i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(webViewKey).evaluate().isNotEmpty) {
          webViewPresent = true;
          break;
        }
        if (i % 20 == 0) debugPrint('[TOPINSET] waiting for WebView i=$i');
      }
      expect(webViewPresent, isTrue, reason: 'WebView present');

      const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
      bool contentReady = false;
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
          contentReady = true;
          break;
        }
      }
      expect(contentReady, isTrue, reason: 'Reader content ready within 60s');

      final eval = ReaderHibikiPage.debugEvaluateJavascript;
      expect(eval, isNotNull,
          reason: 'Reader debug JS hook must be set (debug/profile build).');

      // 读取注入到 WebView 的顶部 inset（修复路径推进的就是这个 CSS 变量）。
      Future<double> readChromeTopInset() async {
        final Object? raw = await eval!(
          r'(function(){var v=getComputedStyle(document.documentElement)'
          r".getPropertyValue('--chrome-top-inset');return parseFloat(v)||0;})()",
        );
        return double.tryParse(raw.toString()) ?? -1;
      }

      // 读取正文第一个可见文本元素的 getBoundingClientRect().top（视口坐标）。
      // 跳过零尺寸 / 不可见节点（display:none、空白）；命中第一个有文本且有宽高的
      // 块级元素（EpubGenerator 产出 <p id="mN">【MN】...</p>）。同时回传该元素文本
      // 前缀作为读数取证（确认确实命中正文而非 chrome）。
      Future<Map<String, dynamic>> readFirstTextLine() async {
        final Object? raw = await eval!(jsFirstTextLineProbe);
        final dynamic decoded = jsonDecode(raw.toString());
        return decoded == null
            ? <String, dynamic>{}
            : (decoded as Map<String, dynamic>);
      }

      // 修复经 _refreshProgress 在「进度由空→正」上升沿异步补推 inset + 重锚，
      // 首载稳定后需要给它若干帧落地。轮询直到 inset 稳定 >= 进度条预留，或超时。
      // 进度条预留 = _infoFontSize(12) * 1.5 = 18px（再乘 appUiScale，桌面通常 1.0）。
      const double kExpectedReservePx = 18.0;
      double chromeTopInset = -1;
      Map<String, dynamic> firstLine = <String, dynamic>{};
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        chromeTopInset = await readChromeTopInset();
        firstLine = await readFirstTextLine();
        debugPrint('[TOPINSET] poll#$i chromeTopInset=$chromeTopInset '
            'firstLine=$firstLine');
        if (chromeTopInset >= kExpectedReservePx - 1.0 &&
            firstLine['top'] != null) {
          break;
        }
      }

      final double firstTop = (firstLine['top'] as num?)?.toDouble() ?? -1;
      debugPrint('[TOPINSET] FINAL chromeTopInset=$chromeTopInset '
          'firstLineTop=$firstTop firstLineText=${firstLine['text']} '
          'tag=${firstLine['tag']}');

      expect(firstLine['top'], isNotNull, reason: '必须在 WebView 里定位到正文首个可见文本元素');

      // 核心不变式 1：顶部 inset 必须含进度条预留（首载上升沿补推已落地）。
      // 留 1px 容差兜亚像素 / 缩放四舍五入。
      expect(chromeTopInset, greaterThanOrEqualTo(kExpectedReservePx - 1.0),
          reason: 'BUG-470：首载稳定后 --chrome-top-inset 必须 >= 顶部进度条预留'
              '（${kExpectedReservePx}px）。实读=$chromeTopInset。若仍≈0 说明首载'
              '「进度由空→正」上升沿的 inset 重推未生效——回归未修复。');

      // 核心不变式 2：正文首行 top >= 注入的 inset（正文从预留带之下开始，
      // 不被顶部进度条覆盖）。body padding-top = calc(...vh + var(--chrome-top-inset))，
      // 故首行 top 应 >= inset。留 1px 容差。
      expect(firstTop, greaterThanOrEqualTo(chromeTopInset - 1.0),
          reason: 'BUG-470：正文首行 top($firstTop) 必须 >= --chrome-top-inset'
              '($chromeTopInset)——首行被顶部进度条压住即回归复现。');

      // 核心不变式 3（直接版）：首行 top 必须避开整条进度条预留带。
      expect(firstTop, greaterThanOrEqualTo(kExpectedReservePx - 1.0),
          reason: 'BUG-470：正文首行 top($firstTop) 必须避开顶部进度条预留带'
              '（>= ${kExpectedReservePx}px）。');

      await takeScreenshot(binding, 'bug470_top_progress_inset_verified');

      final NavigatorState nav =
          Navigator.of(tester.element(find.byType(Scaffold).first));
      nav.pop();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      assertStrictErrors(errors);
      debugPrint('[TOPINSET] === BUG-470 TOP-INSET TEST PASSED ===');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

/// 在 WebView 里定位正文首个可见文本块并回传其 client rect（JSON）。抽成顶层常量，
/// 避免 Dart 多行字符串与脚本拼接相互混淆。
const String jsFirstTextLineProbe = r'''
(function(){
  function visible(el){
    var r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    var cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden') return false;
    return (el.textContent || '').trim().length > 0;
  }
  var nodes = document.querySelectorAll('p,div,span,li,blockquote,h1,h2,h3');
  for (var i = 0; i < nodes.length; i++) {
    var el = nodes[i];
    var hasChildBlock = false;
    for (var j = 0; j < el.children.length; j++) {
      if (visible(el.children[j])) { hasChildBlock = true; break; }
    }
    if (hasChildBlock) continue;
    if (!visible(el)) continue;
    var r = el.getBoundingClientRect();
    return JSON.stringify({
      top: r.top,
      bottom: r.bottom,
      tag: el.tagName,
      text: (el.textContent || '').trim().substr(0, 12)
    });
  }
  return JSON.stringify(null);
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
    fileName: 'test_top_progress_inset.epub',
  );
  debugPrint('[TOPINSET] Imported test EPUB as book key=$bookKey');

  container.invalidate(hibikiBooksProvider(appModel.targetLanguage));
  await tester.pumpAndSettle();
  return bookKey;
}

/// 确定性打开书架书（与 reader_pagination_test._activateBook 同一手法）：书架卡片的
/// Enter→activate→openMedia 绑定只在卡片处于 HibikiFocusRoot 下才装上，测试书架没包它，
/// 故焦点驱动 Enter 是 no-op、阅读器永远打不开（TODO-783）。绕过焦点树：从 key 解析
/// MediaItem，直接驱动 AppModel.openMedia（与真实卡片 tap 同一调用），把 ReaderHibikiPage
/// push 上导航栈，与焦点树状态无关。
Future<void> _activateBook(WidgetTester tester, String bookKey) async {
  final BuildContext appContext =
      tester.element(find.byType(MaterialApp).first);
  final ProviderContainer container = ProviderScope.containerOf(appContext);
  final AppModel appModel = container.read(appProvider);

  // openMedia 需要 WidgetRef 但打开路径不解引用它（经 app 的 navigatorKey context
  // 路由，非 ref）。根 HoshiReaderApp 是 ConsumerStatefulWidget，其 element 即 WidgetRef。
  final ConsumerStatefulElement appElement = tester
      .element(find.byType(app.HoshiReaderApp)) as ConsumerStatefulElement;
  final WidgetRef ref = appElement;

  final MediaItem? item =
      await ReaderHibikiSource.instance.mediaItemForBookKey(bookKey);
  expect(item, isNotNull,
      reason: 'Seeded book must resolve to a MediaItem (key=$bookKey)');

  // 不 await openMedia 到完成：它 await Navigator.push，其 future 只在阅读器路由被 pop
  // 时才 resolve，await 会永久阻塞线性测试体。fire 它（与真实卡片 onTap 同一调用）并
  // pump 帧让 push + 阅读器异步 _initBook 跑起来；路由生命周期 future 故意不 await。
  unawaited(appModel.openMedia(
    ref: ref,
    mediaSource: ReaderHibikiSource.instance,
    item: item!,
  ));
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}
