import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 按住临时倍速快捷键（用户请求：与手机长按画面同语义——按下加速、松开恢复）。
///
/// 三层契约：
/// 1. 纯状态机 [resolveHoldSpeedKeyTransition]：keydown 进入、repeat 消费、keyup
///    恢复，且 keyup/repeat 只按触发键识别（松修饰键不卡加速态）。
/// 2. 绑定命中 [keyDownMatchesHoldSpeed]：默认裸 E 命中；文本框持焦不命中；别的
///    视频键不误命中。
/// 3. 接线约束：videoHoldSpeed 的键盘绑定**不进** CallbackShortcuts activator 表
///    （装进去 keydown 就被消费，页面级 Focus.onKeyEvent 永远收不到、keyup 语义
///    无从谈起）；手柄通道经 videoActionCallbacks 的 toggleHoldSpeed 仍然活着。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  KeyDownEvent down(LogicalKeyboardKey logical, PhysicalKeyboardKey physical) =>
      KeyDownEvent(
        physicalKey: physical,
        logicalKey: logical,
        timeStamp: Duration.zero,
      );

  group('resolveHoldSpeedKeyTransition 状态机', () {
    test('命中绑定的 keydown → engage', () {
      expect(
        resolveHoldSpeedKeyTransition(
          event: down(LogicalKeyboardKey.keyE, PhysicalKeyboardKey.keyE),
          activeTriggerKey: null,
          matchesHoldSpeedBinding: true,
        ),
        HoldSpeedKeyTransition.engage,
      );
    });

    test('未命中绑定的 keydown → none（不消费，交回既有解析路径）', () {
      expect(
        resolveHoldSpeedKeyTransition(
          event: down(LogicalKeyboardKey.keyS, PhysicalKeyboardKey.keyS),
          activeTriggerKey: null,
          matchesHoldSpeedBinding: false,
        ),
        HoldSpeedKeyTransition.none,
      );
    });

    test('按住期间触发键的 OS key-repeat → swallow（不重入、不冒泡）', () {
      expect(
        resolveHoldSpeedKeyTransition(
          event: const KeyRepeatEvent(
            physicalKey: PhysicalKeyboardKey.keyE,
            logicalKey: LogicalKeyboardKey.keyE,
            timeStamp: Duration.zero,
          ),
          activeTriggerKey: LogicalKeyboardKey.keyE,
          matchesHoldSpeedBinding: false,
        ),
        HoldSpeedKeyTransition.swallow,
      );
    });

    test('触发键 keyup → release（即使修饰键已先松开也恢复，不卡加速态）', () {
      expect(
        resolveHoldSpeedKeyTransition(
          event: const KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.keyE,
            logicalKey: LogicalKeyboardKey.keyE,
            timeStamp: Duration.zero,
          ),
          activeTriggerKey: LogicalKeyboardKey.keyE,
          matchesHoldSpeedBinding: false,
        ),
        HoldSpeedKeyTransition.release,
      );
    });

    test('非触发键的 keyup/repeat/keydown 在按住期间 → none（其它键照常工作）', () {
      const KeyUpEvent otherUp = KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyS,
        logicalKey: LogicalKeyboardKey.keyS,
        timeStamp: Duration.zero,
      );
      expect(
        resolveHoldSpeedKeyTransition(
          event: otherUp,
          activeTriggerKey: LogicalKeyboardKey.keyE,
          matchesHoldSpeedBinding: false,
        ),
        HoldSpeedKeyTransition.none,
      );
      expect(
        resolveHoldSpeedKeyTransition(
          event: down(LogicalKeyboardKey.keyS, PhysicalKeyboardKey.keyS),
          activeTriggerKey: LogicalKeyboardKey.keyE,
          matchesHoldSpeedBinding: false,
        ),
        HoldSpeedKeyTransition.none,
      );
    });

    test('未按住时的 keyup → none（松开别的键不误恢复）', () {
      expect(
        resolveHoldSpeedKeyTransition(
          event: const KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.keyE,
            logicalKey: LogicalKeyboardKey.keyE,
            timeStamp: Duration.zero,
          ),
          activeTriggerKey: null,
          matchesHoldSpeedBinding: false,
        ),
        HoldSpeedKeyTransition.none,
      );
    });
  });

  group('keyDownMatchesHoldSpeed 绑定命中（Windows 默认表）', () {
    HibikiShortcutRegistry registry() =>
        HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

    test('默认裸 E 命中', () {
      expect(
        keyDownMatchesHoldSpeed(
          registry(),
          down(LogicalKeyboardKey.keyE, PhysicalKeyboardKey.keyE),
          hasEditableFocus: false,
        ),
        isTrue,
      );
    });

    test('文本框持焦时恒不命中（输入不误触加速）', () {
      expect(
        keyDownMatchesHoldSpeed(
          registry(),
          down(LogicalKeyboardKey.keyE, PhysicalKeyboardKey.keyE),
          hasEditableFocus: true,
        ),
        isFalse,
      );
    });

    test('绑给其它视频动作的键不误命中（] = 加速步进）', () {
      expect(
        keyDownMatchesHoldSpeed(
          registry(),
          down(
            LogicalKeyboardKey.bracketRight,
            PhysicalKeyboardKey.bracketRight,
          ),
          hasEditableFocus: false,
        ),
        isFalse,
      );
    });
  });

  group('接线约束', () {
    VideoPlayerShortcutActions actions(List<String> log) {
      void noop() {}
      return VideoPlayerShortcutActions(
        togglePlayPause: noop,
        play: noop,
        pause: noop,
        previousSubtitle: noop,
        nextSubtitle: noop,
        seekBackward: noop,
        seekForward: noop,
        toggleShaderCompare: noop,
        volumeUp: noop,
        volumeDown: noop,
        toggleMute: noop,
        speedUp: noop,
        speedDown: noop,
        resetSpeed: noop,
        toggleHoldSpeed: () => log.add('toggleHoldSpeed'),
        previousFrame: noop,
        nextFrame: noop,
        screenshot: noop,
        toggleFullscreen: noop,
        toggleSubtitleList: noop,
        toggleImmersiveLock: noop,
        toggleSubtitleBlur: noop,
        cycleSubtitleObscure: noop,
        toggleSubtitleHide: noop,
        cycleSecondarySubtitleObscure: noop,
        toggleSecondarySubtitleHide: noop,
        toggleFavoriteSentence: noop,
        replayCurrentSubtitle: noop,
        replayPreviousSubtitle: noop,
        previousChapter: noop,
        nextChapter: noop,
        openSubtitleAlign: noop,
        subtitleDelayIncrease: noop,
        subtitleDelayDecrease: noop,
        alignSubtitleToPrev: noop,
        alignSubtitleToNext: noop,
        enterCaret: noop,
        escape: noop,
      );
    }

    test('videoHoldSpeed 的键盘绑定不进 activator 表（keyup 语义前提）', () {
      final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      final Map<ShortcutActivator, VoidCallback> activators =
          buildVideoPlayerShortcutsFromRegistry(registry, actions(<String>[]));
      for (final ShortcutActivator activator in activators.keys) {
        if (activator is! SingleActivator) continue;
        expect(
          activator.trigger,
          isNot(LogicalKeyboardKey.keyE),
          reason: '裸 E（videoHoldSpeed 默认键）装进 activator 表会在 keydown '
              '就消费事件，页面级按下/松开判定永远收不到',
        );
      }
    });

    test(
        '手柄通道仍活着：videoActionCallbacks 把 videoHoldSpeed 派发到 '
        'toggleHoldSpeed', () {
      final List<String> log = <String>[];
      final Map<ShortcutAction, VoidCallback> callbacks =
          videoActionCallbacks(actions(log));
      final VoidCallback? callback = callbacks[ShortcutAction.videoHoldSpeed];
      expect(callback, isNotNull);
      callback!();
      expect(log, <String>['toggleHoldSpeed']);
    });

    test('三平台默认表都给 videoHoldSpeed 配了键盘绑定（裸 E）', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.android,
      ]) {
        final ShortcutBindingSet? bindings = ShortcutDefaults.forPlatform(
            platform)[ShortcutAction.videoHoldSpeed];
        expect(bindings, isNotNull, reason: '$platform 缺默认绑定');
        expect(
          bindings!.keyboardBindings.any((InputBinding b) =>
              b.key == LogicalKeyboardKey.keyE && b.modifiers.isEmpty),
          isTrue,
          reason: '$platform 默认键应为裸 E',
        );
      }
    });
  });
}
