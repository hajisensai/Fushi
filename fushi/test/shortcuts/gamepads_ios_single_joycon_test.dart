import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart' as gp;

import 'package:fushi/src/shortcuts/gamepad_service.dart';

import '../helpers/workspace_pubspec.dart';

/// 反馈 2F3oApV21V（GitHub #3122）：iOS 上单只 Switch Joy-Con 翻页。
///
/// 根因：pub 上的 `gamepads_ios-0.1.3+3` 在 `GamepadsIosPlugin.setupController`
/// 里 `guard let gamepad = controller.extendedGamepad else { return }`——单只
/// Joy-Con（iOS 16+）没有 extended profile，整只手柄被丢弃，一个事件也到不了
/// Dart。修复把插件 vendor 到 `packages/gamepads_ios`，没有 extendedGamepad 时
/// 退到 `physicalInputProfile`，按 extended 路径相同的原始 key 上报。
///
/// 顺带：上游把 LT/RT 当 analog 的 `leftTrigger` / `rightTrigger` 上报，而
/// gamepads 的 IosMapping 只在按钮表里认这两个 key，analog 事件被归一成空——
/// iOS 上扳机整个失灵。fork 改为数字按钮事件。
///
/// Swift 源码在 Windows / Linux 测试机上编不了也跑不了，所以这里守两层：
///  1. vendored Swift 源码契约（不再对非 extended 手柄 return、确有
///     physicalInputProfile 路径、扳机不再走 analog）；
///  2. fallback 路径上报的**每一个**原始 key，经真实的 gamepads iOS 归一化 +
///     Fushi 的 [GamepadFrameState] 后都落到预期的帧位——尤其 SL/SR（=左右
///     肩键）→ LB/RB，即阅读器 / 漫画默认的上一页 / 下一页。
void main() {
  const String swiftPath =
      '../packages/gamepads_ios/ios/Classes/GamepadsIosPlugin.swift';
  final String swift = File(swiftPath).readAsStringSync();

  /// 截取 Swift 里 `func <name>(` 起到下一个 `func` 声明之前的函数体。
  String funcBody(String name) {
    final int start = swift.indexOf('func $name(');
    expect(start, greaterThanOrEqualTo(0), reason: '找不到 func $name');
    final int next = swift.indexOf(
      RegExp(r'\n  (?:@available[^\n]*\n  )?(?:private |static )*func '),
      start + 1,
    );
    return next < 0 ? swift.substring(start) : swift.substring(start, next);
  }

  /// `case GCInputXxx: return "key"` 里的全部原始 key。
  List<String> returnedKeys(String body) => RegExp(
    r'case GCInput\w+: return "([^"]+)"',
  ).allMatches(body).map((RegExpMatch m) => m.group(1)!).toList();

  group('vendored gamepads_ios 源码契约', () {
    test('gamepads_ios 来自 workspace 里的 vendored 副本', () {
      expect(
        WorkspacePubspec.load().isVendored(
          'gamepads_ios',
          'packages/gamepads_ios',
        ),
        isTrue,
        reason: '拆掉 vendor 会让 pub.dev 的 0.1.3+3 回来，单只 Joy-Con 再次失灵',
      );
    });

    test('没有 extendedGamepad 的手柄不再被直接丢弃', () {
      expect(
        swift.contains(
          'guard let gamepad = controller.extendedGamepad else { return }',
        ),
        isFalse,
        reason: '上游这行 return 就是单只 Joy-Con 进不了 Dart 的根因',
      );
      final String setup = funcBody('setupController');
      expect(setup, contains('if let gamepad = controller.extendedGamepad'));
      expect(
        setup,
        contains('controller.physicalInputProfile'),
        reason: '非 extended 手柄须退到 physicalInputProfile',
      );
      expect(
        funcBody('setupPhysicalInputProfile'),
        allOf(contains('profile.dpads'), contains('profile.buttons')),
      );
    });

    test('扳机按数字按钮上报（analog 的 trigger key 在 iOS 归一化里是空）', () {
      final String extended = funcBody('setupExtendedGamepad');
      expect(
        extended.contains(
          RegExp(r'key: "(left|right)Trigger", value: value, isAnalog: true'),
        ),
        isFalse,
      );
      expect(
        extended,
        contains(
          'key: "leftTrigger", value: pressed ? 1.0 : 0.0, isAnalog: false',
        ),
      );
      expect(
        extended,
        contains(
          'key: "rightTrigger", value: pressed ? 1.0 : 0.0, isAnalog: false',
        ),
      );
    });
  });

  group('physicalInputProfile 路径的原始 key 经真实归一化落到正确帧位', () {
    final gp.GamepadNormalizer normalizer = gp.GamepadNormalizer.forPlatform(
      gp.GamepadPlatform.ios,
    );

    GamepadFrameState fold(
      gp.KeyType type,
      String key,
      double value, [
      GamepadFrameState? into,
    ]) {
      final GamepadFrameState state = into ?? GamepadFrameState();
      final List<gp.NormalizedGamepadEvent> events = normalizer.normalize(
        gp.GamepadEvent(
          gamepadId: '1',
          timestamp: 0,
          type: type,
          key: key,
          value: value,
        ),
      );
      for (final gp.NormalizedGamepadEvent e in events) {
        final gp.GamepadButton? button = e.button;
        final gp.GamepadAxis? axis = e.axis;
        if (button != null) state.applyButton(button, e.value);
        if (axis != null) state.applyAxis(axis, e.value);
      }
      return state;
    }

    const Map<String, int> expectedButtonBits = <String, int>{
      'buttonA': GamepadFrameBits.a,
      'buttonB': GamepadFrameBits.b,
      'buttonX': GamepadFrameBits.x,
      'buttonY': GamepadFrameBits.y,
      'leftShoulder': GamepadFrameBits.leftShoulder,
      'rightShoulder': GamepadFrameBits.rightShoulder,
      'leftThumbstickButton': GamepadFrameBits.leftThumb,
      'rightThumbstickButton': GamepadFrameBits.rightThumb,
      'buttonMenu': GamepadFrameBits.start,
      'buttonOptions': GamepadFrameBits.back,
    };

    test('Swift 映射表与本测试的期望表一致（防一边改一边漏）', () {
      expect(returnedKeys(funcBody('profileButtonKey')).toSet(), <String>{
        ...expectedButtonBits.keys,
        'leftTrigger',
        'rightTrigger',
        'buttonHome',
      });
      expect(returnedKeys(funcBody('profileDpadKey')).toSet(), <String>{
        'dpad',
        'leftStick',
        'rightStick',
      });
    });

    test('每个数字按钮 key 按下置位、松开清位', () {
      expectedButtonBits.forEach((String key, int bit) {
        final GamepadFrameState state = fold(gp.KeyType.button, key, 1.0);
        expect(state.buttons, bit, reason: '$key 按下应只置 $bit');
        fold(gp.KeyType.button, key, 0.0, state);
        expect(state.buttons, 0, reason: '$key 松开应清位');
      });
    });

    test('SL/SR（iOS 报成左右肩键）= LB/RB = 默认上一页 / 下一页', () {
      expect(
        fold(gp.KeyType.button, 'leftShoulder', 1.0).buttons,
        GamepadFrameBits.leftShoulder,
      );
      expect(
        fold(gp.KeyType.button, 'rightShoulder', 1.0).buttons,
        GamepadFrameBits.rightShoulder,
      );
    });

    test('扳机作为数字按钮上报时落到扳机通道', () {
      expect(
        fold(gp.KeyType.button, 'leftTrigger', 1.0).leftTrigger,
        GamepadFrameBits.triggerMax,
      );
      expect(
        fold(gp.KeyType.button, 'rightTrigger', 1.0).rightTrigger,
        GamepadFrameBits.triggerMax,
      );
      final GamepadFrameState released = fold(
        gp.KeyType.button,
        'leftTrigger',
        1.0,
      );
      fold(gp.KeyType.button, 'leftTrigger', 0.0, released);
      expect(released.leftTrigger, 0);
    });

    test('上游的 analog 扳机事件在 iOS 归一化里确实是空（fork 的理由）', () {
      expect(fold(gp.KeyType.analog, 'leftTrigger', 1.0).leftTrigger, 0);
    });

    test('方向键（单只 Joy-Con 的摇杆可能报成 Direction Pad）→ 四向位', () {
      expect(
        fold(gp.KeyType.analog, 'dpad - xAxis', 1.0).buttons,
        GamepadFrameBits.dpadRight,
      );
      expect(
        fold(gp.KeyType.analog, 'dpad - xAxis', -1.0).buttons,
        GamepadFrameBits.dpadLeft,
      );
      expect(
        fold(gp.KeyType.analog, 'dpad - yAxis', 1.0).buttons,
        GamepadFrameBits.dpadUp,
      );
      expect(
        fold(gp.KeyType.analog, 'dpad - yAxis', -1.0).buttons,
        GamepadFrameBits.dpadDown,
      );
    });

    test('摇杆 key 落到摇杆轴', () {
      expect(
        fold(gp.KeyType.analog, 'leftStick - xAxis', 1.0).stickX,
        GamepadFrameBits.axisMax,
      );
      expect(
        fold(gp.KeyType.analog, 'rightStick - yAxis', -1.0).rightStickY,
        -GamepadFrameBits.axisMax,
      );
    });
  });
}
