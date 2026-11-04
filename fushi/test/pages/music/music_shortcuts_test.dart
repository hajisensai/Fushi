import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/gestures.dart'
    show kMiddleMouseButton, kPrimaryMouseButton, kSecondaryMouseButton;
import 'package:flutter/services.dart'
    show KeyDownEvent, LogicalKeyboardKey, PhysicalKeyboardKey;
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/pages/implementations/music/music_shortcuts.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

void main() {
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    group('默认绑定（$platform）', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(platform);

      test('空格与 K 都是播放 / 暂停（与视频 / 有声书同一习惯键）', () {
        for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.keyK,
        ]) {
          expect(
            registry.resolveKeyboard(
              key,
              modifiers: const <ModifierKey>{},
              scope: ShortcutScope.music,
            ),
            ShortcutAction.musicTogglePlayPause,
            reason: '$key',
          );
        }
      });

      test('歌词行跳转的鼠标键 = 有声书「点句跳转」绑定（默认中键）', () {
        expect(isMusicLyricsSeekPointer(registry, kMiddleMouseButton), isTrue);
        expect(
          isMusicLyricsSeekPointer(registry, kPrimaryMouseButton),
          isFalse,
        );
        expect(
          isMusicLyricsSeekPointer(registry, kSecondaryMouseButton),
          isFalse,
        );
      });
    });
  }

  test('改了有声书点句绑定，歌词行跟着变（同一个配置项）', () {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    registry.updateBinding(
      ShortcutAction.audiobookSeekToClickedSentence,
      const ShortcutBindingSet(mouseBindings: <MouseBinding>[MouseBinding(2)]),
    );
    expect(isMusicLyricsSeekPointer(registry, kMiddleMouseButton), isFalse);
    expect(isMusicLyricsSeekPointer(registry, kSecondaryMouseButton), isTrue);
  });

  test('文本框持焦时让路：空格是在打字', () {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    final MusicPlayerEngine engine = MusicPlayerEngine(
      backendFactory: () => throw UnimplementedError('不该碰到播放后端'),
    );
    addTearDown(engine.dispose);
    expect(
      handleMusicShortcutKey(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.space,
          logicalKey: LogicalKeyboardKey.space,
          timeStamp: Duration.zero,
        ),
        registry: registry,
        engine: engine,
        editableFocused: () => true,
      ),
      KeyEventResult.ignored,
    );
  });
}
