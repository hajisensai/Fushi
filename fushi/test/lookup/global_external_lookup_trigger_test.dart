import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/global_external_lookup_route.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

import '../helpers/source_guard.dart';

/// TODO-1066 — app 外全局查词的两条**非键盘**触发源（手柄按钮 / 鼠标侧键）。
///
/// 这两条与键盘热键是「同一个执行体、三种 OS 机制」，各自的边界写在
/// `ShortcutScope.globalExternal` 的 channels 注释里。本文件钉三件事：
///   ① 手柄解析/派发的行为（含"没注册就不吞按钮"）；
///   ② 派发位置必须在取焦点 context **之前**（否则 app 失焦时整条路径失效，
///      而那正是本功能唯一的使用场景）——这条只有源码守卫抓得住；
///   ③ 手柄/鼠标默认绑定必须为空（它优先于页面，给默认值等于抢键）。
void main() {
  tearDown(GlobalExternalLookupRoute.debugClear);

  FushiShortcutRegistry windowsRegistry() =>
      FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  group('GlobalExternalLookupRoute', () {
    test('未注册 / 注销后 current 为 null', () {
      expect(GlobalExternalLookupRoute.current, isNull);
      GlobalExternalLookupRoute.set(() async {});
      expect(GlobalExternalLookupRoute.current, isNotNull);
      GlobalExternalLookupRoute.set(null);
      expect(GlobalExternalLookupRoute.current, isNull);
    });
  });

  group('tryGlobalExternalLookupGamepadButton', () {
    test('绑定命中且已注册入口 → 触发一次并吞掉按钮', () async {
      final FushiShortcutRegistry registry = windowsRegistry();
      registry.updateBinding(
        ShortcutAction.globalExternalLookup,
        const ShortcutBindingSet(
          gamepadBindings: <GamepadBinding>[GamepadBinding(GamepadButton.y)],
        ),
      );
      int fired = 0;
      GlobalExternalLookupRoute.set(() async => fired++);

      expect(
        tryGlobalExternalLookupGamepadButton(registry, GamepadButton.y),
        isTrue,
      );
      // trigger 是 fire-and-forget（unawaited），让 microtask 跑完再断言。
      await Future<void>.delayed(Duration.zero);
      expect(fired, 1);
    });

    test('未绑定的按钮不触发、不吞', () {
      final FushiShortcutRegistry registry = windowsRegistry();
      registry.updateBinding(
        ShortcutAction.globalExternalLookup,
        const ShortcutBindingSet(
          gamepadBindings: <GamepadBinding>[GamepadBinding(GamepadButton.y)],
        ),
      );
      GlobalExternalLookupRoute.set(() async {});
      expect(
        tryGlobalExternalLookupGamepadButton(registry, GamepadButton.x),
        isFalse,
      );
    });

    test('绑定命中但入口未注册 → 不吞按钮（功能不可用时吃键比没有功能更糟）', () {
      final FushiShortcutRegistry registry = windowsRegistry();
      registry.updateBinding(
        ShortcutAction.globalExternalLookup,
        const ShortcutBindingSet(
          gamepadBindings: <GamepadBinding>[GamepadBinding(GamepadButton.y)],
        ),
      );
      // 刻意不 set —— 模拟非桌面平台 / controller 未 start。
      expect(
        tryGlobalExternalLookupGamepadButton(registry, GamepadButton.y),
        isFalse,
      );
    });

    test('registry 为 null 时安全返回 false', () {
      GlobalExternalLookupRoute.set(() async {});
      expect(
        tryGlobalExternalLookupGamepadButton(null, GamepadButton.y),
        isFalse,
      );
    });
  });

  group('默认绑定', () {
    test('globalExternalLookup 只有键盘默认键，手柄/鼠标默认必须为空', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        final ShortcutBindingSet set = (FushiShortcutRegistry()
              ..loadDefaults(platform))
            .bindingsFor(ShortcutAction.globalExternalLookup);
        expect(
          set.keyboardBindings,
          isNotEmpty,
          reason: '$platform: 键盘默认键（Ctrl/Cmd+Alt+D）不该丢',
        );
        // 手柄这条**优先于页面 Actions**（与键盘的 OS 级 RegisterHotKey 同构），
        // 所以任何默认值都会从页面手里抢走一个按钮。必须由用户显式绑定。
        expect(
          set.gamepadBindings,
          isEmpty,
          reason: '$platform: 手柄给了默认值 = 抢走页面的一个按钮',
        );
        // 鼠标同理，且侧键在浏览器里是前进/后退，默认占用会很意外。
        expect(
          set.mouseBindings,
          isEmpty,
          reason: '$platform: 鼠标给了默认值 = 默认劫持侧键',
        );
      }
    });
  });

  group('接线源码守卫', () {
    test('手柄分支排在取焦点 context 之前（app 失焦时是唯一能走通的位置）', () {
      final String code = maskComments(
        File('lib/src/shortcuts/gamepad_service.dart').readAsStringSync(),
      );
      final int branch = code
          .indexOf('tryGlobalExternalLookupGamepadButton(registry, button)');
      final int ctx =
          code.indexOf('final BuildContext? ctx = _dispatchContext;');
      expect(branch, greaterThanOrEqualTo(0),
          reason: '手柄触发分支不见了：globalExternal 的手柄绑定会变成死绑定');
      expect(ctx, greaterThanOrEqualTo(0));
      expect(
        branch,
        lessThan(ctx),
        reason: '分支被挪到取焦点之后：主窗失焦时 MainWindowFocusGate 会让整条 '
            'Actions 路径落空，而"用户在别的程序里"正是本功能唯一的使用场景',
      );
    });

    test('controller 三个触发源汇入同一个执行体，没有各自复制一条查词链', () {
      final String code = maskComments(
        File('lib/src/lookup/global_lookup_controller.dart').readAsStringSync(),
      );
      // 键盘 / 手柄 / 鼠标三处都必须调 triggerSelectionLookup，而不是各自去拼
      // route 铸造 + 选区捕获 + _lookupExternal（复制一份必然漂移）。
      for (final String source in <String>['hotkey', 'gamepad', 'mouse']) {
        expect(
          code.contains("triggerSelectionLookup(source: '$source')"),
          isTrue,
          reason: '$source 触发源没有接到共享执行体',
        );
      }
    });

    test('剪贴板捕获传了 stillWanted（否则连按会排出一队各 600ms 的事务）', () {
      final String code = maskComments(
        File('lib/src/lookup/global_lookup_controller.dart').readAsStringSync(),
      );
      final int call =
          code.indexOf('SelectionCapture.captureForegroundSelection');
      expect(call, greaterThanOrEqualTo(0));
      expect(
        code.substring(call, call + 200).contains('stillWanted:'),
        isTrue,
        reason: '手柄/侧键比键盘容易连击，排队期间已被取代的那几次不该再动剪贴板',
      );
    });
  });
}
