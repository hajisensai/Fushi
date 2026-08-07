import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';

/// TODO-1223 守卫：缺 GameInput.dll 时给用户提醒（不再静默降级）。
///
/// 背景：+488 用 `/DELAYLOAD` + `init()` 里 `LoadLibraryW(L"GameInput.dll")`
/// 探测，缺失即早退（app 不崩），但**静默**——用户手柄没反应却无从得知。本任务
/// 让 native 把探测结果经 `gameInputAvailable` 通道方法回传 Dart，Dart 在手柄相关
/// 设置页（非启动弹窗）给一行 app 内提示。
///
/// 两层守：
///   A. 源码契约（vendored C++ 在 headless Dart 里跑不到，故守代码契约）：
///      native 探测成功时置位 `game_input_available`，插件用 `gameInputAvailable`
///      方法回传。
///   B. Dart 行为：[GamepadService.gameInputBackendAvailable] 只在 Windows 查通道，
///      拿到确定的 false 才判不可用；非 Windows / 通道异常一律 true（绝不打扰）。
void main() {
  group('TODO-1223 native 探测→信号契约（源码扫描）', () {
    const String pkg = '../packages/gamepads_windows/windows';
    final String gamepadCpp = File('$pkg/gamepad.cpp').readAsStringSync();
    final String gamepadH = File('$pkg/gamepad.h').readAsStringSync();
    final String pluginCpp =
        File('$pkg/gamepads_windows_plugin.cpp').readAsStringSync();

    test('gamepad.h 声明 game_input_available 标志', () {
      expect(gamepadH, contains('bool game_input_available'),
          reason: 'init() 探测结果须有可读回的成员');
    });

    test('init() 探测到 GameInput.dll 后置位 available（缺失路径不置位）', () {
      expect(gamepadCpp, contains('game_input_available = true'),
          reason: 'LoadLibraryW 成功后必须标记可用，否则永远提示不可用');
      // available 的置位必须在 LoadLibraryW 探测的早退 return 之后，确保缺 DLL
      // 时它保持 false（=触发提示）。
      final int probeReturn = gamepadCpp.indexOf('gamepad support disabled');
      final int setTrue = gamepadCpp.indexOf('game_input_available = true');
      expect(probeReturn, greaterThanOrEqualTo(0));
      expect(setTrue, greaterThan(probeReturn),
          reason: 'available=true 必须在缺 DLL 早退之后，缺 DLL 时保持 false');
    });

    test('插件 HandleMethodCall 暴露 gameInputAvailable 方法', () {
      expect(pluginCpp, contains('"gameInputAvailable"'),
          reason: 'Dart 须能经通道查询探测结果');
      expect(pluginCpp, contains('gamepads.game_input_available'),
          reason: 'gameInputAvailable 必须回传真实探测标志，不能硬编码');
    });
  });

  group('TODO-1223 GamepadService.gameInputBackendAvailable 行为', () {
    const MethodChannel channel = MethodChannel('xyz.luan/gamepads');
    late List<String> invoked;

    TestWidgetsFlutterBinding.ensureInitialized();

    void mock(Object? Function() reply) {
      invoked = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        invoked.add(call.method);
        return reply();
      });
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('通道报 false → 不可用（Windows）/ 非 Windows 不查通道恒 true', () async {
      mock(() => false);
      final bool available = await GamepadService.gameInputBackendAvailable();
      if (Platform.isWindows) {
        expect(available, isFalse, reason: 'Windows 上通道 false → 提示不可用');
        expect(invoked, contains('gameInputAvailable'));
      } else {
        expect(available, isTrue, reason: '非 Windows 无此可选 DLL，恒可用');
        expect(invoked, isEmpty, reason: '非 Windows 不应查询通道');
      }
    });

    test('通道报 true → 可用（Windows）', () async {
      mock(() => true);
      final bool available = await GamepadService.gameInputBackendAvailable();
      expect(available, isTrue);
    }, skip: !Platform.isWindows);

    test('通道抛异常 → 回退可用（绝不因瞬时错误打扰）', () async {
      mock(() => throw PlatformException(code: 'boom'));
      final bool available = await GamepadService.gameInputBackendAvailable();
      expect(available, isTrue);
    }, skip: !Platform.isWindows);
  });
}
