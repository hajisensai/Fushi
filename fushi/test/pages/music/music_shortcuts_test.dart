import 'dart:ui' show KeyEventDeviceType;

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/gestures.dart'
    show kMiddleMouseButton, kPrimaryMouseButton, kSecondaryMouseButton;
import 'package:flutter/services.dart'
    show KeyDownEvent, LogicalKeyboardKey, PhysicalKeyboardKey;
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
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

      // 拍板台 vo1KPp0_Rh：全屏播放页 / 歌词页裸 ←/→ ±5 秒；曲库页裸方向键留给网格移焦。
      test('播放页裸 ←/→ = ±5 秒，曲库页裸方向键不被播放控制夺走', () {
        ShortcutAction? resolve(
          MusicShortcutSurface surface,
          LogicalKeyboardKey key, [
          Set<ModifierKey> modifiers = const <ModifierKey>{},
        ]) =>
            resolveMusicShortcut(registry, surface, key, modifiers: modifiers);

        expect(
          resolve(MusicShortcutSurface.player, LogicalKeyboardKey.arrowRight),
          ShortcutAction.musicPlayerSeekForward,
        );
        expect(
          resolve(MusicShortcutSurface.player, LogicalKeyboardKey.arrowLeft),
          ShortcutAction.musicPlayerSeekBackward,
        );
        expect(
          resolve(MusicShortcutSurface.library, LogicalKeyboardKey.arrowRight),
          isNull,
        );
        expect(
          resolve(MusicShortcutSurface.library, LogicalKeyboardKey.arrowLeft),
          isNull,
        );
        // 两处都认的 music 组照旧：Shift+←/→ ±5 秒、空格播放暂停。
        for (final MusicShortcutSurface surface
            in MusicShortcutSurface.values) {
          expect(
            resolve(surface, LogicalKeyboardKey.arrowRight, const <ModifierKey>{
              ModifierKey.shift,
            }),
            ShortcutAction.musicSeekForward,
            reason: '$surface',
          );
          expect(
            resolve(surface, LogicalKeyboardKey.arrowLeft, const <ModifierKey>{
              ModifierKey.shift,
            }),
            ShortcutAction.musicSeekBackward,
            reason: '$surface',
          );
          expect(
            resolve(surface, LogicalKeyboardKey.space),
            ShortcutAction.musicTogglePlayPause,
            reason: '$surface',
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

  test('musicPlayer 与 music 同一 co-active 组，只开键盘、跟音乐模块显隐', () {
    expect(ShortcutScope.musicPlayer.coactiveScopes, <ShortcutScope>[
      ShortcutScope.musicPlayer,
      ShortcutScope.music,
    ]);
    expect(
      ShortcutScope.music.coactiveScopes,
      ShortcutScope.musicPlayer.coactiveScopes,
    );
    expect(ShortcutScope.musicPlayer.channels, <ShortcutChannel>{
      ShortcutChannel.keyboard,
    });
    expect(moduleOfShortcutScope(ShortcutScope.musicPlayer), ModuleId.music);
    // 播放页的 scope 组先解析自己、再落回 music。
    expect(MusicShortcutSurface.player.scopes, <ShortcutScope>[
      ShortcutScope.musicPlayer,
      ShortcutScope.music,
    ]);
    expect(MusicShortcutSurface.library.scopes, <ShortcutScope>[
      ShortcutScope.music,
    ]);
  });

  test('改绑播放页 ±5 秒后曲库页仍不受影响', () {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    registry.updateBinding(
      ShortcutAction.musicPlayerSeekForward,
      const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.keyL),
        ],
      ),
    );
    expect(
      resolveMusicShortcut(
        registry,
        MusicShortcutSurface.player,
        LogicalKeyboardKey.keyL,
        modifiers: const <ModifierKey>{},
      ),
      ShortcutAction.musicPlayerSeekForward,
    );
    expect(
      resolveMusicShortcut(
        registry,
        MusicShortcutSurface.player,
        LogicalKeyboardKey.arrowRight,
        modifiers: const <ModifierKey>{},
      ),
      isNull,
    );
    expect(
      resolveMusicShortcut(
        registry,
        MusicShortcutSurface.library,
        LogicalKeyboardKey.keyL,
        modifiers: const <ModifierKey>{},
      ),
      isNull,
    );
  });

  test('引擎没在放时播放页 ±5 秒不消费（落回焦点导航）', () {
    final MusicPlayerEngine engine = MusicPlayerEngine(
      backendFactory: () => throw UnimplementedError('不该碰到播放后端'),
    );
    addTearDown(engine.dispose);
    expect(
      dispatchMusicShortcut(ShortcutAction.musicPlayerSeekForward, engine),
      isFalse,
    );
    expect(
      dispatchMusicShortcut(ShortcutAction.musicPlayerSeekBackward, engine),
      isFalse,
    );
  });

  test('手柄 / 遥控器十字键的左右不被播放页 ±5 秒夺走（只认键盘）', () {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.android);
    for (final (
          LogicalKeyboardKey key,
          PhysicalKeyboardKey physical,
          ShortcutAction expected,
        )
        in <(LogicalKeyboardKey, PhysicalKeyboardKey, ShortcutAction)>[
          (
            LogicalKeyboardKey.arrowRight,
            PhysicalKeyboardKey.arrowRight,
            ShortcutAction.musicPlayerSeekForward,
          ),
          (
            LogicalKeyboardKey.arrowLeft,
            PhysicalKeyboardKey.arrowLeft,
            ShortcutAction.musicPlayerSeekBackward,
          ),
        ]) {
      // 键盘方向键：播放页解析成 ±5 秒。
      expect(
        resolveMusicKeyEvent(
          KeyDownEvent(
            physicalKey: physical,
            logicalKey: key,
            timeStamp: Duration.zero,
          ),
          registry: registry,
          surface: MusicShortcutSurface.player,
          modifiers: const <ModifierKey>{},
        ),
        expected,
      );
      // 同一个 arrow 键来自手柄 / 遥控器：不解析，交回焦点导航。
      for (final KeyEventDeviceType device in <KeyEventDeviceType>[
        KeyEventDeviceType.gamepad,
        KeyEventDeviceType.directionalPad,
        KeyEventDeviceType.joystick,
      ]) {
        expect(
          resolveMusicKeyEvent(
            KeyDownEvent(
              physicalKey: physical,
              logicalKey: key,
              timeStamp: Duration.zero,
              deviceType: device,
            ),
            registry: registry,
            surface: MusicShortcutSurface.player,
            modifiers: const <ModifierKey>{},
          ),
          isNull,
          reason: '$key from $device',
        );
      }
    }
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
        surface: MusicShortcutSurface.player,
        editableFocused: () => true,
      ),
      KeyEventResult.ignored,
    );
  });
}
