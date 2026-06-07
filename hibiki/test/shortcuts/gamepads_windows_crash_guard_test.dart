import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-116 回归守卫（源码扫描；vendored 的 Windows 原生插件 C++ 在 headless Dart
/// 测试里跑不到 —— 既没有 GameInput.h，也没有真手柄，故守 4 处修复的代码契约）。
///
/// 现象：`gamepads_windows_plugin.dll` 在 `FlutterDesktopViewControllerDestroy`
/// （app 销毁期）c0000005 崩溃；按键期亦有独立崩溃向量。
///
/// pub 插件 `gamepads_windows-0.3.0+1` 四处缺陷（已 vendor 到
/// `packages/gamepads_windows` 修复）：
///   ① `stop()` Release `g_gameInput` 后不置空，detach 的轮询线程仍
///      `GetCurrentReading` → 对已释放 COM use-after-free（teardown 崩）。
///      修：线程改 OWNED（不 detach）+ stop/disconnect 先 join 再 Release 并置空。
///   ② `emit_gamepad_event` 从轮询线程直接 `channel->InvokeMethod`，违反 Flutter
///      「平台通道仅平台线程」。修：经 message-only 窗口 PostMessage marshal 回
///      平台线程再 InvokeMethod。
///   ③ `stop_thread` / `alive` 裸 bool 跨线程数据竞争。修：`std::atomic<bool>`。
///   ④ `deviceCallbackToken` 裸指针未初始化（野指针）。修：值类型 token。
///
/// 谁把这些修复改回旧的崩溃写法（detach / 线程内直接调 channel / 裸 bool /
/// 野指针），或把 vendor override 拆掉，本测试红。
void main() {
  const String pkg = '../packages/gamepads_windows/windows';
  final String gamepadCpp = File('$pkg/gamepad.cpp').readAsStringSync();
  final String gamepadH = File('$pkg/gamepad.h').readAsStringSync();
  final String pluginCpp =
      File('$pkg/gamepads_windows_plugin.cpp').readAsStringSync();
  final String pluginH =
      File('$pkg/gamepads_windows_plugin.h').readAsStringSync();
  final String pubspec = File('pubspec.yaml').readAsStringSync();

  group('BUG-116 gamepads_windows 崩溃修复（vendored 源码契约）', () {
    test('① 轮询线程 OWNED + join，不再 detach + 线程内自删', () {
      expect(gamepadH, contains('std::thread thread'),
          reason: '①：GamepadData 须持有线程句柄以便 join（不再 detach）');
      expect(gamepadCpp, contains('.join()'),
          reason: '①：stop/disconnect 须 join 轮询线程后才能释放');
      expect(gamepadCpp.contains('read_thread.detach()'), isFalse,
          reason: '①：轮询线程不得 detach（detach 后无法 join → teardown UAF）');
      // 轮询线程 read_gamepad 体内不得自删 GamepadData；合法的 delete 只在
      // owner 侧的 join_and_destroy（join 之后）。
      final int readStart = gamepadCpp.indexOf('::read_gamepad');
      expect(readStart, greaterThanOrEqualTo(0));
      final String readBody = gamepadCpp.substring(readStart);
      expect(readBody.contains('delete gamepad'), isFalse,
          reason: '①：轮询线程 read_gamepad 内不得自删，所有权归 join 的 owner');
      expect(gamepadCpp, contains('join_and_destroy'),
          reason: '①：须由 owner 的 join_and_destroy 统一 join 后释放');
    });

    test('① stop() Release g_gameInput 后置空', () {
      expect(gamepadCpp, contains('g_gameInput = nullptr'),
          reason: '①：Release(g_gameInput) 后必须置空，避免线程触到已释放指针');
    });

    test('② 事件经平台线程 marshal，不在轮询线程直调 channel', () {
      expect(pluginH, contains('drain_event_queue'),
          reason: '②：须有平台线程出队函数 drain_event_queue');
      expect(pluginCpp, contains('PostMessage'),
          reason: '②：轮询线程须 PostMessage 唤醒平台线程，不直调 channel');
      expect(pluginCpp, contains('HWND_MESSAGE'),
          reason: '②：须用 message-only 窗口在平台线程接收事件');
      // emit_gamepad_event（轮询线程）函数体内不得出现 InvokeMethod。
      final int emitStart = pluginCpp.indexOf('::emit_gamepad_event');
      final int drainStart = pluginCpp.indexOf('::drain_event_queue');
      expect(emitStart, greaterThanOrEqualTo(0));
      expect(drainStart, greaterThan(emitStart),
          reason: 'drain_event_queue 应定义在 emit_gamepad_event 之后');
      final String emitBody = pluginCpp.substring(emitStart, drainStart);
      expect(emitBody.contains('InvokeMethod'), isFalse,
          reason: '②：emit_gamepad_event（轮询线程）内不得调 channel->InvokeMethod');
      expect(pluginCpp, contains('_channel->InvokeMethod'),
          reason: '②：InvokeMethod 仍须存在，但只在平台线程的 drain 里');
    });

    test('③ 跨线程标志用 std::atomic', () {
      expect(gamepadH, contains('std::atomic<bool> stop_thread'),
          reason: '③：stop_thread 须为 atomic，消除跨线程数据竞争');
      expect(gamepadH.contains('bool alive'), isFalse,
          reason: '③：裸 bool alive（自删信号）应随 join 模型移除');
    });

    test('④ deviceCallbackToken 为值类型，非野指针', () {
      expect(gamepadH, contains('GameInputCallbackToken deviceCallbackToken'),
          reason: '④：token 须为值类型并初始化，不能是未初始化裸指针');
      expect(gamepadH.contains('GameInputCallbackToken* deviceCallbackToken'),
          isFalse,
          reason: '④：不得用裸指针 token（RegisterDeviceCallback 会写野地址）');
      expect(gamepadCpp, contains('&this->deviceCallbackToken'),
          reason: '④：注册回调须传 token 的地址（out 参数）');
    });

    test('device AddRef 保活轮询线程期间的设备', () {
      expect(gamepadCpp, contains('device->AddRef()'),
          reason: '连接时须 AddRef 设备，避免轮询期间被释放（次生 UAF）');
    });

    test('vendor override 已接线到 path:', () {
      expect(pubspec, contains('gamepads_windows:'),
          reason: 'hibiki 须 override gamepads_windows 到 vendored 副本');
      expect(pubspec, contains('path: ../packages/gamepads_windows'),
          reason: 'override 须指向 packages/gamepads_windows');
    });
  });
}
