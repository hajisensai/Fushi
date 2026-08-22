import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart' as gp;
import 'package:fushi/src/shortcuts/dictionary_popup_gamepad.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

import '../helpers/source_guard.dart';

/// 手柄全功能重设计 P2：查词弹窗手柄通道（默认映射 / 兜底派发 / v9→v10 迁移）
/// 与右摇杆滚动采集。
void main() {
  tearDown(DictionaryPopupGamepadRegistry.debugClear);

  DictionaryPopupGamepadHooks recordingHooks(
    List<String> calls, {
    bool visible = true,
  }) {
    return DictionaryPopupGamepadHooks(
      hasVisiblePopup: () => visible,
      entryMove: (bool forward) async =>
          calls.add(forward ? 'entry:next' : 'entry:prev'),
      mineFirstEntry: () async => calls.add('mine'),
      playFirstAudio: () async => calls.add('audio'),
      scrollBy: (double dy) async => calls.add('scroll:$dy'),
    );
  }

  group('dictionaryPopup 手柄默认映射', () {
    late FushiShortcutRegistry registry;

    setUp(() {
      registry = FushiShortcutRegistry();
      registry.loadDefaults(TargetPlatform.windows);
    });

    test('dpad下/上=词条导航、X=制卡、Y=发音', () {
      expect(
        registry.resolveGamepad(GamepadButton.dpadDown,
            scope: ShortcutScope.dictionaryPopup),
        ShortcutAction.popupNextEntry,
      );
      expect(
        registry.resolveGamepad(GamepadButton.dpadUp,
            scope: ShortcutScope.dictionaryPopup),
        ShortcutAction.popupPrevEntry,
      );
      expect(
        registry.resolveGamepad(GamepadButton.x,
            scope: ShortcutScope.dictionaryPopup),
        ShortcutAction.popupMineEntry,
      );
      expect(
        registry.resolveGamepad(GamepadButton.y,
            scope: ShortcutScope.dictionaryPopup),
        ShortcutAction.popupPlayAudio,
      );
    });

    test('移动端默认表也带手柄绑定（Android 键事件链同一执行路）', () {
      final Map<ShortcutAction, ShortcutBindingSet> mobile =
          ShortcutDefaults.forPlatform(TargetPlatform.android);
      expect(
          mobile[ShortcutAction.popupNextEntry]!.gamepadBindings, isNotEmpty);
      expect(
          mobile[ShortcutAction.popupPlayAudio]!.gamepadBindings, isNotEmpty);
    });
  });

  group('tryDictionaryPopupGamepadButton（弹窗兜底派发）', () {
    late FushiShortcutRegistry registry;

    setUp(() {
      registry = FushiShortcutRegistry();
      registry.loadDefaults(TargetPlatform.windows);
    });

    test('弹窗可见：四个默认按钮各自派发到对应钩子', () {
      final List<String> calls = <String>[];
      DictionaryPopupGamepadRegistry.push(recordingHooks(calls));
      expect(tryDictionaryPopupGamepadButton(registry, GamepadButton.dpadDown),
          isTrue);
      expect(tryDictionaryPopupGamepadButton(registry, GamepadButton.dpadUp),
          isTrue);
      expect(
          tryDictionaryPopupGamepadButton(registry, GamepadButton.x), isTrue);
      expect(
          tryDictionaryPopupGamepadButton(registry, GamepadButton.y), isTrue);
      expect(calls, <String>['entry:next', 'entry:prev', 'mine', 'audio']);
    });

    test('未绑定按钮返回 false（交回滚动/焦点兜底），不误吞', () {
      final List<String> calls = <String>[];
      DictionaryPopupGamepadRegistry.push(recordingHooks(calls));
      expect(
          tryDictionaryPopupGamepadButton(registry, GamepadButton.a), isFalse);
      expect(
          tryDictionaryPopupGamepadButton(registry, GamepadButton.b), isFalse);
      expect(
          tryDictionaryPopupGamepadButton(registry, GamepadButton.rb), isFalse);
      expect(calls, isEmpty);
    });

    test('无可见弹窗：登记了钩子也不吃任何按钮', () {
      final List<String> calls = <String>[];
      DictionaryPopupGamepadRegistry.push(
          recordingHooks(calls, visible: false));
      expect(tryDictionaryPopupGamepadButton(registry, GamepadButton.dpadDown),
          isFalse);
      expect(calls, isEmpty);
    });

    test('取最近注册且可见的钩子（首页常驻 controller 不抢活跃路由的弹窗）', () {
      final List<String> homeCalls = <String>[];
      final List<String> videoCalls = <String>[];
      DictionaryPopupGamepadRegistry.push(
          recordingHooks(homeCalls, visible: false));
      DictionaryPopupGamepadRegistry.push(recordingHooks(videoCalls));
      expect(tryDictionaryPopupGamepadButton(registry, GamepadButton.dpadDown),
          isTrue);
      expect(homeCalls, isEmpty);
      expect(videoCalls, <String>['entry:next']);
    });

    test('registry 为 null（测试宿主）时安全返回 false', () {
      DictionaryPopupGamepadRegistry.push(recordingHooks(<String>[]));
      expect(tryDictionaryPopupGamepadButton(null, GamepadButton.dpadDown),
          isFalse);
    });
  });

  group('右摇杆滚动采集', () {
    test('GamepadFrameState 采集 rightStickX/Y 轴', () {
      final GamepadFrameState state = GamepadFrameState();
      state.applyAxis(gp.GamepadAxis.rightStickY, 0.5);
      expect(state.rightStickY, (0.5 * GamepadFrameBits.axisMax).round());
      state.applyAxis(gp.GamepadAxis.rightStickX, -1.0);
      expect(state.rightStickX, -GamepadFrameBits.axisMax);
    });

    test('处理器：死区内不发、死区外每 tick 发归一化偏移且向下为正', () {
      final List<double> emitted = <double>[];
      final GamepadFrameProcessor processor = GamepadFrameProcessor(
        onButton: (_) {},
        onRightStickScroll: emitted.add,
      );
      // 死区内（|8000| 不超过阈值）：不发。
      processor.processFrame(
        buttons: 0,
        leftTrigger: 0,
        rightTrigger: 0,
        stickX: 0,
        stickY: 0,
        rightStickY: GamepadFrameProcessor.rightStickDeadZone,
        nowMs: 0,
      );
      expect(emitted, isEmpty);
      // 推杆向上（插件 +Y=上）→ 滚动向上 = 负值。
      processor.processFrame(
        buttons: 0,
        leftTrigger: 0,
        rightTrigger: 0,
        stickX: 0,
        stickY: 0,
        rightStickY: GamepadFrameBits.axisMax,
        nowMs: 60,
      );
      expect(emitted.single, -1.0);
      // 推杆向下 → 正值，连续 tick 连续发（无边沿检测）。
      processor.processFrame(
        buttons: 0,
        leftTrigger: 0,
        rightTrigger: 0,
        stickX: 0,
        stickY: 0,
        rightStickY: -GamepadFrameBits.axisMax ~/ 2,
        nowMs: 120,
      );
      processor.processFrame(
        buttons: 0,
        leftTrigger: 0,
        rightTrigger: 0,
        stickX: 0,
        stickY: 0,
        rightStickY: -GamepadFrameBits.axisMax ~/ 2,
        nowMs: 180,
      );
      expect(emitted.length, 3);
      expect(emitted[1], greaterThan(0));
      expect(emitted[2], emitted[1]);
    });
  });

  group(
      '派发接线源码守卫（单测只测 tryDictionaryPopupGamepadButton 本体，'
      '接线被删时它们照样绿——这两条钉住两条真实调用链）', () {
    test('桌面轮询：_dispatchButton 在页面 Actions 之后调弹窗兜底', () {
      final String code = maskComments(
          File('lib/src/shortcuts/gamepad_service.dart').readAsStringSync());
      expect(
        code.contains('if (tryDictionaryPopupGamepadButton(registry, button)) '
            'return;'),
        isTrue,
        reason: '桌面轮询链丢失弹窗兜底：手柄在弹窗上只剩焦点/滚动兜底',
      );
    });

    test('Android 键事件链：全局 wrapper 调同一入口', () {
      final String code = maskComments(
          File('lib/src/shortcuts/global_navigation.dart').readAsStringSync());
      expect(
        code.contains(
            'tryDictionaryPopupGamepadButton(registry, nativeButton)'),
        isTrue,
        reason: 'Android 链丢失弹窗兜底：手柄弹窗操作变桌面 only',
      );
    });
  });

  group('schema migration v9 → v10（弹窗手柄默认播种）', () {
    /// v9 时代的快照：dictionaryPopup 动作有滚轮/键盘绑定但手柄恒空
    /// （该 scope 当时根本没开手柄通道），popupPlayAudio 尚不存在。
    Map<String, dynamic> v9Snapshot({
      Map<ShortcutAction, ShortcutBindingSet> overrides = const {},
    }) {
      final Map<ShortcutAction, ShortcutBindingSet> defaults =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final Map<String, dynamic> json = <String, dynamic>{
        kShortcutSchemaVersionKey: 9,
      };
      for (final MapEntry<ShortcutAction, ShortcutBindingSet> entry
          in defaults.entries) {
        final ShortcutAction action = entry.key;
        if (action == ShortcutAction.popupPlayAudio) continue; // v9 没有它
        if (overrides.containsKey(action)) {
          json[action.key] = overrides[action]!.toJson();
          continue;
        }
        final List<GamepadBinding> gamepad =
            action.scope == ShortcutScope.dictionaryPopup
                ? const <GamepadBinding>[]
                : entry.value.gamepadBindings;
        json[action.key] = ShortcutBindingSet(
          keyboardBindings: entry.value.keyboardBindings,
          gamepadBindings: gamepad,
          mouseBindings: entry.value.mouseBindings,
          wheelBindings: entry.value.wheelBindings,
        ).toJson();
      }
      return json;
    }

    test('老快照升级后补上弹窗手柄默认；新动作 popupPlayAudio 天然拿默认', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry();
      registry.loadFromJsonString(
        jsonEncode(v9Snapshot()),
        TargetPlatform.windows,
      );
      expect(
        registry.resolveGamepad(GamepadButton.dpadDown,
            scope: ShortcutScope.dictionaryPopup),
        ShortcutAction.popupNextEntry,
      );
      expect(
        registry.resolveGamepad(GamepadButton.x,
            scope: ShortcutScope.dictionaryPopup),
        ShortcutAction.popupMineEntry,
      );
      expect(
        registry.resolveGamepad(GamepadButton.y,
            scope: ShortcutScope.dictionaryPopup),
        ShortcutAction.popupPlayAudio,
      );
    });

    test('用户自定义的滚轮绑定原样保留（播种只动 gamepad，绝不整组还原）', () {
      // 用户把「下一个词条」改成 Ctrl+滚轮下：迁移后滚轮保持用户值，同时手柄补上。
      final FushiShortcutRegistry registry = FushiShortcutRegistry();
      const WheelBinding userWheel = WheelBinding(
        WheelDirection.down,
        modifiers: <ModifierKey>{ModifierKey.ctrl},
      );
      registry.loadFromJsonString(
        jsonEncode(
          v9Snapshot(
            overrides: <ShortcutAction, ShortcutBindingSet>{
              ShortcutAction.popupNextEntry: const ShortcutBindingSet(
                wheelBindings: <WheelBinding>[userWheel],
              ),
            },
          ),
        ),
        TargetPlatform.windows,
      );
      expect(
        registry.bindingsFor(ShortcutAction.popupNextEntry).wheelBindings,
        <WheelBinding>[userWheel],
      );
      expect(
        registry.resolveGamepad(GamepadButton.dpadDown,
            scope: ShortcutScope.dictionaryPopup),
        ShortcutAction.popupNextEntry,
      );
    });
  });
}
