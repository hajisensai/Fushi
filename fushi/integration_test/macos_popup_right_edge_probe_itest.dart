import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart'
    show
        openBookViaProductionPath,
        readyAppModel,
        seedDictionary,
        seedReaderBook;
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-2871 macOS 真机取证：阅读器查词浮层右缘的白色竖条。
///
/// 白条只在「App 深色主题 + 系统浅色外观」下可见：浮层文档是深色，popup.css 的
/// 8px 经典 `::-webkit-scrollbar` 槽位轨道透明，槽位里透出的是 WKWebView 自己的
/// 默认底色（浅色外观下为白色）。本用例真实点词弹出浮层、把释义撑到可滚动，
/// 再用 `screencapture -l` 抓**合成后**的真实窗口像素。Flutter 帧抓图不含平台
/// 视图纹理，在本 bug 上只会给假绿。
///
/// 窗口必须在前台：macOS 不给被遮挡的窗口发 vsync，pump 会一直挂着；
/// 隐藏模式（HIBIKI_TEST_HIDDEN）下 WKWebView 也不渲染。
///
/// Run（在 Mac 上、可见窗口、系统浅色外观）：
///   FUSHI_TEST_INPUT=1 FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root \
///     flutter test integration_test/macos_popup_right_edge_probe_itest.dart \
///     -d macos --no-pub --dart-define=FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root
const MethodChannel _input = MethodChannel('app.fushi.test/input');
const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');

Future<Map<Object?, Object?>> _call(
  String method, [
  Map<String, Object?> args = const <String, Object?>{},
]) async {
  final dynamic raw = await _input.invokeMethod<dynamic>(method, args);
  return (raw as Map).cast<Object?, Object?>();
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label,
) async {
  for (int i = 0; i < 120; i++) {
    if (ready()) return;
    await tester.pump(const Duration(milliseconds: 500));
  }
  fail('timed out waiting for $label');
}

Future<dynamic> _popupEval(String source) async =>
    ReaderFushiPage.debugEvaluateTopPopup?.call(source);

Future<bool> _waitPopup(WidgetTester tester) async {
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    final dynamic t = await _popupEval(
      "(document.body && document.body.innerText || '').indexOf('testword') >= 0",
    );
    if (t == true || t == 1 || t == 'true') return true;
  }
  return false;
}

/// 抓真窗口像素（需要屏幕录制授权；缺了文件不产出）。
Future<File?> _shot(int windowNumber, String name) async {
  final File file = File('${observeScreenshotDir().path}/$name.png');
  final ProcessResult r = await Process.run('screencapture', <String>[
    '-x',
    '-o',
    '-l',
    '$windowNumber',
    file.path,
  ]);
  debugPrint('[edge-probe] $name exit=${r.exitCode} ${file.path}');
  return file.existsSync() ? file : null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('BUG-2871: macOS lookup popup right edge has no white bar', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    await _call('activate');
    expect(await waitForHome(tester), isTrue, reason: 'home must render');
    await tester.pump(const Duration(seconds: 2));
    expect(await seedDictionary(tester), isTrue);
    await (await readyAppModel(tester)).themeNotifier.setBrightnessMode('dark');

    final String bookKey = await seedReaderBook(
      tester,
      fileName: 'bug2871_mac_popup_edge.epub',
    );
    await openBookViaProductionPath(tester, bookKey);
    await _waitFor(
      tester,
      () => find.byKey(_kWebViewKey).evaluate().isNotEmpty,
      'reader WebView',
    );
    await _waitFor(
      tester,
      () => find.byKey(_kContentReadyKey).evaluate().isNotEmpty,
      'reader content',
    );
    await _waitFor(tester, readerWebViewReady, 'reader debug hooks');
    await tester.pump(const Duration(seconds: 2));

    final Map<Object?, Object?> act = await _call('activate');
    debugPrint('[edge-probe] activate=$act');
    final int windowNumber = (act['windowNumber'] as num).toInt();

    final dynamic rectRaw = await ReaderFushiPage.debugEvaluateJavascript!('''
      (function() {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        var n; while ((n = walker.nextNode())) {
          var i = n.textContent.indexOf('testword');
          if (i >= 0) {
            var r = document.createRange();
            r.setStart(n, i); r.setEnd(n, i + 8);
            var b = r.getBoundingClientRect();
            if (b.width > 0 && b.height > 0)
              return JSON.stringify({x: b.left, y: b.top, w: b.width, h: b.height});
          }
        }
        return null;
      })()
    ''');
    expect(rectRaw, isNotNull, reason: 'testword must be laid out on screen');
    final Map<String, double> rect = <String, double>{
      for (final Match m in RegExp(
        r'"(x|y|w|h)":\s*(-?[\d.]+)',
      ).allMatches(rectRaw.toString()))
        m.group(1)!: double.parse(m.group(2)!),
    };
    final Offset origin = tester.getTopLeft(find.byKey(_kWebViewKey));
    await _call('click', <String, Object?>{
      'x': origin.dx + rect['x']! + rect['w']! / 2,
      'y': origin.dy + rect['y']! + rect['h']! / 2,
    });
    expect(await _waitPopup(tester), isTrue, reason: '点 testword 必须弹出查词浮层');

    // 把释义撑长到可滚动——只有可滚动时文档才有垂直滚动条槽位。
    final dynamic appended = await _popupEval('''
      (function(){
        var c = document.getElementById('entries-container');
        var e = c.querySelector('.entry');
        for (var i = 0; i < 12; i++) c.appendChild(e.cloneNode(true));
        return c.children.length;
      })()
    ''');
    debugPrint('[edge-probe] appended entries=$appended');
    await tester.pump(const Duration(milliseconds: 300));
    final File? shot = await _shot(windowNumber, 'bug2871-popup-right-edge');
    debugPrint('[edge-probe] shot=${shot?.path}');
    final dynamic dom = await _popupEval('''
      JSON.stringify({
        inner: innerWidth,
        client: document.documentElement.clientWidth,
        scrollH: document.scrollingElement.scrollHeight,
        innerH: innerHeight,
        theme: document.documentElement.getAttribute('data-theme')
      })
    ''');
    debugPrint('[edge-probe] dom=$dom');

    final Finder popup = find.byType(DictionaryPopupWebView);
    expect(popup, findsWidgets);
    final Rect webRect = tester.getRect(popup.last);
    debugPrint('[edge-probe] popup webview rect=$webRect');

    await tester.pump(const Duration(seconds: 1));
  });
}
