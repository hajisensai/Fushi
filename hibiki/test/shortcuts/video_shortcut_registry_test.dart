import 'dart:convert';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_shortcuts.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

VideoPlayerShortcutActions _recordingActions(List<String> log) {
  return VideoPlayerShortcutActions(
    togglePlayPause: () => log.add('togglePlayPause'),
    play: () => log.add('play'),
    pause: () => log.add('pause'),
    previousSubtitle: () => log.add('previousSubtitle'),
    nextSubtitle: () => log.add('nextSubtitle'),
    seekBackward: () => log.add('seekBackward'),
    seekForward: () => log.add('seekForward'),
    toggleShaderCompare: () => log.add('toggleShaderCompare'),
    volumeUp: () => log.add('volumeUp'),
    volumeDown: () => log.add('volumeDown'),
    toggleMute: () => log.add('toggleMute'),
    speedUp: () => log.add('speedUp'),
    speedDown: () => log.add('speedDown'),
    resetSpeed: () => log.add('resetSpeed'),
    previousFrame: () => log.add('previousFrame'),
    nextFrame: () => log.add('nextFrame'),
    screenshot: () => log.add('screenshot'),
    toggleFullscreen: () => log.add('toggleFullscreen'),
    toggleSubtitleList: () => log.add('toggleSubtitleList'),
    toggleImmersiveLock: () => log.add('toggleImmersiveLock'),
    toggleSubtitleBlur: () => log.add('toggleSubtitleBlur'),
    toggleFavoriteSentence: () => log.add('toggleFavoriteSentence'),
    replayCurrentSubtitle: () => log.add('replayCurrentSubtitle'),
    replayPreviousSubtitle: () => log.add('replayPreviousSubtitle'),
    previousChapter: () => log.add('previousChapter'),
    nextChapter: () => log.add('nextChapter'),
    escape: () => log.add('escape'),
  );
}

/// [SingleActivator] does not implement value equality, so a freshly
/// constructed activator never equals one already used as a map key. Match on
/// the public fields instead to find the callback the player wired for a given
/// key + modifiers (+ repeat policy).
MapEntry<SingleActivator, VoidCallback>? _findSingleActivator(
  Map<ShortcutActivator, VoidCallback> activators,
  LogicalKeyboardKey trigger, {
  bool control = false,
  bool shift = false,
  bool alt = false,
  bool meta = false,
  bool? includeRepeats,
}) {
  for (final MapEntry<ShortcutActivator, VoidCallback> entry
      in activators.entries) {
    final ShortcutActivator key = entry.key;
    if (key is! SingleActivator) continue;
    if (key.trigger != trigger) continue;
    if (key.control != control || key.shift != shift) continue;
    if (key.alt != alt || key.meta != meta) continue;
    if (includeRepeats != null && key.includeRepeats != includeRepeats) {
      continue;
    }
    return MapEntry<SingleActivator, VoidCallback>(key, entry.value);
  }
  return null;
}

void main() {
  group('video scope is registered in the shortcut registry (TODO-134)', () {
    test('the video scope exists and owns actions', () {
      expect(ShortcutScope.values, contains(ShortcutScope.video));
      final List<ShortcutAction> videoActions =
          ShortcutAction.actionsForScope(ShortcutScope.video);
      expect(videoActions, isNotEmpty);
      for (final ShortcutAction action in videoActions) {
        expect(action.scope, ShortcutScope.video);
        expect(action.key, startsWith('video_'));
      }
    });

    test('the video scope is its own co-active group (standalone surface)', () {
      expect(ShortcutScope.video.coactiveScopes, <ShortcutScope>[
        ShortcutScope.video,
      ]);
    });

    test('every video action has platform defaults on every platform', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        final Map<ShortcutAction, ShortcutBindingSet> defaults =
            ShortcutDefaults.forPlatform(platform);
        for (final ShortcutAction action
            in ShortcutAction.actionsForScope(ShortcutScope.video)) {
          expect(defaults.containsKey(action), isTrue,
              reason: 'missing $platform default for ${action.key}');
        }
      }
    });

    test('default video keys resolve through the registry (asbplayer/mpv map)',
        () {
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      expect(
        registry.resolveKeyboard(LogicalKeyboardKey.space,
            modifiers: const <ModifierKey>{}, scope: ShortcutScope.video),
        ShortcutAction.videoTogglePlayPause,
      );
      expect(
        registry.resolveKeyboard(LogicalKeyboardKey.keyF,
            modifiers: const <ModifierKey>{}, scope: ShortcutScope.video),
        ShortcutAction.videoToggleFullscreen,
      );
      expect(
        registry.resolveKeyboard(LogicalKeyboardKey.keyS,
            modifiers: const <ModifierKey>{}, scope: ShortcutScope.video),
        ShortcutAction.videoScreenshot,
      );
      expect(
        registry.resolveKeyboard(LogicalKeyboardKey.space,
            modifiers: const <ModifierKey>{}, scope: ShortcutScope.reader),
        ShortcutAction.readerPageForward,
      );
    });
  });

  group('settings-page scope enumeration covers the video scope (TODO-134)',
      () {
    test(
        'iterating ShortcutScope.values x actionsForScope (how the settings '
        'page builds its list) yields the full video action set', () {
      final Map<ShortcutScope, List<ShortcutAction>> byScope =
          <ShortcutScope, List<ShortcutAction>>{
        for (final ShortcutScope scope in ShortcutScope.values)
          scope: ShortcutAction.actionsForScope(scope),
      };
      expect(byScope.keys, contains(ShortcutScope.video));
      expect(byScope[ShortcutScope.video], isNotEmpty);

      final Set<ShortcutAction> enumeratedVideo =
          byScope[ShortcutScope.video]!.toSet();
      final Set<ShortcutAction> allVideo = ShortcutAction.values
          .where((ShortcutAction a) => a.scope == ShortcutScope.video)
          .toSet();
      expect(enumeratedVideo, allVideo);
      expect(allVideo.length, greaterThan(10));
    });
  });

  group('video rebind persists and resolves to the new key (TODO-134)', () {
    test(
        'rebind -> save (toJson) -> load (fromJson) -> resolves to the NEW key, '
        'and the player activator map points the new key at the action', () {
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      expect(
        registry.resolveKeyboard(LogicalKeyboardKey.keyS,
            modifiers: const <ModifierKey>{}, scope: ShortcutScope.video),
        ShortcutAction.videoScreenshot,
      );

      const InputBinding newBinding = InputBinding(
        key: LogicalKeyboardKey.keyG,
        modifiers: <ModifierKey>{ModifierKey.ctrl},
      );
      registry.updateBinding(
        ShortcutAction.videoScreenshot,
        const ShortcutBindingSet(keyboardBindings: <InputBinding>[newBinding]),
      );

      final String json = registry.toJsonString();
      final HibikiShortcutRegistry reloaded = HibikiShortcutRegistry()
        ..loadFromJsonString(json, TargetPlatform.windows);

      expect(
        reloaded.resolveKeyboard(LogicalKeyboardKey.keyG,
            modifiers: const <ModifierKey>{ModifierKey.ctrl},
            scope: ShortcutScope.video),
        ShortcutAction.videoScreenshot,
      );
      expect(
        reloaded.resolveKeyboard(LogicalKeyboardKey.keyS,
            modifiers: const <ModifierKey>{}, scope: ShortcutScope.video),
        isNull,
        reason: 'old screenshot key must be gone after the rebind round trip',
      );

      final List<String> log = <String>[];
      final Map<ShortcutActivator, VoidCallback> activators =
          buildVideoPlayerShortcutsFromRegistry(
        reloaded,
        _recordingActions(log),
      );
      final MapEntry<SingleActivator, VoidCallback>? newEntry =
          _findSingleActivator(activators, LogicalKeyboardKey.keyG,
              control: true);
      expect(newEntry, isNotNull,
          reason: 'the rebound Ctrl+G must be a live player activator');
      newEntry!.value();
      expect(log, <String>['screenshot']);

      // The old default KeyS (no modifiers) must no longer be wired.
      expect(
        _findSingleActivator(activators, LogicalKeyboardKey.keyS),
        isNull,
        reason: 'old screenshot key must be gone from the player activators',
      );
    });

    test(
        'buildVideoPlayerShortcutsFromRegistry keeps subtitle-blur '
        'press-edge-only (includeRepeats:false) while others repeat', () {
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      final Map<ShortcutActivator, VoidCallback> activators =
          buildVideoPlayerShortcutsFromRegistry(
              registry, _recordingActions([]));

      // Subtitle blur default is KeyB and must be installed press-edge-only.
      expect(
        _findSingleActivator(activators, LogicalKeyboardKey.keyB,
            includeRepeats: false),
        isNotNull,
        reason: 'subtitle-blur must be press-edge-only (includeRepeats:false)',
      );
      // A repeating KeyB activator must NOT exist (would change behaviour).
      expect(
        _findSingleActivator(activators, LogicalKeyboardKey.keyB,
            includeRepeats: true),
        isNull,
        reason: 'subtitle-blur must not be a repeating activator',
      );
      // A non-blur video key (e.g. screenshot KeyS) stays repeating.
      expect(
        _findSingleActivator(activators, LogicalKeyboardKey.keyS,
            includeRepeats: true),
        isNotNull,
        reason: 'ordinary video keys honour OS key-repeat',
      );
    });
  });

  test('toJson exposes a video action key (registry persistence covers video)',
      () {
    final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    final Map<String, dynamic> json = registry.toJson();
    expect(json.containsKey(ShortcutAction.videoScreenshot.key), isTrue);
    final String encoded = jsonEncode(json);
    expect(encoded.contains('video_screenshot'), isTrue);
  });

  group(
      'old snapshots get newly-added default keys back (BUG-318 / TODO-562: '
      'F12 fullscreen regressed for users who saved shortcuts before F12 '
      'was added to defaults)', () {
    // A pre-F12 persisted snapshot: video_toggle_fullscreen held ONLY the old
    // default key F (no F12), and the old app never wrote a schema version key.
    // The fullscreen entry is the "complete old default", which is exactly the
    // signal the user never touched it.
    String legacyFullscreenJson(
        {List<String> fullscreenKeyboard = const ['KeyF']}) {
      return jsonEncode(<String, dynamic>{
        // No __schema_version__ key (legacy writer).
        ShortcutAction.videoToggleFullscreen.key: <String, dynamic>{
          'keyboard': fullscreenKeyboard,
          'gamepad': <String>[],
          'mouse': <String>[],
        },
      });
    }

    test(
        'legacy snapshot (only F, no schema version) regains F12 after load '
        '— this is the F12-no-response fix; reverting the migration makes F12 '
        'resolve to null', () {
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
        ..loadFromJsonString(legacyFullscreenJson(), TargetPlatform.windows);

      // F (the user's preserved key) still works.
      expect(
        registry.resolveKeyboard(LogicalKeyboardKey.keyF,
            modifiers: const <ModifierKey>{}, scope: ShortcutScope.video),
        ShortcutAction.videoToggleFullscreen,
        reason: 'the existing F key must survive the migration',
      );
      // F12 (the newly-added default) is restored — the regression fix.
      expect(
        registry.resolveKeyboard(LogicalKeyboardKey.f12,
            modifiers: const <ModifierKey>{}, scope: ShortcutScope.video),
        ShortcutAction.videoToggleFullscreen,
        reason: 'F12 must be re-added to fullscreen for the untouched snapshot',
      );

      // And the player activator map actually fires fullscreen on F12.
      final List<String> log = <String>[];
      final Map<ShortcutActivator, VoidCallback> activators =
          buildVideoPlayerShortcutsFromRegistry(
              registry, _recordingActions(log));
      final MapEntry<SingleActivator, VoidCallback>? f12Entry =
          _findSingleActivator(activators, LogicalKeyboardKey.f12);
      expect(f12Entry, isNotNull,
          reason: 'F12 must be a live fullscreen player activator');
      f12Entry!.value();
      expect(log, <String>['toggleFullscreen']);
    });

    test(
        'a snapshot the user actually rebound (fullscreen on G, not F) is NOT '
        'force-fed F12 — migration only touches untouched actions', () {
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
        ..loadFromJsonString(
          legacyFullscreenJson(fullscreenKeyboard: <String>['KeyG']),
          TargetPlatform.windows,
        );

      // The user's chosen G is honoured.
      expect(
        registry.resolveKeyboard(LogicalKeyboardKey.keyG,
            modifiers: const <ModifierKey>{}, scope: ShortcutScope.video),
        ShortcutAction.videoToggleFullscreen,
      );
      // F12 must NOT be auto-injected over a binding the user deliberately set.
      expect(
        registry.resolveKeyboard(LogicalKeyboardKey.f12,
            modifiers: const <ModifierKey>{}, scope: ShortcutScope.video),
        isNull,
        reason: 'migration must not override a user-customised fullscreen key',
      );
    });

    test(
        'a current snapshot (schema version present) is not migrated again — '
        'no double-add, user choices are final', () {
      // User on the new version deliberately set fullscreen to ONLY F (dropped
      // F12). The snapshot carries the current schema version, so migration is
      // skipped and F stays the sole key.
      final String currentJson = jsonEncode(<String, dynamic>{
        kShortcutSchemaVersionKey: kShortcutSchemaVersion,
        ShortcutAction.videoToggleFullscreen.key: <String, dynamic>{
          'keyboard': <String>['KeyF'],
          'gamepad': <String>[],
          'mouse': <String>[],
        },
      });
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
        ..loadFromJsonString(currentJson, TargetPlatform.windows);

      expect(
        registry.resolveKeyboard(LogicalKeyboardKey.f12,
            modifiers: const <ModifierKey>{}, scope: ShortcutScope.video),
        isNull,
        reason:
            'a same-version snapshot must be taken verbatim (no re-migration)',
      );
      expect(
        registry.resolveKeyboard(LogicalKeyboardKey.keyF,
            modifiers: const <ModifierKey>{}, scope: ShortcutScope.video),
        ShortcutAction.videoToggleFullscreen,
      );
    });

    test('toJson now stamps the current schema version', () {
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      final Map<String, dynamic> json = registry.toJson();
      expect(json[kShortcutSchemaVersionKey], kShortcutSchemaVersion);
    });
  });
}
