import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';

// TODO-1093 guards for the window-level ("app 级") fullscreen toggle shortcut.
// Distinct from videoToggleFullscreen (which only toggles the video surface):
// this flips the whole desktop window via WindowManager.setFullScreen and lives
// in the remappable registry (global scope, default F11).
void main() {
  group('globalToggleFullscreen exists in the global scope', () {
    test('enum has globalToggleFullscreen, scope=global, stable key', () {
      expect(
        ShortcutAction.values.map((ShortcutAction a) => a.name),
        contains('globalToggleFullscreen'),
      );
      expect(
        ShortcutAction.globalToggleFullscreen.scope,
        ShortcutScope.global,
      );
      expect(
        ShortcutAction.globalToggleFullscreen.key,
        'global_toggle_fullscreen',
      );
      // It is listed under the global scope so the settings page renders it.
      expect(
        ShortcutAction.actionsForScope(ShortcutScope.global),
        contains(ShortcutAction.globalToggleFullscreen),
      );
    });

    test('it is a separate action from the video-surface fullscreen toggle',
        () {
      expect(
        ShortcutAction.globalToggleFullscreen,
        isNot(ShortcutAction.videoToggleFullscreen),
      );
      expect(
        ShortcutAction.videoToggleFullscreen.scope,
        ShortcutScope.video,
      );
    });
  });

  group('defaults', () {
    test('desktop default keyboard binding == F11', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
      ]) {
        final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
            platform)[ShortcutAction.globalToggleFullscreen]!;
        expect(set.keyboardBindings, hasLength(1));
        final InputBinding binding = set.keyboardBindings.first;
        expect(binding.key, LogicalKeyboardKey.f11);
        expect(binding.modifiers, isEmpty);
      }
    });

    test('all 3 platform tables register the action', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.android,
      ]) {
        expect(
          ShortcutDefaults.forPlatform(platform)
              .containsKey(ShortcutAction.globalToggleFullscreen),
          isTrue,
        );
      }
    });

    test('mobile drops the F11 keyboard binding (window-level, no-op there)',
        () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
            platform)[ShortcutAction.globalToggleFullscreen]!;
        expect(set.keyboardBindings, isEmpty);
        expect(set.gamepadBindings, isEmpty);
      }
    });
  });

  group('executor wiring source guard', () {
    final String navSrc = File(
      'lib/src/shortcuts/global_navigation.dart',
    ).readAsStringSync();

    test('global_navigation dispatches globalToggleFullscreen', () {
      expect(
        navSrc.contains('ShortcutAction.globalToggleFullscreen'),
        isTrue,
      );
    });

    test('executor calls WindowManager.setFullScreen with inverted state', () {
      expect(navSrc.contains('windowManager.isFullScreen()'), isTrue);
      expect(navSrc.contains('windowManager.setFullScreen(!current)'), isTrue);
    });

    test('the toggle is fired from the global-navigation key handler', () {
      expect(navSrc.contains('_handleGlobalToggleFullscreen'), isTrue);
    });
  });

  group('settings page label exhaustiveness', () {
    final String pageSrc = File(
      'lib/src/pages/implementations/shortcut_settings_page.dart',
    ).readAsStringSync();

    test('_actionLabel covers globalToggleFullscreen', () {
      expect(
        pageSrc.contains('case ShortcutAction.globalToggleFullscreen:'),
        isTrue,
      );
    });
  });
}
