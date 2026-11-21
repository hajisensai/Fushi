import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';

/// 反馈 fMicnouU6V（拍板台「做」）：显示 / 隐藏 galgame 台词浮窗（游戏内 overlay）
/// 的全局快捷键，游戏窗口在前台时也能按。
///
/// 本文件钉：动作在 globalExternal scope（OS 级热键）、键盘-only、持久化 key
/// 稳定、有标签；所有平台默认不绑键；只在有台词浮窗的平台注册；执行体落到浮窗
/// 「关闭」按钮与「显示 Hook 浮窗」各自调的同一对方法（热键与按钮行为一致）。
void main() {
  const ShortcutAction action =
      ShortcutAction.globalExternalGalgameOverlayToggle;

  test('落在 globalExternal scope、键盘-only、持久化 key 稳定、有标签', () {
    expect(action.scope, ShortcutScope.globalExternal);
    expect(action.key, 'global_external_galgame_overlay_toggle');
    expect(action.channels, const <ShortcutChannel>{ShortcutChannel.keyboard});
    expect(action.allowedMouseButtons, isNull);
    expect(action.label, isNotEmpty);
    expect(
      ShortcutAction.fromKey('global_external_galgame_overlay_toggle'),
      action,
    );
  });

  test('所有平台默认都不绑键（不偷任何系统级组合键）', () {
    for (final TargetPlatform platform in TargetPlatform.values) {
      final ShortcutBindingSet? set = ShortcutDefaults.forPlatform(
        platform,
      )[action];
      expect(set, isNotNull, reason: '$platform 缺 ${action.key}');
      expect(set!.keyboardBindings, isEmpty, reason: '$platform');
      expect(set.gamepadBindings, isEmpty, reason: '$platform');
      expect(set.mouseBindings, isEmpty, reason: '$platform');
    }
  });

  test('只在有台词浮窗的平台注册 OS 热键', () {
    addTearDown(() => GalHookTextOverlayChannel.platformOverride = null);
    GalHookTextOverlayChannel.platformOverride = false;
    expect(GlobalLookupController.osHotKeyActionWorksHere(action), isFalse);
    GalHookTextOverlayChannel.platformOverride = true;
    expect(GlobalLookupController.osHotKeyActionWorksHere(action), isTrue);
  });

  test('执行体登记在 OS 热键表，落到浮窗关闭 / 手动显示的同一对方法', () {
    final String controller = File(
      'lib/src/lookup/global_lookup_controller.dart',
    ).readAsStringSync();
    expect(
      controller,
      matches(
        RegExp(
          r'ShortcutAction\.globalExternalGalgameOverlayToggle:\s+'
          r'toggleGalgameOverlay,',
        ),
      ),
    );
    expect(
      controller,
      matches(
        RegExp(
          r'Future<void> toggleGalgameOverlay\(\) =>\s+'
          r'GalHookTextOverlayController\.instance\.toggleVisibility\(\);',
        ),
      ),
    );

    final String overlay = File(
      'lib/src/lookup/gal_hook_text_overlay_controller.dart',
    ).readAsStringSync();
    // 可见 → 浮窗「关闭」按钮的方法；不可见 → 「显示 Hook 浮窗」的方法。
    expect(
      overlay,
      matches(
        RegExp(
          r'Future<void> toggleVisibility\(\) async \{\s+'
          r'if \(!_started\) return;\s+'
          r'if \(_visible\) \{\s+'
          r'await closeForCurrentSession\(\);\s+'
          r'\} else \{\s+'
          r'await showManually\(\);',
        ),
      ),
    );
    expect(overlay, contains('onClose: closeForCurrentSession,'));
  });
}
