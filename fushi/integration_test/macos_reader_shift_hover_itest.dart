import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/media/sources/reader_fushi_source.dart'
    show ReaderFushiSource;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;

import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, seedDictionary, seedReaderBook;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-2508 macOS 真机取证：阅读器 Shift-悬停查词 / Shift 按下即查。
///
/// 输入不走 `tester` 合成事件（那会跳过要验的嵌入层），而是经 macOS Runner 的
/// `app.fushi.test/input` 钩子（`FUSHI_TEST_INPUT` 门控）送真实 `NSEvent`：
/// * 点击 / flagsChanged 走 `NSApp.postEvent`（AppKit 正常派发到命中视图 / 第一响应者）；
/// * hover 用 `flutter` 模式直接交 `FlutterViewController.mouseMoved`——AppKit 只给
///   WindowServer 产生的事件派 tracking area，进程内合成的到不了那一跳（ssh 会话
///   无辅助功能授权，CGEvent 也投不进去）；从 VC 往下的修饰键同步、Flutter hover、
///   `MouseRegion`、JS `selectText`、真弹窗全是真路径。
/// 测试绑定默认丢弃设备来源指针事件，须 `shouldPropagateDevicePointerEvents = true`。
///
/// 2026-09-13 Mac（macOS 27.0 / 1470×867 窗口）实测：`dumpViews` 显示 desktop_drop 的
/// `DropTarget`（整窗 NSView）是 FlutterViewWrapper 里**最顶**的子视图，压在
/// FlutterView 与全部平台视图之上，AppKit 命中测试在正文任何一点都返回 DropTarget
/// → WebKit `WKMouseTrackingObserver` 的「WKWebView 是最顶视图」门永远不过 →
/// 正文 DOM `mousemove` 计数恒 0（点击经引擎转发仍能到 DOM）。这就是 JS 腿在
/// macOS 上死掉的直接原因；宿主腿不经这道门。
///
/// 证据：
///   ⓪ 对照：真 NSEvent 点击 testword → DOM `mousedown`=1、弹窗出现（点击路径没坏）；
///   ① 按住 Shift 横扫正文 → 弹窗出现且释义含 `testword`；DOM `mousemove` 计数 0，
///      AppKit 命中视图 DropTarget；
///   ③ 松开 Shift 纯悬停 → 不查词（门控没被打穿）；
///   ② 光标停在词上、按一下 Shift → 弹窗出现（BUG-880 同款静止反查）；
///   ④ 「悬停即查词」开着 → 不按 Shift 纯悬停出词。
///
/// Run（在 Mac 上、可见窗口）：
///   FUSHI_TEST_INPUT=1 FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root \
///     flutter test integration_test/macos_reader_shift_hover_itest.dart -d macos \
///     --no-pub --dart-define=FUSHI_TEST_ROOT=$HOME/dev/fushi-test-root

const MethodChannel _input = MethodChannel('app.fushi.test/input');
const Key _kWebViewKey = ValueKey<String>('fushi_webview');
const Key _kContentReadyKey = ValueKey<String>('fushi_content_ready');

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int maxPolls = 120,
}) async {
  for (int i = 0; i < maxPolls; i++) {
    if (ready()) return;
    await tester.pump(const Duration(milliseconds: 500));
  }
  fail('timed out waiting for $label');
}

Future<Map<Object?, Object?>> _call(
  String method, [
  Map<String, Object?> args = const <String, Object?>{},
]) async {
  final dynamic raw = await _input.invokeMethod<dynamic>(method, args);
  return (raw as Map).cast<Object?, Object?>();
}

/// 顶层弹窗是否可见且释义里含 [needle]。`debugEvaluateTopPopup` 无弹窗时返 null。
Future<bool> _popupShows(String needle) async {
  final Future<dynamic> Function(String)? evalTop =
      ReaderFushiPage.debugEvaluateTopPopup;
  if (evalTop == null) return false;
  try {
    final dynamic raw = await evalTop(
      "(document.body && document.body.innerText || '').indexOf('$needle') >= 0",
    );
    return raw == true || raw == 'true' || raw == 1;
  } catch (_) {
    return false;
  }
}

/// 真窗口像素：`screencapture -l <windowNumber>`（不需要辅助功能授权；需要屏幕录制
/// 授权，缺了文件不产出但不抛）。
Future<String> _shotWindow(int windowNumber, String name) async {
  final String path = '${observeScreenshotDir().path}/$name.png';
  try {
    final ProcessResult r = await Process.run(
      'screencapture',
      <String>['-x', '-o', '-l', '$windowNumber', path],
    );
    final bool ok = r.exitCode == 0 && File(path).existsSync();
    return ok ? '$path (${File(path).lengthSync()} bytes)' : 'failed: exit=${r.exitCode} ${r.stderr}';
  } catch (e) {
    return 'failed: $e';
  }
}

Future<bool> _waitPopup(
  WidgetTester tester,
  String needle, {
  int maxPolls = 40,
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (await _popupShows(needle)) return true;
  }
  return false;
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'BUG-2508: macOS reader Shift-hover lookup via real NSEvents',
    timeout: const Timeout(Duration(minutes: 12)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'mac-shift-hover',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue, reason: 'home must render');
          await tester.pump(const Duration(seconds: 2));

          expect(await seedDictionary(tester), isTrue,
              reason: 'generated test dictionary must be installed');
          final String bookKey = await seedReaderBook(
            tester,
            fileName: 'bug2508_mac_shift_hover.epub',
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
          await _waitFor(tester, readerWebViewReady, 'reader debug hooks',
              maxPolls: 20);
          await tester.pump(const Duration(seconds: 2));

          final Future<dynamic> Function(String)? runJs =
              ReaderFushiPage.debugEvaluateJavascript;
          expect(runJs, isNotNull, reason: 'reader must expose the JS hook');

          // LiveTestWidgetsFlutterBinding 默认把「设备来源」的指针事件整个丢掉（只放行
          // tester 合成事件）；本测试要的恰是嵌入层送来的真 hover，必须放行。测试结束
          // 前必须复原，否则 binding 在收尾时报「值被测试改了」。
          binding.shouldPropagateDevicePointerEvents = true;
          // 该值的复原检查在 test body 结束时、addTearDown 之前跑，所以只能在 body
          // 里自己 finally 复原。
          try {
            await _drive(tester, runJs!);
          } finally {
            binding.shouldPropagateDevicePointerEvents = false;
          }
        },
      );
    },
  );
}

/// 计数器用可变盒子跨函数共享。
class _Counter {
  int value = 0;
  String last = '';
}

Future<void> _drive(
  WidgetTester tester,
  Future<dynamic> Function(String) runJs,
) async {
  // Flutter 侧收到了什么：全局指针路由数 hover，HardwareKeyboard 数键事件。
  final _Counter hoverSeenBox = _Counter();
  final _Counter keySeenBox = _Counter();
  void route(PointerEvent e) {
    if (e is PointerHoverEvent) hoverSeenBox.value++;
  }
  bool keyHandler(KeyEvent e) {
    keySeenBox.value++;
    keySeenBox.last = '${e.runtimeType}:${e.logicalKey.debugName} synth=${e.synthesized}';
    return false;
  }
  GestureBinding.instance.pointerRouter.addGlobalRoute(route);
  HardwareKeyboard.instance.addHandler(keyHandler);
  addTearDown(() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(route);
    HardwareKeyboard.instance.removeHandler(keyHandler);
  });

  // 让窗口成为 key window：两边的 tracking area 都是 ActiveInKeyWindow。
  final Map<Object?, Object?> act = await _call('activate');
  debugPrint('[mac-shift-hover] activate=$act');
  await tester.pump(const Duration(milliseconds: 800));
  final Map<Object?, Object?> act2 = await _call('activate');
  debugPrint('[mac-shift-hover] activate(2)=$act2');
  expect(act2['isKey'], isTrue,
      reason: '窗口必须是 key window，否则 tracking area 根本不激活');

  final Map<Object?, Object?> views = await _call('dumpViews');
  debugPrint('[mac-shift-hover] views:\n${views['views']}');

  // DOM 侧 mousemove 计数：根因证据（macOS 上宿主腿平台，JS 腿已让路，
  // 这里只是数事件到没到 DOM）。
  await runJs('''
    window.__mm = 0; window.__mmShift = 0;
    document.addEventListener('mousemove', function(e) {
      window.__mm++; if (e.shiftKey) window.__mmShift++;
    }, true);
    'ok'
  ''');

  // 第一个 testword 的 CSS 视口矩形 → WebView 局部 == 窗口内容坐标偏移。
  final dynamic rectRaw = await runJs('''
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
  debugPrint('[mac-shift-hover] testword rect=$rectRaw');
  expect(rectRaw, isNotNull, reason: 'testword must be laid out on screen');
  final RegExp numRe = RegExp(r'"(x|y|w|h)":\s*(-?[\d.]+)');
  final Map<String, double> rect = <String, double>{
    for (final Match m in numRe.allMatches(rectRaw.toString()))
      m.group(1)!: double.parse(m.group(2)!),
  };
  final Offset webViewTopLeft = tester.getTopLeft(find.byKey(_kWebViewKey));
  final double wordY = webViewTopLeft.dy + rect['y']! + rect['h']! / 2;
  final double wordX0 = webViewTopLeft.dx + rect['x']! + 2;
  final double wordX1 = webViewTopLeft.dx + rect['x']! + rect['w']! - 2;
  debugPrint('[mac-shift-hover] webView@$webViewTopLeft word x=[$wordX0..$wordX1] y=$wordY');

  // ── ⓪ 对照：真 NSEvent 点击 testword，看点击这条路到不到 WKWebView ──
  await runJs("window.__md = 0; document.addEventListener('mousedown', function(){window.__md++;}, true); 'ok'");
  expect(await _popupShows('testword'), isFalse, reason: '起点无弹窗');
  final Map<Object?, Object?> clk = await _call(
    'click',
    <String, Object?>{'x': (wordX0 + wordX1) / 2, 'y': wordY},
  );
  final bool clickPopup = await _waitPopup(tester, 'testword', maxPolls: 20);
  final dynamic md = await runJs('window.__md');
  debugPrint('[mac-shift-hover] ⓪ click popup=$clickPopup domMousedown=$md $clk');
  if (clickPopup) {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (int i = 0; i < 12 && await _popupShows('testword'); i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (i == 6) await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    }
  }
  await tester.pump(const Duration(milliseconds: 500));

  // ── ① 按住 Shift 横扫正文 ────────────────────────────────────
  expect(await _popupShows('testword'), isFalse, reason: '起点无弹窗');
  // 三种投递方式逐个试，直到 Flutter 侧看见 Shift（诊断投递路径）。
  Map<Object?, Object?> fc = <Object?, Object?>{};
  for (final String m in <String>['post', 'flutter']) {
    fc = await _call('flagsChanged', <String, Object?>{'shift': true, 'mode': m});
    await tester.pump(const Duration(milliseconds: 300));
    debugPrint('[mac-shift-hover] flagsChanged(shift, mode=$m) $fc '
        'shiftHeld=${HardwareKeyboard.instance.isShiftPressed} keySeen=${keySeenBox.value} last=${keySeenBox.last}');
    if (HardwareKeyboard.instance.isShiftPressed) break;
  }
  final List<String> hits = <String>[];
  const String mode = String.fromEnvironment('FUSHI_TEST_INPUT_MODE',
      defaultValue: 'flutter');
  debugPrint('[mac-shift-hover] delivery mode=$mode');
  for (double x = wordX0 - 24; x <= wordX1; x += 6) {
    final Map<Object?, Object?> r = await _call(
      'mouseMove',
      <String, Object?>{'x': x, 'y': wordY, 'shift': true, 'mode': mode},
    );
    hits.add('${r['hit']}');
    if (hits.length == 1) debugPrint('[mac-shift-hover] hit chain: ${r['chain']}');
    await tester.pump(const Duration(milliseconds: 40));
  }
  final bool hoverPopup = await _waitPopup(tester, 'testword');
  final dynamic mm = await runJs('JSON.stringify({mm: window.__mm, shift: window.__mmShift})');
  debugPrint('[mac-shift-hover] ① popup=$hoverPopup domMousemove=$mm '
      'shiftHeld=${HardwareKeyboard.instance.isShiftPressed} '
      'flutterHoverSeen=${hoverSeenBox.value} keySeen=${keySeenBox.value} hits=${hits.toSet()}');
  final int windowNumber = (act2['windowNumber'] as num).toInt();
  debugPrint('[mac-shift-hover] shot1=${await _shotWindow(windowNumber, 'bug2508-01-shift-hover')}');
  // 正文 WebView 自己的快照（WKWebView takeSnapshot，不需要屏幕录制授权）：被查词
  // 的高亮就在里面；弹窗释义文本另抓一段进日志。
  final ObserveShot web1 = await captureReaderWebView('bug2508-01-reader-webview');
  final dynamic popupText = await ReaderFushiPage.debugEvaluateTopPopup
      ?.call("(document.body.innerText || '').replace(/\\s+/g, ' ').slice(0, 160)");
  debugPrint('[mac-shift-hover] reader-webview shot=${web1.path} nonBlank=${web1.nonBlank} '
      'popupText="$popupText"');
  expect(hoverPopup, isTrue,
      reason: '按住 Shift 扫过 testword 必须弹出含 testword 的查词弹窗');

  // ── 收口：松 Shift、Esc 关弹窗 ─────────────────────────────
  await _call('flagsChanged', <String, Object?>{'shift': false, 'mode': mode});
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  for (int i = 0; i < 12 && await _popupShows('testword'); i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (i == 6) await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  }
  expect(await _popupShows('testword'), isFalse, reason: 'Esc 必须关掉弹窗');

  // ── ③ 松开 Shift 纯悬停：不查词（门没被打穿）───────────────
  for (double x = wordX1; x >= wordX0; x -= 6) {
    await _call('mouseMove',
        <String, Object?>{'x': x, 'y': wordY, 'shift': false, 'mode': mode});
    await tester.pump(const Duration(milliseconds: 40));
  }
  await tester.pump(const Duration(seconds: 1));
  expect(await _popupShows('testword'), isFalse,
      reason: '没按 Shift 且未开「悬停即查词」时纯悬停不得查词');

  // ── ② 光标停在词上、按一下 Shift（静止反查）──────────────────
  await _call('mouseMove',
      <String, Object?>{'x': (wordX0 + wordX1) / 2, 'y': wordY, 'shift': false, 'mode': mode});
  await tester.pump(const Duration(milliseconds: 300));
  final Map<Object?, Object?> fc2 =
      await _call('flagsChanged', <String, Object?>{'shift': true, 'mode': mode});
  await tester.pump(const Duration(milliseconds: 300));
  debugPrint('[mac-shift-hover] flagsChanged(shift, stationary) $fc2 '
      'shiftHeld=${HardwareKeyboard.instance.isShiftPressed} last=${keySeenBox.last}');
  final bool pressPopup = await _waitPopup(tester, 'testword');
  debugPrint('[mac-shift-hover] ② popup=$pressPopup '
      'shiftHeld=${HardwareKeyboard.instance.isShiftPressed}');
  debugPrint('[mac-shift-hover] shot2=${await _shotWindow(windowNumber, 'bug2508-02-shift-press')}');
  await _call('flagsChanged', <String, Object?>{'shift': false, 'mode': mode});
  expect(pressPopup, isTrue,
      reason: '光标停在 testword 上按下 Shift 必须直接弹出查词弹窗');

  // ── ④ 「悬停即查词」开关开着：不按 Shift 纯悬停也出词（同一条宿主腿）────
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  for (int i = 0; i < 12 && await _popupShows('testword'); i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (i == 6) await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  }
  expect(await _popupShows('testword'), isFalse, reason: 'Esc 必须关掉弹窗');
  final ReaderFushiSource source = ReaderFushiSource.instance;
  final bool baseAuto = source.hoverAutoLookup;
  try {
    await source.setHoverAutoLookup(value: true);
    await tester.pump(const Duration(milliseconds: 500));
    for (double x = wordX0 - 24; x <= wordX1; x += 6) {
      await _call('mouseMove',
          <String, Object?>{'x': x, 'y': wordY, 'shift': false, 'mode': mode});
      await tester.pump(const Duration(milliseconds: 40));
    }
    final bool autoPopup = await _waitPopup(tester, 'testword');
    debugPrint('[mac-shift-hover] ④ hoverAutoLookup popup=$autoPopup '
        'shiftHeld=${HardwareKeyboard.instance.isShiftPressed}');
    expect(autoPopup, isTrue,
        reason: '「悬停即查词」开着时纯悬停扫过 testword 必须出词');
  } finally {
    await source.setHoverAutoLookup(value: baseAuto);
  }
}
