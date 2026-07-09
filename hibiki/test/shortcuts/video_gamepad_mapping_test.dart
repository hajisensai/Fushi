import 'dart:convert';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

/// TODO-1342：视频播放器手柄映射守卫。
///
/// 视频页现在把手柄按键解析成 [ShortcutScope.video] 的动作
/// （见 `video_hibiki_page._handleVideoGamepadButton`）。本测试锁定默认映射、
/// video 作用域内的「无遮蔽」不变式，以及老快照升级到当前 schema 时手柄默认被补回。
void main() {
  /// 视频作用域期望的默认手柄映射（按钮 → 动作），单一真相源。
  const Map<GamepadButton, ShortcutAction> expected =
      <GamepadButton, ShortcutAction>{
    GamepadButton.a: ShortcutAction.videoTogglePlayPause,
    GamepadButton.b: ShortcutAction.videoEscape,
    GamepadButton.lb: ShortcutAction.videoSeekBackward,
    GamepadButton.dpadLeft: ShortcutAction.videoSeekBackward,
    GamepadButton.rb: ShortcutAction.videoSeekForward,
    GamepadButton.dpadRight: ShortcutAction.videoSeekForward,
    GamepadButton.dpadUp: ShortcutAction.videoVolumeUp,
    GamepadButton.dpadDown: ShortcutAction.videoVolumeDown,
    GamepadButton.x: ShortcutAction.videoPreviousSubtitle,
    GamepadButton.y: ShortcutAction.videoNextSubtitle,
    GamepadButton.lt: ShortcutAction.videoReplayCurrentSubtitle,
    GamepadButton.rt: ShortcutAction.videoToggleFullscreen,
    GamepadButton.start: ShortcutAction.videoToggleSubtitleList,
  };

  const List<TargetPlatform> platforms = <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ];

  group('video gamepad defaults', () {
    test('each expected button binds its video action on every platform', () {
      for (final TargetPlatform platform in platforms) {
        final Map<ShortcutAction, ShortcutBindingSet> defaults =
            ShortcutDefaults.forPlatform(platform);
        expected.forEach((GamepadButton button, ShortcutAction action) {
          expect(
            defaults[action]!
                .gamepadBindings
                .map((GamepadBinding b) => b.button),
            contains(button),
            reason: '${button.label} → ${action.key} missing on $platform',
          );
        });
      }
    });

    test(
        'no video-scope gamepad button is owned by more than one action '
        '(no shadowed gamepad default on the video page)', () {
      final Map<ShortcutAction, ShortcutBindingSet> defaults =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final Map<GamepadButton, ShortcutAction> seen =
          <GamepadButton, ShortcutAction>{};
      for (final ShortcutAction action
          in ShortcutAction.actionsForScope(ShortcutScope.video)) {
        for (final GamepadBinding gp in defaults[action]!.gamepadBindings) {
          expect(seen.containsKey(gp.button), isFalse,
              reason: '${gp.button} bound to both ${seen[gp.button]?.key} and '
                  '${action.key} — the later one is shadowed');
          seen[gp.button] = action;
        }
      }
    });

    test('adding video gamepad defaults did not change video keyboard defaults',
        () {
      // The new mapping only ADDS gamepad bindings — the keyboard defaults that
      // users may have persisted must be untouched, so the v4→v5 migration's
      // "keyboard untouched" judgement stays valid.
      final Map<ShortcutAction, ShortcutBindingSet> win =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      expect(
        win[ShortcutAction.videoTogglePlayPause]!
            .keyboardBindings
            .map((InputBinding b) => b.key),
        contains(LogicalKeyboardKey.space),
      );
      expect(
        win[ShortcutAction.videoSeekBackward]!
            .keyboardBindings
            .map((InputBinding b) => b.key),
        contains(LogicalKeyboardKey.arrowLeft),
      );
    });
  });

  group('resolveGamepad in the video scope', () {
    test('resolves every expected button to its video action', () {
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      expected.forEach((GamepadButton button, ShortcutAction action) {
        expect(
          registry.resolveGamepad(button, scope: ShortcutScope.video),
          action,
          reason: '${button.label} should resolve to ${action.key}',
        );
      });
    });

    test('an unbound button resolves to null (falls back to focus nav)', () {
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      // L3 / R3 / Select / Mode are intentionally left free for user rebind.
      expect(
        registry.resolveGamepad(GamepadButton.thumbLeft,
            scope: ShortcutScope.video),
        isNull,
      );
    });
  });

  group('schema migration v4 → v5 (TODO-1342 video gamepad defaults)', () {
    /// Builds a persisted snapshot as it would have looked at schema v4: the
    /// video actions had their keyboard defaults but NO gamepad bindings yet.
    Map<String, dynamic> v4Snapshot({
      Map<ShortcutAction, ShortcutBindingSet> overrides = const {},
    }) {
      final Map<ShortcutAction, ShortcutBindingSet> defaults =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final Map<String, dynamic> json = <String, dynamic>{
        kShortcutSchemaVersionKey: 4,
      };
      for (final MapEntry<ShortcutAction, ShortcutBindingSet> entry
          in defaults.entries) {
        final ShortcutAction action = entry.key;
        if (overrides.containsKey(action)) {
          json[action.key] = overrides[action]!.toJson();
          continue;
        }
        // v4 had no video gamepad bindings; every other scope is unchanged.
        final List<GamepadBinding> gamepad = action.scope == ShortcutScope.video
            ? const <GamepadBinding>[]
            : entry.value.gamepadBindings;
        json[action.key] = ShortcutBindingSet(
          keyboardBindings: entry.value.keyboardBindings,
          gamepadBindings: gamepad,
          mouseBindings: entry.value.mouseBindings,
        ).toJson();
      }
      return json;
    }

    test('untouched video actions get their new gamepad defaults restored', () {
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry();
      registry.loadFromJsonString(
        jsonEncode(v4Snapshot()),
        TargetPlatform.windows,
      );
      expected.forEach((GamepadButton button, ShortcutAction action) {
        expect(
          registry.resolveGamepad(button, scope: ShortcutScope.video),
          action,
          reason: '${button.label} → ${action.key} not restored after upgrade',
        );
      });
    });

    test(
        'a video action whose keyboard the user rebound is NOT force-restored '
        '(never clobber a user edit)', () {
      // User removed Space from play/pause → the migration must leave their
      // snapshot alone, so A stays unbound for that action.
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry();
      registry.loadFromJsonString(
        jsonEncode(
          v4Snapshot(
            overrides: <ShortcutAction, ShortcutBindingSet>{
              ShortcutAction.videoTogglePlayPause: const ShortcutBindingSet(
                keyboardBindings: <InputBinding>[
                  InputBinding(key: LogicalKeyboardKey.keyP),
                ],
              ),
            },
          ),
        ),
        TargetPlatform.windows,
      );
      expect(
        registry.resolveGamepad(GamepadButton.a, scope: ShortcutScope.video),
        isNull,
        reason: 'user-edited play/pause must not be force-restored to A',
      );
      // Untouched siblings still get their gamepad defaults.
      expect(
        registry.resolveGamepad(GamepadButton.b, scope: ShortcutScope.video),
        ShortcutAction.videoEscape,
      );
    });
  });
}
