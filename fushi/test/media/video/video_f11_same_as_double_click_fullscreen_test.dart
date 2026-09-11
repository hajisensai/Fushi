import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/input_binding.dart' show ModifierKey;
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// BUG-2462：视频页里 F11（全局全屏键）必须与双击 / F 落在**同一个**全屏执行体
/// （全屏路由 + 原生窗口全屏），不能穿到 app 根那条只切原生窗口的裸 F11。
///
/// 两半都钉：① press-time 解析要从 global scope 认领 `globalToggleFullscreen`；
/// ② `videoActionCallbacks` 把它映到 `toggleFullscreen`，与 `videoToggleFullscreen`
/// 是同一个回调对象。缺 ① F11 解析成 null 穿到 app 根；缺 ② 解析到却没执行体、
/// 静默降级，症状与 ① 一样，而枚举守卫看不见。
void main() {
  FushiShortcutRegistry defaults() =>
      FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  VideoKeyboardResolution resolve(
    FushiShortcutRegistry registry,
    LogicalKeyboardKey logical,
    PhysicalKeyboardKey physical,
  ) => resolveVideoKeyboardShortcut(
    registry,
    KeyDownEvent(
      logicalKey: logical,
      physicalKey: physical,
      timeStamp: Duration.zero,
    ),
    modifiers: const <ModifierKey>{},
    hasEditableFocus: false,
    hasVisiblePopup: false,
    videoSurfaceHoldsFocus: true,
    videoNavigablePanelOpen: false,
  );

  test('F11 在视频页解析成 globalToggleFullscreen 并映到 toggleFullscreen', () {
    final FushiShortcutRegistry registry = defaults();
    final VideoKeyboardResolution byF11 = resolve(
      registry,
      LogicalKeyboardKey.f11,
      PhysicalKeyboardKey.f11,
    );
    expect(byF11.dispatch, VideoKeyboardDispatch.run);
    expect(byF11.action, ShortcutAction.globalToggleFullscreen);

    final VideoKeyboardResolution byF = resolve(
      registry,
      LogicalKeyboardKey.keyF,
      PhysicalKeyboardKey.keyF,
    );
    expect(byF.action, ShortcutAction.videoToggleFullscreen);

    final List<String> log = <String>[];
    final Map<ShortcutAction, VoidCallback> callbacks = videoActionCallbacks(
      _actions(log),
    );
    expect(
      callbacks[byF11.action],
      isNotNull,
      reason: '解析得到却没有执行体 = F11 静默降级成 app 根的裸窗口全屏',
    );
    expect(
      identical(callbacks[byF11.action], callbacks[byF.action]),
      isTrue,
      reason: 'F11 与 F（= 双击）必须是同一个 toggleFullscreen 回调对象',
    );
    callbacks[byF11.action]!();
    expect(log, <String>['toggleFullscreen']);
  });

  test('F11 只认按下沿：重复沿不消费，不会按住来回翻转全屏', () {
    final FushiShortcutRegistry registry = defaults();
    final VideoKeyboardResolution repeat = resolveVideoKeyboardShortcut(
      registry,
      const KeyRepeatEvent(
        logicalKey: LogicalKeyboardKey.f11,
        physicalKey: PhysicalKeyboardKey.f11,
        timeStamp: Duration.zero,
      ),
      modifiers: const <ModifierKey>{},
      hasEditableFocus: false,
      hasVisiblePopup: false,
      videoSurfaceHoldsFocus: true,
      videoNavigablePanelOpen: false,
    );
    expect(repeat.dispatch, isNot(VideoKeyboardDispatch.run));
  });

  test('对轴弹窗的冻结快捷键表把 F11 与视频全屏键一起摘掉', () {
    // 两处 `buildVideoPlayerShortcutsFromRegistry(... exclude: {...})` 调用点：
    // 弹窗里切全屏路由会让弹窗与路由栈错位，F11 现在也是视频全屏，必须同摘。
    for (final String path in <String>[
      'lib/src/pages/implementations/video_fushi_page.dart',
      'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
    ]) {
      final List<String> lines = File(path).readAsLinesSync();
      int blocks = 0;
      for (int i = 0; i < lines.length; i++) {
        if (!lines[i].contains('exclude: const <ShortcutAction>{')) continue;
        blocks++;
        final String block = lines.sublist(i, i + 8).join('\n');
        expect(
          block,
          contains('ShortcutAction.videoToggleFullscreen'),
          reason: '$path:${i + 1} 冻结表理应摘掉视频全屏键',
        );
        expect(
          block,
          contains('ShortcutAction.globalToggleFullscreen'),
          reason: '$path:${i + 1} 冻结表漏摘 F11（globalToggleFullscreen）',
        );
      }
      expect(blocks, greaterThan(0), reason: '$path 找不到 exclude 块，守卫空转');
    }
  });

  test('global scope 里只认领全屏键，其余 global 动作仍留给 app 根', () {
    final FushiShortcutRegistry registry = defaults();
    // Page Down 默认绑 globalScrollPageDown（global scope）：视频页不该截胡。
    final VideoKeyboardResolution pageDown = resolve(
      registry,
      LogicalKeyboardKey.pageDown,
      PhysicalKeyboardKey.pageDown,
    );
    expect(
      pageDown.action,
      isNot(ShortcutAction.globalScrollPageDown),
      reason: '只有 globalToggleFullscreen 允许从 global scope 被视频页认领',
    );
  });
}

VideoPlayerShortcutActions _actions(List<String> log) {
  void record(String name) => log.add(name);
  return VideoPlayerShortcutActions(
    togglePlayPause: () => record('togglePlayPause'),
    play: () => record('play'),
    pause: () => record('pause'),
    previousSubtitle: () => record('previousSubtitle'),
    nextSubtitle: () => record('nextSubtitle'),
    seekBackward: () => record('seekBackward'),
    seekForward: () => record('seekForward'),
    toggleShaderCompare: () => record('toggleShaderCompare'),
    volumeUp: () => record('volumeUp'),
    volumeDown: () => record('volumeDown'),
    toggleMute: () => record('toggleMute'),
    speedUp: () => record('speedUp'),
    speedDown: () => record('speedDown'),
    resetSpeed: () => record('resetSpeed'),
    toggleHoldSpeed: () => record('toggleHoldSpeed'),
    previousFrame: () => record('previousFrame'),
    nextFrame: () => record('nextFrame'),
    screenshot: () => record('screenshot'),
    toggleFullscreen: () => record('toggleFullscreen'),
    toggleSubtitleList: () => record('toggleSubtitleList'),
    searchSubtitleList: () => record('searchSubtitleList'),
    toggleImmersiveLock: () => record('toggleImmersiveLock'),
    toggleSubtitleBlur: () => record('toggleSubtitleBlur'),
    cycleSubtitleObscure: () => record('cycleSubtitleObscure'),
    toggleSubtitleHide: () => record('toggleSubtitleHide'),
    cycleSecondarySubtitleObscure: () =>
        record('cycleSecondarySubtitleObscure'),
    toggleSecondarySubtitleHide: () => record('toggleSecondarySubtitleHide'),
    toggleFavoriteSentence: () => record('toggleFavoriteSentence'),
    replayCurrentSubtitle: () => record('replayCurrentSubtitle'),
    replayPreviousSubtitle: () => record('replayPreviousSubtitle'),
    previousChapter: () => record('previousChapter'),
    nextChapter: () => record('nextChapter'),
    openSubtitleAlign: () => record('openSubtitleAlign'),
    subtitleDelayIncrease: () => record('subtitleDelayIncrease'),
    subtitleDelayDecrease: () => record('subtitleDelayDecrease'),
    alignSubtitleToPrev: () => record('alignSubtitleToPrev'),
    alignSubtitleToNext: () => record('alignSubtitleToNext'),
    enterCaret: () => record('enterCaret'),
    escape: () => record('escape'),
  );
}
