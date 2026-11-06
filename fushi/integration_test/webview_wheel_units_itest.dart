// Windows 真 WebView2：app 内 WebView 每档滚轮送进 DOM 的 deltaY 必须与原生窗口一致。
//
// 用户报「视频查词框的滚轮手感远不如 galgame 查词框」（2026-09-27）。两者跑同一份
// popup.js，区别只在宿主怎么把滚轮交给 WebView2：galgame 覆盖窗是原生 HWND，系统的
// WM_MOUSEWHEEL(120) 原样到达；app 内 WebView 由 Flutter 收滚轮、再经 fork 的
// `InAppWebView::sendScroll` 用 `SendMouseInput` 转发。fork 原先按「一档 delta≈20」
// 乘 6，而现行引擎一档是 `行数×100/3` 物理像素（默认 100），于是一档变成 5 个
// WHEEL_DELTA。
//
// 本测投一档引擎真实会发的量（100 物理像素 ÷ dpr 的逻辑像素，与
// flutter_window.cc WM_MOUSEWHEEL → SendScroll → converter 的链路逐位一致），
// 读 DOM 实收的 deltaY，断言它等于同一台机器上 WebView2 对**一个** WHEEL_DELTA
// 的换算——由第二次投送「1/5 档」的量反证线性、并与系统滚动行数推出的期望值比对。
//
// 运行：fushi/ 下 `.\tool\run_windows_itest.ps1 integration_test\webview_wheel_units_itest.dart`
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const String _html = '''
<!doctype html><html><head><meta charset="utf-8">
<style>html,body{margin:0;height:4000px;background:#fff}</style></head>
<body><script>
window.__wheel = [];
window.__moves = 0;
document.addEventListener('mousemove', function(){ window.__moves++; });
document.addEventListener('wheel', function(e){
  window.__wheel.push({dy: e.deltaY, dx: e.deltaX, mode: e.deltaMode,
    ctrl: e.ctrlKey});
  e.preventDefault();
}, {passive:false});
</script></body></html>
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('一档滚轮到 DOM 的 deltaY 与原生 WHEEL_DELTA 同量', (
    WidgetTester tester,
  ) async {
    if (!Platform.isWindows) return;
    InAppWebViewController? controller;
    int flutterSignals = 0;
    bool loaded = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: Listener(
                onPointerSignal: (PointerSignalEvent e) => flutterSignals++,
                child: InAppWebView(
                  initialData: InAppWebViewInitialData(data: _html),
                  onWebViewCreated: (InAppWebViewController c) =>
                      controller = c,
                  onLoadStop: (InAppWebViewController c, WebUri? url) =>
                      loaded = true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    for (int i = 0; i < 120 && !loaded; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(loaded, isTrue, reason: 'WebView2 应在 30s 内加载完测试页');
    await tester.pump(const Duration(milliseconds: 500));

    final double dpr = tester.view.devicePixelRatio;
    final Offset center = tester.getCenter(find.byType(InAppWebView));

    Future<List<Map<String, dynamic>>> drain() async {
      await tester.pump(const Duration(milliseconds: 400));
      final Object? raw = await controller!.evaluateJavascript(
        source: 'JSON.stringify(window.__wheel.splice(0))',
      );
      final Object? decoded = raw is String ? jsonDecode(raw) : raw;
      return (decoded as List<dynamic>? ?? <dynamic>[])
          .cast<Map<String, dynamic>>();
    }

    // fork 的 sendScroll 把滚轮投在 `lastCursorPos_`，它由鼠标移动事件建立——真实
    // 使用中滚轮前指针必然先移进 WebView，这里照样先投一次 hover。
    await tester.sendEventToBinding(
      PointerAddedEvent(kind: PointerDeviceKind.mouse, position: center),
    );
    await tester.sendEventToBinding(
      PointerHoverEvent(kind: PointerDeviceKind.mouse, position: center),
    );
    await tester.pump(const Duration(milliseconds: 300));

    Future<void> scroll(double logicalDy) async {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: center,
          scrollDelta: Offset(0, logicalDy),
        ),
      );
    }

    // 一档：引擎发 100 物理像素（默认 3 行），框架除以 dpr。
    const double notchPhysical = 100;
    await scroll(notchPhysical / dpr);
    final List<Map<String, dynamic>> notch = await drain();
    // 五分之一档：旧换算下恰好是一个 WHEEL_DELTA，用作「单个 WHEEL_DELTA 在本机
    // 映射成多少 deltaY」的对照（新换算下是 24 单位，按线性换算回去比）。
    await scroll(notchPhysical / 5 / dpr);
    final List<Map<String, dynamic>> fifth = await drain();

    final Object? moves = await controller!.evaluateJavascript(
      source: 'window.__moves',
    );
    debugPrint(
      '[wheel-units] dpr=$dpr notch=$notch fifth=$fifth '
      'flutterSignals=$flutterSignals domMoves=$moves',
    );
    expect(notch, hasLength(1), reason: '一档应恰好派发一个 wheel 事件');
    expect(fifth, hasLength(1));
    final double notchDy = (notch.single['dy'] as num).toDouble();
    final double fifthDy = (fifth.single['dy'] as num).toDouble();
    expect(notch.single['mode'], 0, reason: 'WebView2 以像素模式上报');
    expect(notchDy, greaterThan(0));
    // 线性：一档 = 五个五分之一档（整数截断允许 1px 误差）。
    expect((notchDy - fifthDy * 5).abs(), lessThanOrEqualTo(5));
    // 原生窗口一档（WHEEL_DELTA=120，默认 3 行）在 WebView2 里是 100 DIP，deltaY 以
    // CSS px 计 = 100（页面缩放 1）。旧换算这里是 500。
    expect(
      notchDy,
      closeTo(100, 2),
      reason: '一档应与原生 WHEEL_DELTA 同量（旧换算为 5 倍）；实测 $notchDy',
    );
  });

  // 反馈 794gISjvgV / SUsLYAlCJF：横向符号与触控板慢滑。
  //
  // ① WM_MOUSEHWHEEL 的正值是「向右滚」，与 WM_MOUSEWHEEL「正 = 向上」相反；fork 的
  //    sendScroll 入参是「内容移动量」，横向必须取反才对上。倾斜滚轮向右
  //    （Flutter scrollDelta.dx > 0）在 DOM 里必须是 deltaX > 0。
  // ② 触控板两指向左划（panDelta.dx < 0，内容跟手向左）= 视口向右滚 = deltaX > 0。
  // ③ 触控板两指慢慢上滑一长段，scale 途中漂移越过 3%：必须一路以普通（非 Ctrl）
  //    滚轮到达 DOM，总量与平移一致——此前中途被锁成捏合，之后全部丢弃。
  testWidgets('横向滚轮符号与触控板慢滑到达 DOM', (WidgetTester tester) async {
    if (!Platform.isWindows) return;
    InAppWebViewController? controller;
    bool loaded = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: InAppWebView(
                initialData: InAppWebViewInitialData(data: _html),
                onWebViewCreated: (InAppWebViewController c) => controller = c,
                onLoadStop: (InAppWebViewController c, WebUri? url) =>
                    loaded = true,
              ),
            ),
          ),
        ),
      ),
    );
    for (int i = 0; i < 120 && !loaded; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(loaded, isTrue, reason: 'WebView2 应在 30s 内加载完测试页');
    await tester.pump(const Duration(milliseconds: 500));
    final Offset center = tester.getCenter(find.byType(InAppWebView));

    Future<List<Map<String, dynamic>>> drain() async {
      await tester.pump(const Duration(milliseconds: 400));
      final Object? raw = await controller!.evaluateJavascript(
        source: 'JSON.stringify(window.__wheel.splice(0))',
      );
      final Object? decoded = raw is String ? jsonDecode(raw) : raw;
      return (decoded as List<dynamic>? ?? <dynamic>[])
          .cast<Map<String, dynamic>>();
    }

    double sum(List<Map<String, dynamic>> events, String key) => events.fold(
      0.0,
      (double acc, Map<String, dynamic> e) => acc + (e[key] as num).toDouble(),
    );

    await tester.sendEventToBinding(
      PointerAddedEvent(kind: PointerDeviceKind.mouse, position: center),
    );
    await tester.sendEventToBinding(
      PointerHoverEvent(kind: PointerDeviceKind.mouse, position: center),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // ① 倾斜滚轮向右一档。
    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: center,
        scrollDelta: Offset(100 / tester.view.devicePixelRatio, 0),
      ),
    );
    final List<Map<String, dynamic>> tilt = await drain();
    debugPrint('[wheel-units] tiltRight=$tilt');
    expect(tilt, isNotEmpty);
    expect(sum(tilt, 'dx'), greaterThan(0), reason: '向右倾斜必须向右滚');

    const int device = 7;
    Future<void> panZoom(List<({Offset pan, double scale})> frames) async {
      await tester.sendEventToBinding(
        PointerPanZoomStartEvent(device: device, position: center),
      );
      Offset pan = Offset.zero;
      for (final ({Offset pan, double scale}) f in frames) {
        pan += f.pan;
        await tester.sendEventToBinding(
          PointerPanZoomUpdateEvent(
            device: device,
            position: center,
            pan: pan,
            panDelta: f.pan,
            scale: f.scale,
          ),
        );
      }
      await tester.sendEventToBinding(
        PointerPanZoomEndEvent(device: device, position: center),
      );
    }

    // ② 两指向左划 40 逻辑像素。
    await panZoom(<({Offset pan, double scale})>[
      for (int i = 0; i < 20; i++) (pan: const Offset(-2, 0), scale: 1.0),
    ]);
    final List<Map<String, dynamic>> swipeLeft = await drain();
    debugPrint('[wheel-units] trackpadLeft=$swipeLeft');
    expect(swipeLeft, isNotEmpty);
    expect(sum(swipeLeft, 'dx'), greaterThan(0), reason: '内容跟手向左 = 视口向右滚');

    // ③ 两指慢慢上滑 90 逻辑像素，scale 漂移到 1.06。
    double scale = 1.0;
    await panZoom(<({Offset pan, double scale})>[
      for (int i = 0; i < 60; i++)
        (pan: const Offset(0, -1.5), scale: scale += 0.001),
    ]);
    final List<Map<String, dynamic>> slow = await drain();
    debugPrint('[wheel-units] trackpadSlowUp=$slow');
    expect(
      slow.where((Map<String, dynamic> e) => e['ctrl'] == true),
      isEmpty,
      reason: '慢滑途中不得被改判成捏合（Ctrl+滚轮）',
    );
    // DOM deltaY（CSS px，页面缩放 1）= 逻辑像素 × dpr（见上一条测试的一档换算）。
    final double dpr = tester.view.devicePixelRatio;
    expect(
      sum(slow, 'dy'),
      closeTo(90 * dpr, 6 * dpr),
      reason: '内容跟手向上 = 视口向下滚，总量与平移一致',
    );
  });
}
