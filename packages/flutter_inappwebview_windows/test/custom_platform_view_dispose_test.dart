import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview_windows/src/in_app_webview/custom_platform_view.dart';

/// TODO-904：[CustomPlatformViewController] 的 dispose await-gate 回归守卫。
///
/// 根因：原 `initialize()` 仅在成功路径 complete `_creatingCompleter`，失败时该
/// completer 永不完成 → `dispose()` 首行 `await _creatingCompleter.future` 永久挂起
/// → native `'dispose'` 永远到不了 → texture/孤儿资源不回收（死亡螺旋，反复开关书
/// 后稳定抛 `Cannot create the InAppWebView instance!`）。
///
/// 修复：失败路径 `completeError`，dispose 不无条件 await 失败 completer。
///
/// 本测试用 fake MethodChannel 处理器让 `createInAppWebView` 抛 PlatformException，
/// 断言：① `initialize()` 抛出（失败冒泡，不再被吞）；② 随后 `dispose()` 在有限时间内
/// 完成（不永久挂起）；③ 失败时仍发出 native `'dispose'`（id=0 在 native 是 no-op，
/// 不 double-free）；④ 成功路径 dispose 正常完成且发出正确 id 的 dispose。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_manager');

  final List<MethodCall> calls = <MethodCall>[];

  void installHandler({required bool createSucceeds, int textureId = 7}) {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      if (call.method == 'createInAppWebView') {
        if (!createSucceeds) {
          throw PlatformException(
              code: '0', message: 'Cannot create the InAppWebView instance!');
        }
        return textureId;
      }
      if (call.method == 'dispose') {
        return null;
      }
      return null;
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('创建失败时 initialize 抛出且 dispose 有限时间完成（不永久挂起）', () async {
    installHandler(createSucceeds: false);
    final controller = CustomPlatformViewController();

    await expectLater(
        controller.initialize(), throwsA(isA<PlatformException>()));

    // dispose 必须有限时间完成；若 await-gate 回归，这里会永久挂起 → 测试超时。
    await controller.dispose().timeout(const Duration(seconds: 2));

    final disposeCalls = calls.where((c) => c.method == 'dispose').toList();
    expect(disposeCalls.length, 1, reason: '失败路径仍应发出一次 native dispose 兜底回收');
    final args = disposeCalls.single.arguments as Map;
    expect(args['id'], 0,
        reason: '失败时 textureId 保持默认 0，native 对未知 id 是 no-op，不 double-free');
  });

  test('创建失败后重复 dispose 不再发第二次 native dispose（不 double-dispose）', () async {
    installHandler(createSucceeds: false);
    final controller = CustomPlatformViewController();

    await expectLater(
        controller.initialize(), throwsA(isA<PlatformException>()));
    await controller.dispose().timeout(const Duration(seconds: 2));
    await controller.dispose().timeout(const Duration(seconds: 2));

    final disposeCalls = calls.where((c) => c.method == 'dispose').toList();
    expect(disposeCalls.length, 1,
        reason: '_isDisposed 守卫保证只发一次 native dispose');
  });

  test('成功路径 dispose 正常完成并发出正确 textureId 的 dispose', () async {
    installHandler(createSucceeds: true, textureId: 42);
    final controller = CustomPlatformViewController();

    await controller.initialize().timeout(const Duration(seconds: 2));
    await controller.dispose().timeout(const Duration(seconds: 2));

    final disposeCalls = calls.where((c) => c.method == 'dispose').toList();
    expect(disposeCalls.length, 1);
    expect((disposeCalls.single.arguments as Map)['id'], 42,
        reason: '成功路径行为零变化：用真实 textureId dispose');
  });

  testWidgets(
      'TODO-965: ready 完成前 widget 被销毁，complete 后上报不崩（不解引用陈旧 box/context）',
      (WidgetTester tester) async {
    // native WebView2 跨帧创建用一个手动 Completer 卡住 createInAppWebView：
    // postFrame 的 _reportSurfaceSize/_reportWidgetPosition 会 await _controller.ready
    // 进入挂起；此时把 widget 从树移除（box/context 失效），再 complete 创建。
    // 修复前 await 之后用陈旧 box/context → View.of 返 null `!` 崩、localToGlobal 崩。
    final Completer<int> createGate = Completer<int>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'createInAppWebView') {
        return createGate.future;
      }
      return null;
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: CustomPlatformView(),
          ),
        ),
      ),
    );
    // 触发 initState 的 postFrameCallback（其中调用两个上报方法）。
    await tester.pump();

    // ready 仍未完成时，把 CustomPlatformView 从树里移除 → 其 box/context 失效。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    await tester.pump();

    // 现在放行 native 创建：两个上报方法的 await 恢复执行，必须命中 !mounted 早返回，
    // 而不是解引用已失效的 box/context。
    createGate.complete(7);
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: 'ready 完成后必须复检 mounted/box.attached，不得用陈旧引用崩溃');
  });
}
