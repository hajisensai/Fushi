import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/platform/desktop/windows_native_pre_exit.dart';

/// TODO-618 fix1 守卫：关窗路径与更新路径不共享同一个一次性 `prepareForExit` 守卫。
///
/// 根因 A1：旧实现用单个静态 `_prepared` bool，被更新预检置真后，关窗路径
/// `if (_prepared) return;` 静默短路，native teardown 落空 → 退出期 Unknown Hard Error。
///
/// 本测试断言「走过更新路径（置位守卫）后，关窗路径仍发出一次 prepareForProcessExit
/// channel 调用」，并验证 per-path 一次性与非 Windows 向后兼容。
void main() {
  const MethodChannel channel =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_manager');

  late List<MethodCall> calls;

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return null;
    });
    WindowsNativePreExit.resetForTesting();
    WindowsNativePreExit.isWindows = () => true;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    WindowsNativePreExit.resetForTesting();
  });

  test(
      'update path then window-close path each emit prepareForProcessExit (decoupled guards)',
      () async {
    await WindowsNativePreExit.prepareForExit(WindowsExitReason.update);
    expect(calls.length, 1,
        reason: 'update path must emit the native pre-exit call');

    // 关键：走过更新路径后再关窗，关窗路径仍必须真正发出 channel 调用（解耦语义）。
    await WindowsNativePreExit.prepareForExit(WindowsExitReason.windowClose);
    expect(calls.length, 2,
        reason:
            'window-close path must still emit even after update path armed its guard');
    expect(calls.every((MethodCall c) => c.method == 'prepareForProcessExit'),
        isTrue);
  });

  test('each path is one-shot: same reason does not re-emit', () async {
    await WindowsNativePreExit.prepareForExit(WindowsExitReason.windowClose);
    await WindowsNativePreExit.prepareForExit(WindowsExitReason.windowClose);
    expect(calls.length, 1,
        reason: 'repeat of same exit reason must short-circuit');
  });

  test('non-Windows is a no-op (backward compatible)', () async {
    WindowsNativePreExit.isWindows = () => false;
    await WindowsNativePreExit.prepareForExit(WindowsExitReason.update);
    await WindowsNativePreExit.prepareForExit(WindowsExitReason.windowClose);
    expect(calls, isEmpty,
        reason: 'non-Windows platforms must not invoke the native channel');
  });
}
