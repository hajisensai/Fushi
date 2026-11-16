import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';

/// 反馈 N8qzDdzIvD（拍板台「做」）：galgame 台词朗读（TTS）的全局快捷键，游戏
/// 窗口在前台时也能按，方便跟读。
///
/// 本文件钉：动作在 globalExternal scope（OS 级热键）、键盘-only、持久化 key
/// 稳定、有标签；所有平台默认不绑键；只在有台词浮窗的平台注册；执行体就是台词
/// 浮窗「朗读」按钮接的同一个方法（热键与按钮行为一致）。
void main() {
  const ShortcutAction action = ShortcutAction.globalExternalGalgameSpeakLine;

  test('落在 globalExternal scope、键盘-only、持久化 key 稳定、有标签', () {
    expect(action.scope, ShortcutScope.globalExternal);
    expect(action.key, 'global_external_galgame_speak_line');
    expect(action.channels, const <ShortcutChannel>{ShortcutChannel.keyboard});
    expect(action.allowedMouseButtons, isNull);
    expect(action.label, isNotEmpty);
    expect(
      ShortcutAction.fromKey('global_external_galgame_speak_line'),
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

  test('执行体登记在 OS 热键表，且是台词浮窗「朗读」按钮的同一个方法', () {
    final String controller = File(
      'lib/src/lookup/global_lookup_controller.dart',
    ).readAsStringSync();
    expect(
      controller,
      contains(
        'ShortcutAction.globalExternalGalgameSpeakLine: speakGalgameLine,',
      ),
    );
    expect(
      controller,
      matches(
        RegExp(
          r'Future<void> speakGalgameLine\(\) =>\s+'
          r'GalHookTextOverlayController\.instance\.speakCurrentLine\(\);',
        ),
      ),
    );

    // 浮窗「朗读」按钮那一侧接的就是 speakCurrentLine——热键与按钮行为一致。
    final String overlay = File(
      'lib/src/lookup/gal_hook_text_overlay_controller.dart',
    ).readAsStringSync();
    expect(overlay, contains('onSpeakLine: speakCurrentLine,'));
  });
}
