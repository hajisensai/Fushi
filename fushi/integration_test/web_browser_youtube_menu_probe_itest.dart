// 诊断：app 内浏览器（WebView2 合成模式）里 YouTube 播放器设置菜单的二级项点不开。
//
// 鼠标输入走 Flutter 层指针事件（mouse 设备，hover move / down / up）打到 WebView 上，
// 于是经过的就是真实转发链路 custom_platform_view.dart → SendMouseInput，且不碰用户桌面。
// 页内用捕获阶段监听记录 pointer / mouse / click 事件序列与菜单 DOM 变化；
// 每步同时抓 Flutter 合成帧（纹理）与 CDP 截图（渲染器真相）对照。
//
// 跑：在 fushi/ 下
// `.\tool\run_windows_itest.ps1 integration_test/web_browser_youtube_menu_probe_itest.dart`
//
// 真鼠标模式（Flutter 层指针全过、用户真鼠标仍打不开时用）：
// `.\tool\run_windows_itest.ps1 -Visible -DartDefine FUSHI_YT_REAL_INPUT=1 integration_test/web_browser_youtube_menu_probe_itest.dart`
// 改用 SetCursorPos + SendInput 走系统输入队列（会占用桌面光标几十秒），
// 每次点击前后记录 Win32 焦点窗口（GetGUIThreadInfo）。
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show ViewFocusEvent;

import 'package:ffi/ffi.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'package:fushi/pages.dart';
import 'package:fushi/src/pages/implementations/fushi_web_browser_page.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _kUrl = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';

const bool _kRealInput = String.fromEnvironment('FUSHI_YT_REAL_INPUT') == '1';

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final int Function(int, int) _setCursorPos = _user32
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'SetCursorPos',
    );
final int Function(int, Pointer<Uint8>, int) _sendInput = _user32
    .lookupFunction<
      Uint32 Function(Uint32, Pointer<Uint8>, Int32),
      int Function(int, Pointer<Uint8>, int)
    >('SendInput');
final int Function(int, int, Pointer<Utf16>, Pointer<Utf16>) _findWindowEx =
    _user32.lookupFunction<
      IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
      int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowExW');
final int Function(int, Pointer<Uint32>) _getWindowThreadProcessId = _user32
    .lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetWindowThreadProcessId');
final int Function(int, Pointer<Int32>) _clientToScreen = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Int32>),
      int Function(int, Pointer<Int32>)
    >('ClientToScreen');
final int Function(int, Pointer<Uint8>) _getGuiThreadInfo = _user32
    .lookupFunction<
      Int32 Function(Uint32, Pointer<Uint8>),
      int Function(int, Pointer<Uint8>)
    >('GetGUIThreadInfo');
final int Function(int, Pointer<Utf16>, int) _getClassName = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Int32),
      int Function(int, Pointer<Utf16>, int)
    >('GetClassNameW');

final int Function(int) _windowFromPoint = _user32
    .lookupFunction<IntPtr Function(Int64), int Function(int)>(
      'WindowFromPoint',
    );
final int Function(Pointer<Int32>) _getCursorPos = _user32
    .lookupFunction<
      Int32 Function(Pointer<Int32>),
      int Function(Pointer<Int32>)
    >('GetCursorPos');

/// 光标下的窗口（POINT 按值传，x64 打包成一个 64 位整数）。
String _windowUnderCursor() {
  final Pointer<Int32> pt = calloc<Int32>(2);
  try {
    _getCursorPos(pt);
    final int packed = (pt[0] & 0xffffffff) | (pt[1] << 32);
    return 'cursor=(${pt[0]},${pt[1]}) under=${_className(_windowFromPoint(packed))}';
  } finally {
    calloc.free(pt);
  }
}

/// 本进程的 Flutter 视图 HWND（同类名的用户实例按 PID 排除）。
int _ownFlutterView() {
  final Pointer<Utf16> cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final Pointer<Utf16> view = 'FLUTTERVIEW'.toNativeUtf16();
  final Pointer<Uint32> pidOut = calloc<Uint32>();
  try {
    int top = 0;
    while (true) {
      top = _findWindowEx(0, top, cls, nullptr);
      if (top == 0) return 0;
      _getWindowThreadProcessId(top, pidOut);
      if (pidOut.value == pid) return _findWindowEx(top, 0, view, nullptr);
    }
  } finally {
    calloc.free(cls);
    calloc.free(view);
    calloc.free(pidOut);
  }
}

String _className(int hwnd) {
  if (hwnd == 0) return 'null';
  final Pointer<Utf16> buf = calloc<Uint16>(128).cast<Utf16>();
  try {
    _getClassName(hwnd, buf, 128);
    return '${buf.toDartString()}@0x${hwnd.toRadixString(16)}';
  } finally {
    calloc.free(buf);
  }
}

/// Win32 焦点所在：视图线程的 hwndFocus / hwndActive。
String _win32Focus(int view) {
  final int tid = _getWindowThreadProcessId(view, nullptr);
  final Pointer<Uint8> info = calloc<Uint8>(72);
  try {
    info.cast<Uint32>().value = 72;
    if (_getGuiThreadInfo(tid, info) == 0) return 'n/a';
    final int active = (info + 8).cast<IntPtr>().value;
    final int focus = (info + 16).cast<IntPtr>().value;
    return 'focus=${_className(focus)} active=${_className(active)}';
  } finally {
    calloc.free(info);
  }
}

void _sendButton(bool down) {
  final Pointer<Uint8> input = calloc<Uint8>(40);
  try {
    input.cast<Uint32>().value = 0; // INPUT_MOUSE
    (input + 20).cast<Uint32>().value = down ? 0x0002 : 0x0004;
    _sendInput(1, input, 40);
  } finally {
    calloc.free(input);
  }
}

/// 页内事件记录器：捕获阶段、只记播放器子树内的事件，外加菜单 DOM 变化。
const String _kRecorder = r'''
(function(){
  if (window.__ytLog) { window.__ytLog.length = 0; return 'reset'; }
  window.__ytLog = [];
  var t0 = performance.now();
  function desc(el){
    if (!el || !el.tagName) return String(el && el.nodeName);
    var c = (el.className && el.className.baseVal !== undefined) ? el.className.baseVal : el.className;
    return el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (c ? '.' + String(c).trim().split(/\s+/).slice(0,2).join('.') : '');
  }
  ['pointerover','pointerenter','pointermove','pointerdown','pointerup','pointercancel','pointerout','pointerleave',
   'mouseover','mousemove','mousedown','mouseup','click','dblclick','contextmenu','focusin','focusout','blur','focus']
  .forEach(function(type){
    window.addEventListener(type, function(e){
      var p = document.getElementById('movie_player');
      if (!p || !(e.target instanceof Node) || !p.contains(e.target)) {
        if (type !== 'blur' && type !== 'focus') return;
      }
      if (type === 'pointermove' || type === 'mousemove') {
        var last = window.__ytLog[window.__ytLog.length-1];
        if (last && last.t === type && last.tg === desc(e.target)) { last.n = (last.n||1)+1; last.x = e.clientX; last.y = e.clientY; return; }
      }
      window.__ytLog.push({t:type, ms: Math.round(performance.now()-t0), tg: desc(e.target),
        tr: e.isTrusted, b: e.buttons, bt: e.button, pt: e.pointerType, x: e.clientX, y: e.clientY,
        d: e.detail, id: e.pointerId, pr: e.isPrimary});
    }, true);
  });
  var mo = new MutationObserver(function(recs){
    recs.forEach(function(r){
      var tg = r.target;
      if (!tg.closest || !tg.closest('.ytp-settings-menu')) return;
      window.__ytLog.push({t:'mut:' + r.type + (r.attributeName ? ':' + r.attributeName : ''), ms: Math.round(performance.now()-t0),
        tg: desc(tg), add: r.addedNodes.length, rm: r.removedNodes.length});
    });
  });
  mo.observe(document.documentElement, {subtree:true, childList:true, attributes:true, attributeFilter:['style','class','aria-expanded','hidden']});
  return 'installed';
})()
''';

class _ViewFocusLog with WidgetsBindingObserver {
  _ViewFocusLog(this.log);
  final void Function(String) log;
  int count = 0;

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    count++;
    log(
      'viewFocus #$count ${event.state.name} view=${event.viewId} '
      'dir=${event.direction.name} primary=${FocusManager.instance.primaryFocus}',
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('YouTube 设置菜单二级项：Flutter 鼠标指针经 SendMouseInput 能否打开子菜单', (
    WidgetTester tester,
  ) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final List<String> results = <String>[];
    File? progress;
    void log(String line) {
      final String text = '[yt-probe] $line';
      debugPrint(text);
      try {
        progress ??= File('${observeScreenshotDir().parent.path}/yt-probe.log');
        progress!.writeAsStringSync(
          '${DateTime.now().toIso8601String()} $text\n',
          mode: FileMode.append,
          flush: true,
        );
      } on Object {
        // 取证日志写不进去不影响测试本身。
      }
    }

    void result(String item, bool ok, [String note = '']) {
      final String line = '${ok ? 'PASS' : 'FAIL'} $item $note';
      results.add(line);
      log(line);
    }

    int shotIndex = 0;
    Size? originalSize;

    await runFushiItest(
      label: 'yt-probe',
      collectedErrors: errors,
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        await tester.pump(const Duration(seconds: 2));
        await readyAppModel(tester);

        Future<void> settle([int ms = 600]) async {
          for (int i = 0; i < ms ~/ 50; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
        }

        FushiWebBrowserPageState page() =>
            tester.state<FushiWebBrowserPageState>(
              find.byType(FushiWebBrowserPage, skipOffstage: false),
            );
        WebBrowserTab? active() => page().tabsController.activeTab;

        Future<bool> waitFor(
          FutureOr<bool> Function() cond, {
          Duration timeout = const Duration(seconds: 20),
        }) async {
          final DateTime end = DateTime.now().add(timeout);
          while (DateTime.now().isBefore(end)) {
            if (await cond()) return true;
            await tester.pump(const Duration(milliseconds: 200));
          }
          return await cond();
        }

        Future<Object?> js(String source) async {
          final InAppWebViewController? c = active()?.controller;
          if (c == null) return null;
          try {
            return await c
                .evaluateJavascript(source: source)
                .timeout(const Duration(seconds: 10));
          } on Object catch (e) {
            log('js failed: $e');
            return null;
          }
        }

        Future<void> shot(String name) async {
          await settle(500);
          shotIndex++;
          final String full =
              'yt-${shotIndex.toString().padLeft(2, '0')}-$name';
          final RenderView view = tester.binding.renderViews.first;
          final OffsetLayer layer = view.debugLayer! as OffsetLayer;
          final ui.Image frame = await layer.toImage(view.paintBounds);
          try {
            final ByteData? png = await frame.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '${observeScreenshotDir().path}/$full-flutter.png',
            ).writeAsBytes(png!.buffer.asUint8List(), flush: true);
          } finally {
            frame.dispose();
          }
          try {
            final Uint8List? cdp = await active()?.controller
                ?.takeScreenshot()
                .timeout(const Duration(seconds: 10));
            if (cdp != null) {
              await File(
                '${observeScreenshotDir().path}/$full-cdp.png',
              ).writeAsBytes(cdp, flush: true);
            }
          } on Object catch (e) {
            log('cdp shot failed: $e');
          }
          log('shot $full');
        }

        originalSize = await windowManager.getSize();
        await windowManager.setSize(const Size(1300, 860));
        await settle(800);

        final BuildContext ctx = tester.element(find.byType(HomePage));
        unawaited(openFushiWebBrowser(ctx, Uri.parse(_kUrl)));
        await settle(1500);
        final bool loaded = await waitFor(() {
          final WebBrowserTab? t = active();
          return t != null && t.controller != null && !t.loading;
        }, timeout: const Duration(seconds: 60));
        result('页面加载', loaded, '${active()?.url}');
        // 失败页取证：记录每次 error 变化（失败页盖在 WebView 上会吞掉全部指针）。
        final WebBrowserTab tab = active()!;
        Object? lastError;
        void onTab() {
          final Object? e = tab.error;
          if (identical(e, lastError)) return;
          lastError = e;
          final WebBrowserLoadError? le = tab.error;
          log(
            'tab.error -> ${le == null ? 'null' : '${le.kind} "${le.description}" '
                      'status=${le.statusCode} url=${le.url}'} '
            'tabUrl=${tab.url} loading=${tab.loading}',
          );
        }

        tab.addListener(onTab);
        onTab();
        final bool hasButton = await waitFor(
          () async =>
              await js('!!document.querySelector(".ytp-settings-button")') ==
              true,
          timeout: const Duration(seconds: 60),
        );
        result('播放器设置按钮出现', hasButton);
        await settle(5000);
        // 失败页：YouTube 的 themeRefresh 改址曾把被顶掉的首个导航报成
        // 「connection was stopped」盖在新文档上（BUG-3859，已修）。
        result(
          '没有失败页盖在已加载的页面上 ${tab.error?.description ?? ''}',
          tab.error == null,
        );
        result(
          '扩展播放器菜单按钮出现',
          await waitFor(
            () async =>
                await js('!!document.getElementById("fushi-player-btn")') ==
                true,
            timeout: const Duration(seconds: 30),
          ),
        );

        // WebView widget 在 Flutter 里的全局矩形 → CSS px 的换算。
        final Finder webFinder = find.byType(InAppWebView);
        expect(webFinder, findsOneWidget);
        final Rect webRect = tester.getRect(webFinder);
        final Object? vp = await js(
          'JSON.stringify({w: innerWidth, h: innerHeight, dpr: devicePixelRatio})',
        );
        final Map<String, dynamic> v =
            jsonDecode(vp! as String) as Map<String, dynamic>;
        final double scaleX = webRect.width / (v['w'] as num).toDouble();
        final double scaleY = webRect.height / (v['h'] as num).toDouble();
        log(
          'webRect=$webRect viewport=$vp scale=($scaleX,$scaleY) '
          'flutterDpr=${tester.view.devicePixelRatio}',
        );

        Future<Offset?> centerOf(String selectorJs) async {
          final Object? raw = await js(
            '(function(){var e=$selectorJs; if(!e) return null;'
            'var r=e.getBoundingClientRect(); if(!r.width) return null;'
            'return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2});})()',
          );
          if (raw is! String) return null;
          final Map<String, dynamic> r =
              jsonDecode(raw) as Map<String, dynamic>;
          return webRect.topLeft +
              Offset(
                (r['x'] as num).toDouble() * scaleX,
                (r['y'] as num).toDouble() * scaleY,
              );
        }

        final _ViewFocusLog viewFocus = _ViewFocusLog(log);
        WidgetsBinding.instance.addObserver(viewFocus);
        addTearDown(() => WidgetsBinding.instance.removeObserver(viewFocus));
        final TestGesture mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: webRect.center);
        addTearDown(mouse.removePointer);
        Offset mouseAt = webRect.center;

        final int flutterView = _kRealInput ? _ownFlutterView() : 0;
        if (_kRealInput) {
          // Live binding 默认把真设备指针只画圈不分发。
          final IntegrationTestWidgetsFlutterBinding b =
              IntegrationTestWidgetsFlutterBinding.instance;
          b.shouldPropagateDevicePointerEvents = true;
          await windowManager.setAlwaysOnTop(true);
          await windowManager.focus();
          addTearDown(() => windowManager.setAlwaysOnTop(false));
          log('real-input view=${_className(flutterView)}');
        }
        void realMove(Offset logical) {
          final Pointer<Int32> pt = calloc<Int32>(2);
          try {
            final double dpr = tester.view.devicePixelRatio;
            pt[0] = (logical.dx * dpr).round();
            pt[1] = (logical.dy * dpr).round();
            _clientToScreen(flutterView, pt);
            _setCursorPos(pt[0], pt[1]);
          } finally {
            calloc.free(pt);
          }
        }

        Future<void> hoverTo(Offset target, {int steps = 8}) async {
          final Offset from = mouseAt;
          for (int i = 1; i <= steps; i++) {
            if (_kRealInput) {
              mouseAt = Offset.lerp(from, target, i / steps)!;
              realMove(mouseAt);
              await tester.pump(const Duration(milliseconds: 30));
              continue;
            }
            await mouse.moveTo(Offset.lerp(from, target, i / steps)!);
            mouseAt = Offset.lerp(from, target, i / steps)!;
            await tester.pump(const Duration(milliseconds: 30));
          }
        }

        Future<void> click(Offset target) async {
          await hoverTo(target);
          await settle(300);
          String w32() => _kRealInput
              ? ' ${_win32Focus(flutterView)} ${_windowUnderCursor()}'
              : '';
          log(
            'before-down primary=${FocusManager.instance.primaryFocus} viewFocusEvents=${viewFocus.count}${w32()}',
          );
          if (_kRealInput) {
            _sendButton(true);
            await tester.pump(const Duration(milliseconds: 80));
            log('mid-click${w32()}');
            _sendButton(false);
          } else {
            await mouse.down(target);
            await tester.pump(const Duration(milliseconds: 80));
            await mouse.up();
          }
          await settle(800);
          log(
            'after-click primary=${FocusManager.instance.primaryFocus} viewFocusEvents=${viewFocus.count}${w32()}',
          );
        }

        Future<String> dumpLog(String tag) async {
          final Object? raw = await js('JSON.stringify(window.__ytLog||[])');
          final String s = raw?.toString() ?? 'null';
          log('$tag events=$s');
          return s;
        }

        const String menuState = r'''
(function(){var m=document.querySelector(".ytp-settings-menu");
if(!m) return JSON.stringify({menu:null});
var cs=getComputedStyle(m);
var hdr=m.querySelector(".ytp-panel-header");
var items=[].slice.call(m.querySelectorAll(".ytp-menuitem")).map(function(i){
  return (i.querySelector(".ytp-menuitem-label")||i).textContent.trim();});
return JSON.stringify({display:cs.display, visible: m.getBoundingClientRect().width>0 && cs.display!=="none",
  w: m.style.width, h: m.style.height, header: hdr ? hdr.textContent.trim() : null,
  panels: m.querySelectorAll(".ytp-panel").length, items: items.slice(0,12),
  active: document.activeElement ? (document.activeElement.className||document.activeElement.tagName) : null});})()
''';

        // 先让播放器控件显示出来（hover 到视频上）。
        final Offset? player = await centerOf(
          'document.getElementById("movie_player")',
        );
        result('定位播放器', player != null, '$player');
        await hoverTo(player!);
        await settle(800);
        log('recorder=${await js(_kRecorder)}');

        // ① 点齿轮。
        final Offset? gear = await centerOf(
          'document.querySelector(".ytp-settings-button")',
        );
        log('gear=$gear');
        await click(gear!);
        await dumpLog('after-gear');
        final Object? m1 = await js(menuState);
        log('menu-after-gear=$m1');
        final Map<String, dynamic> s1 =
            jsonDecode(m1! as String) as Map<String, dynamic>;
        result('齿轮打开设置菜单', s1['visible'] == true, '$m1');
        await shot('menu-open');

        // ② 依次点二级项（每项点开后读面板，再点返回键回主面板）。
        final List<String> labels =
            (s1['items'] as List<dynamic>? ?? <dynamic>[]).cast<String>();
        int idx = 0;
        for (final String label in labels) {
          idx++;
          final String safe = jsonEncode(label);
          final Offset? item = await centerOf(
            '[].slice.call(document.querySelectorAll(".ytp-settings-menu .ytp-panel:not(.ytp-panel-animate-back) .ytp-menuitem"))'
            '.filter(function(i){return (i.querySelector(".ytp-menuitem-label")||i).textContent.trim()===$safe && i.getAttribute("aria-haspopup")==="true";})[0]',
          );
          if (item == null) {
            log('skip "$label"（不是二级项或不可见）');
            continue;
          }
          await js(_kRecorder);
          await click(item);
          final String events = await dumpLog('after-item-$idx');
          final Object? m2 = await js(menuState);
          log('menu-after-item-$idx($label)=$m2');
          final Map<String, dynamic> s2 =
              jsonDecode(m2! as String) as Map<String, dynamic>;
          result(
            '二级项「$label」打开子菜单',
            s2['header'] != null,
            'clicks=${'"t":"click"'.allMatches(events).length} $m2',
          );
          await shot('item-$idx');
          // 回主面板：点子菜单标题的返回按钮；没开成就点齿轮复位。
          final Offset? back = await centerOf(
            'document.querySelector(".ytp-settings-menu .ytp-panel-back-button") || document.querySelector(".ytp-settings-menu .ytp-panel-header")',
          );
          if (back != null) {
            await click(back);
          } else {
            await js(
              'document.querySelector(".ytp-settings-menu").style.display',
            );
          }
          final Object? m3 = await js(menuState);
          final Map<String, dynamic> s3 =
              jsonDecode(m3! as String) as Map<String, dynamic>;
          if (s3['visible'] != true) {
            await click(gear);
          }
        }
      },
    );

    // 框架在测试体结束时就校验这个开关（早于 addTearDown），必须在这里还原。
    IntegrationTestWidgetsFlutterBinding
            .instance
            .shouldPropagateDevicePointerEvents =
        false;
    try {
      if (originalSize != null) await windowManager.setSize(originalSize!);
    } on Object {
      // 窗口已关。
    }
    log(
      'SUMMARY ${results.where((String r) => r.startsWith('PASS')).length}'
      '/${results.length}',
    );
    for (final String r in results) {
      log(r);
    }
    expect(
      results.where((String r) => r.startsWith('FAIL')),
      isEmpty,
      reason: results.join('\n'),
    );
  });
}
