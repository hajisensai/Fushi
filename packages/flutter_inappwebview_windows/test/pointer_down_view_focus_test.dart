import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview_windows/src/in_app_webview/custom_platform_view.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-3858：鼠标点进 WebView2 时，插件不得把原生焦点从 Chromium 抢回 Flutter 视图。
///
/// 真实链路：WebView2 收到 LEFT_BUTTON_DOWN 后自己 SetFocus 到 Chromium 子窗，引擎给框架
/// 发 `ViewFocusState.unfocused`，焦点停在根作用域。原先 onPointerDown 里的
/// `_focusNode.requestFocus()`（外加 50 ms 重试）让 View 作用域重新得焦，框架随即
/// `requestViewFocusChange(focused)` → 引擎 SetFocus 回 Flutter 视图，与 Chromium 来回抢：
/// 网页里每次都是 window blur，YouTube 设置菜单点二级项时整个关掉。
///
/// 断言落在最强的可落地层：框架对引擎发出的 view focus 请求（`testFocusEvents`）——
/// 那就是会变成原生 SetFocus 的那一条。同时确认点击本身照常转发给 native。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel manager = MethodChannel(
    'com.pichillilorenzo/flutter_inappwebview_manager',
  );
  const int textureId = 11;
  const MethodChannel view = MethodChannel(
    'com.pichillilorenzo/custom_platform_view_$textureId',
  );
  const MethodChannel events = MethodChannel(
    'com.pichillilorenzo/custom_platform_view_${textureId}_events',
  );

  final List<MethodCall> viewCalls = <MethodCall>[];

  setUp(() {
    viewCalls.clear();
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(manager, (MethodCall call) async {
      if (call.method == 'createInAppWebView') return textureId;
      return null;
    });
    messenger.setMockMethodCallHandler(view, (MethodCall call) async {
      viewCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (MethodCall call) async => null);
  });

  tearDown(() {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(manager, null);
    messenger.setMockMethodCallHandler(view, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  testWidgets('焦点已被 WebView2 拿走时，点击网页不向引擎要回视图焦点', (WidgetTester tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(width: 400, height: 300, child: CustomPlatformView()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final Finder target = find.byType(Listener).first;
    expect(target, findsOneWidget, reason: '初始化完成后应挂上转发指针的 Listener');

    // WebView2 第一次被点：Chromium 拿走 Win32 焦点，引擎报 unfocused，框架停焦根作用域。
    tester.binding.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ViewFocusState.unfocused,
        direction: ViewFocusDirection.undefined,
      ),
    );
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus,
      FocusManager.instance.rootScope,
      reason: '原生焦点离开 Flutter 视图后框架应停焦在根作用域',
    );
    tester.platformDispatcher.resetFocusedViewTestValues();
    viewCalls.clear();

    // 再点一次网页（菜单的二级项）。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: tester.getCenter(target));
    await mouse.moveTo(tester.getCenter(target));
    await mouse.down(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 20));
    await mouse.up();
    // 越过旧实现的 50 ms 重试窗口。
    await tester.pump(const Duration(milliseconds: 120));
    await mouse.removePointer();

    final List<ViewFocusEvent> requests =
        tester.platformDispatcher.testFocusEvents;
    expect(
      requests.where((ViewFocusEvent e) => e.state == ViewFocusState.focused),
      isEmpty,
      reason: '点击网页不得请求 Flutter 视图得焦（会 SetFocus 抢走 Chromium 的焦点）：$requests',
    );
    expect(
      FocusManager.instance.primaryFocus,
      FocusManager.instance.rootScope,
      reason: '焦点应继续停在根作用域，键盘归网页',
    );
    final List<String> buttons = viewCalls
        .where((MethodCall c) => c.method == 'setPointerButton')
        .map((MethodCall c) => '${c.arguments}')
        .toList();
    expect(buttons.length, 2, reason: '按下与抬起仍须转发给 native：$viewCalls');
  });
}
