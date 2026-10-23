import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 反馈 vTpcneuvAm：「截屏识字」的全局快捷键
/// （[ShortcutAction.globalExternalScreenOcr]）。执行体与桌面应用外悬浮球的「截屏
/// 识字」按钮共用（悬浮球宿主装到 [GlobalLookupController.screenOcrHandler] 上），
/// 本文件钉「有动作、有默认键且不撞键、OS 热键真的接到了执行体」。
void main() {
  test('落在 globalExternal scope、键盘-only、持久化 key 稳定', () {
    expect(
      ShortcutAction.globalExternalScreenOcr.scope,
      ShortcutScope.globalExternal,
    );
    expect(
      ShortcutAction.globalExternalScreenOcr.key,
      'global_external_screen_ocr',
    );
    expect(
      ShortcutAction.globalExternalScreenOcr.channels,
      const <ShortcutChannel>{ShortcutChannel.keyboard},
    );
  });

  test('桌面默认 Ctrl+Alt+O（macOS Meta+Alt+O），移动端无绑定', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    ]) {
      final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
        platform,
      )[ShortcutAction.globalExternalScreenOcr]!;
      expect(set.keyboardBindings, hasLength(1), reason: '$platform');
      expect(set.keyboardBindings.first.key, LogicalKeyboardKey.keyO);
      expect(
        set.keyboardBindings.first.modifiers,
        platform == TargetPlatform.macOS
            ? <ModifierKey>{ModifierKey.meta, ModifierKey.alt}
            : <ModifierKey>{ModifierKey.ctrl, ModifierKey.alt},
      );
      expect(set.gamepadBindings, isEmpty);
      expect(set.mouseBindings, isEmpty);
    }
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
        platform,
      )[ShortcutAction.globalExternalScreenOcr]!;
      expect(set.keyboardBindings, isEmpty, reason: '$platform');
    }
  });

  test('默认键与任何 scope 的默认绑定都不冲突（OS 热键全系统吞键）', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    ]) {
      final FushiShortcutRegistry registry = FushiShortcutRegistry();
      registry.loadDefaults(platform);
      final InputBinding binding = registry
          .bindingsFor(ShortcutAction.globalExternalScreenOcr)
          .keyboardBindings
          .first;
      for (final ShortcutScope scope in ShortcutScope.values) {
        expect(
          registry.hasKeyboardConflict(
            scope,
            binding,
            exclude: ShortcutAction.globalExternalScreenOcr,
          ),
          isNull,
          reason: '$platform / $scope 的默认绑定撞上了截屏识字热键',
        );
      }
    }
  });

  test('OS 热键执行体登记在 _osHotKeyActions，并转给悬浮球宿主', () async {
    final String controller = File(
      'lib/src/lookup/global_lookup_controller.dart',
    ).readAsStringSync();
    expect(
      controller,
      contains('ShortcutAction.globalExternalScreenOcr: triggerScreenOcr,'),
    );
    final String host = File(
      'lib/src/floating_ball/app_floating_ball_host.dart',
    ).readAsStringSync();
    expect(
      host,
      contains(
        'GlobalLookupController.instance.screenOcrHandler = _screenOcrFromHotKey;',
      ),
    );
    expect(host, contains('await _desktopScreenOcr(null);'));

    // 执行体真的转发到装上的处理器。
    final GlobalLookupController lookup = GlobalLookupController.instance;
    final Future<void> Function()? previous = lookup.screenOcrHandler;
    int calls = 0;
    lookup.screenOcrHandler = () async => calls++;
    try {
      await lookup.triggerScreenOcr();
    } finally {
      lookup.screenOcrHandler = previous;
    }
    expect(calls, 1);
  });
}
