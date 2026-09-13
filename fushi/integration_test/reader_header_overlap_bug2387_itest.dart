import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi/main.dart' as app;
import 'package:fushi/media.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show kReaderDesktopHeaderHeight;

import 'helpers/focus_driver.dart';
import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'test_helpers.dart';

/// BUG-2387 回归 —— 顶部工具栏压住正文首行（real-DOM + 真渲染树几何验证）。
///
/// 根因：顶部工具栏是 `Positioned(top: _stableTopInset)` 的**不透明**叠层、固定高
/// [kReaderDesktopHeaderHeight]=48；而正文内容盒起点
/// = `marginTop`(默认 0vh) + `--chrome-top-inset`。悬浮态下
/// `readerDesktopHeaderReserve` 曾恒返回 0（照抄底栏 / 顶部进度的悬浮模型），
/// 于是 `--chrome-top-inset == _stableTopInset` —— **与工具栏起点相同**，那 48px
/// 整条压在正文首行上。
///
/// 用户报告场景是手机小窗/分屏，但**与分屏无关**：修复前实测重叠在
/// Android API34 全屏（`OVERLAP=48.01`，vpTop=49.45 / cssInset=49.45）与
/// Windows 桌面（`OVERLAP=48.0`，两者皆 0）**都是满 48px**。小窗只是让它更刺眼
/// ——可读行数本就少，被吃掉一行占比大得多。
///
/// BUG-2387 当时的修法是删掉 `floating → 0`、让悬浮态也恒定预留 48px；代价是
/// 顶栏收起后正文顶上常驻一条空带。**2026-09-13 用户拍板改回**：悬浮态「隐藏满屏、
/// 唤出盖在正文上」（顶栏半透明），`floating → 0` 恢复。本测试的契约随之改为：
///  * 悬浮态 `--chrome-top-inset == 系统顶 inset`（正文满屏，不给顶栏让位）；
///  * 唤出时顶栏**恰好**盖住正文顶部一条 [kReaderDesktopHeaderHeight]（这是有意
///    的覆盖，不是重叠 bug）；
///  * 显隐多次不改 `--chrome-top-inset`（「悬浮显隐不重锚」设计律不受影响）。
/// 挤压态「不盖字」由 reader_desktop_chrome_test 的纯函数契约钉住。
///
/// 本测试在默认（悬浮）配置下唤出工具栏，量三件事：
///  1. `--chrome-top-inset`（注入 WebView 的正文顶部让位）；
///  2. 正文首个可见文本元素的 client rect（DOM 坐标）；
///  3. 工具栏与 WebView 的 Flutter 渲染树 rect（逻辑坐标）。
///
/// DOM→逻辑坐标的换算比**实测**（WebView widget 高 / documentElement.clientHeight），
/// 不假设 1:1 —— 阅读器 WebView 有自己的缩放，硬套会得到「可信但错」的读数。
///
/// 修复后实测（Android API34）：cssInset 49.45→97.45、正文首行正好落在工具栏下沿
/// （firstTopLogical 97.44 vs header.bottom 97.45），`OVERLAP=0.01`、
/// `ABOVE_BAR=-47.99`（负值 = 工具栏那条带是空白）。
///
/// Run（Windows 离屏 harness）：
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1
///       -Target integration_test/reader_header_overlap_bug2382_itest.dart
/// Run（Android 模拟器）：
///   flutter test integration_test/reader_header_overlap_bug2382_itest.dart \
///       -d emulator-5554 --no-pub
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('BUG-2387 契约 2026-09-13：悬浮顶栏隐藏满屏、唤出恰好覆盖正文顶部',
      timeout: const Timeout(Duration(minutes: 6)),
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[HDROVL] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: 'Home within 90s');
      await tester.pump(const Duration(seconds: 2));

      // 默认配置就是本 bug 的触发条件：底栏/顶栏悬浮 + marginTop 默认 0vh。
      // 显式断言默认没被改，否则读数说明不了问题。
      expect(ReaderFushiSource.instance.tapEmptyToHideChrome, isTrue,
          reason: '本探针要的是悬浮态（默认）。tap_empty_hide_chrome 默认必须为 true。');

      await enableFocusNavigation(tester);
      final FocusDriver driver = FocusDriver(tester);

      await _openBooksTab(tester, driver);
      final String bookKey = await _seedTestBook(tester);

      // 不经书架卡片：_activateBook 直接驱动 AppModel.openMedia（与卡片 onTap 同一
      // 调用），书架列表是否已刷出与本探针要量的几何无关。
      await _activateBook(tester, bookKey);
      await tester.pump(const Duration(seconds: 3));

      for (int i = 0;
          i < 40 && find.byType(ReaderFushiPage).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.byType(ReaderFushiPage), findsOneWidget,
          reason: 'ReaderFushiPage must mount after openMedia');

      const Key webViewKey = ValueKey<String>('fushi_webview');
      bool webViewPresent = false;
      for (int i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(webViewKey).evaluate().isNotEmpty) {
          webViewPresent = true;
          break;
        }
        if (i % 20 == 0) debugPrint('[HDROVL] waiting for WebView i=$i');
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
      expect(eval, isNotNull, reason: 'Reader debug JS hook must be set');

      Future<double> readNumber(String expr) async {
        final Object? raw = await eval!('(function(){return $expr;})()');
        return double.tryParse(raw.toString()) ?? double.nan;
      }

      Future<Map<String, dynamic>> readFirstTextLine() async {
        final Object? raw = await eval!(jsFirstTextLineProbe);
        final dynamic decoded = jsonDecode(raw.toString());
        return decoded == null
            ? <String, dynamic>{}
            : (decoded as Map<String, dynamic>);
      }

      // 唤出悬浮 chrome：走真 JS 桥的 onTapEmpty（与用户点空白同一入口）。
      await eval!(
        'setTimeout(function(){window.flutter_inappwebview.callHandler('
        "'onTapEmpty');},0)",
      );

      const Key headerKey = ValueKey<String>('fushi_desktop_header');
      bool headerVisible = false;
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find.byKey(headerKey).evaluate().isNotEmpty) {
          headerVisible = true;
          break;
        }
      }
      expect(headerVisible, isTrue,
          reason: 'onTapEmpty 必须唤出悬浮顶部工具栏（fushi_desktop_header）');

      // ── 测量 ─────────────────────────────────────────────────────────
      // 一次采样：读 Flutter 渲染树几何 + WebView DOM 几何，换算到同一坐标系。
      // DOM→逻辑坐标比实测（webView 高 / clientHeight），不假设 1:1。
      // 悬浮 chrome 3s 自动收起，每次采样前重新唤出并等它入树。
      Future<bool> revealHeader() async {
        for (int attempt = 0; attempt < 3; attempt++) {
          await eval(
            'setTimeout(function(){window.flutter_inappwebview.callHandler('
            "'onTapEmpty');},0)",
          );
          for (int i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            if (find.byKey(headerKey).evaluate().isNotEmpty) return true;
          }
        }
        return false;
      }

      Future<_Sample?> sample(String tag) async {
        if (!await revealHeader()) {
          debugPrint('[HDROVL] $tag: 工具栏唤不出，跳过本次采样');
          return null;
        }
        final Rect headerRect = tester.getRect(find.byKey(headerKey));
        final Rect webViewRect = tester.getRect(find.byKey(webViewKey));
        final EdgeInsets viewPadding =
            MediaQuery.viewPaddingOf(tester.element(find.byKey(webViewKey)));
        final double chromeTopInset = await readNumber(
          r'parseFloat(getComputedStyle(document.documentElement)'
          r".getPropertyValue('--chrome-top-inset'))||0",
        );
        final double clientHeight =
            await readNumber('document.documentElement.clientHeight');
        final Map<String, dynamic> firstLine = await readFirstTextLine();
        final double firstTopCss = (firstLine['top'] as num?)?.toDouble() ?? -1;
        final double scale =
            clientHeight > 0 ? webViewRect.height / clientHeight : double.nan;
        final double firstTopLogical = webViewRect.top + firstTopCss * scale;
        final _Sample s = _Sample(
          tag: tag,
          windowSize: tester.view.physicalSize / tester.view.devicePixelRatio,
          viewPaddingTop: viewPadding.top,
          headerRect: headerRect,
          webViewRect: webViewRect,
          chromeTopInset: chromeTopInset,
          firstTopCss: firstTopCss,
          firstTopLogical: firstTopLogical,
          firstText: '${firstLine['text']}',
        );
        debugPrint('[HDROVL] $s');
        return s;
      }

      final _Sample? baseline = await sample('BASELINE');
      expect(baseline, isNotNull, reason: '基线采样必须成功（工具栏可唤出、正文可定位）');
      expect(baseline!.firstTopCss, greaterThanOrEqualTo(0),
          reason: '必须在 WebView 里定位到正文首个可见文本元素');

      // 再采几次确认读数稳定（悬浮 chrome 3s 自动收起 → 每次采样前重新唤出，
      // 顺带验证「显隐不改预留高」：多次采样的 header/inset 必须一致）。
      const int kPolls = 3;
      _Sample last = baseline;
      for (int i = 0; i < kPolls; i++) {
        for (int f = 0; f < 12; f++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        final _Sample? s = await sample('POLL#$i');
        if (s != null) {
          expect(s.chromeTopInset, closeTo(baseline.chromeTopInset, 1.0),
              reason: '悬浮 chrome 的显隐不得改变 --chrome-top-inset（不重锚设计律）。'
                  'baseline=${baseline.chromeTopInset} now=${s.chromeTopInset}');
          last = s;
        }
      }

      await takeScreenshot(binding, 'header_overlap_probe');

      debugPrint('[HDROVL] === FINAL ===');
      debugPrint('[HDROVL] $last');

      // 不变式 1（悬浮态正文满屏）：正文顶部让位只有系统顶 inset，没有顶栏那 48px。
      expect(last.chromeTopInset, closeTo(last.viewPaddingTop, 1.0),
          reason: '悬浮态 --chrome-top-inset 必须等于系统顶 inset（隐藏满屏）；'
              '多出来的就是 BUG-2387 时代那条常驻空带。$last');

      // 不变式 2（唤出即覆盖）：顶栏上沿之上不露正文，下沿正好盖住正文顶部一条
      // 顶栏高——覆盖是悬浮态的语义，不是重叠 bug。
      expect(last.aboveBar, lessThanOrEqualTo(1.0),
          reason: '工具栏上沿(${last.headerRect.top}) 之上露出了正文'
              '（首行上沿 ${last.firstTopLogical}），露出 ${last.aboveBar} 逻辑 px。$last');
      expect(last.overlap, closeTo(kReaderDesktopHeaderHeight, 2.0),
          reason: '悬浮顶栏唤出时应恰好盖住正文顶部 $kReaderDesktopHeaderHeight px'
              '（实测重叠 ${last.overlap}）。$last');

      final NavigatorState nav =
          Navigator.of(tester.element(find.byType(Scaffold).first));
      nav.pop();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      assertStrictErrors(errors);
      debugPrint('[HDROVL] === BUG-2387 HEADER OVERLAP TEST PASSED ===');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

/// 一次几何采样。所有量都换算到 Flutter 逻辑坐标系，便于直接相减。
class _Sample {
  const _Sample({
    required this.tag,
    required this.windowSize,
    required this.viewPaddingTop,
    required this.headerRect,
    required this.webViewRect,
    required this.chromeTopInset,
    required this.firstTopCss,
    required this.firstTopLogical,
    required this.firstText,
  });

  final String tag;
  final Size windowSize;
  final double viewPaddingTop;
  final Rect headerRect;
  final Rect webViewRect;
  final double chromeTopInset;
  final double firstTopCss;
  final double firstTopLogical;
  final String firstText;

  /// >0 = 工具栏**上方**露出正文（那条带本该空白）——用户报的症状。
  double get aboveBar => headerRect.top - firstTopLogical;

  /// >0 = 工具栏**压住**正文首行。
  double get overlap => headerRect.bottom - firstTopLogical;

  /// 非 0 = Flutter 按一个 inset 画栏、WebView 按另一个 inset 排字。
  double get insetMismatch => viewPaddingTop - chromeTopInset;

  @override
  String toString() => '$tag win=${windowSize.width.toStringAsFixed(1)}x'
      '${windowSize.height.toStringAsFixed(1)} '
      'vpTop=${viewPaddingTop.toStringAsFixed(2)} '
      'header=[${headerRect.top.toStringAsFixed(2)},'
      '${headerRect.bottom.toStringAsFixed(2)}] '
      'webViewTop=${webViewRect.top.toStringAsFixed(2)} '
      'cssInset=${chromeTopInset.toStringAsFixed(2)} '
      'firstTopCss=${firstTopCss.toStringAsFixed(2)} '
      'firstTopLogical=${firstTopLogical.toStringAsFixed(2)} '
      'ABOVE_BAR=${aboveBar.toStringAsFixed(2)} '
      'OVERLAP=${overlap.toStringAsFixed(2)} '
      'insetMismatch=${insetMismatch.toStringAsFixed(2)} '
      'text="$firstText"';
}

/// 在 WebView 里定位正文首个可见文本块并回传其 client rect（JSON）。
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

Future<void> _openBooksTab(WidgetTester tester, FocusDriver driver) async {
  final List<Finder> navTargets = findPrimaryNavigationTargets();
  if (navTargets.isEmpty) return;
  final bool focused = await driver.focusWidget(navTargets.first);
  expect(focused, isTrue, reason: 'Books tab must be reachable by focus');
  await driver.activate();
  await tester.pump(const Duration(milliseconds: 500));
}

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
    fileName: 'test_header_overlap.epub',
  );
  debugPrint('[HDROVL] Imported test EPUB as book key=$bookKey');

  container.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
  await tester.pumpAndSettle();
  return bookKey;
}

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
