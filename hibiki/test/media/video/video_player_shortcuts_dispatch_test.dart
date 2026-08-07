import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

VideoPlayerShortcutActions _recordingVideoActions(List<String> log) {
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

Future<void> _pumpShortcutHarness(
  WidgetTester tester,
  List<String> log,
) async {
  final FushiShortcutRegistry registry = FushiShortcutRegistry()
    ..loadDefaults(TargetPlatform.windows);
  await tester.pumpWidget(MaterialApp(
    home: CallbackShortcuts(
      bindings: buildVideoPlayerShortcutsFromRegistry(
        registry,
        _recordingVideoActions(log),
      ),
      child: const Focus(
        autofocus: true,
        child: SizedBox.expand(),
      ),
    ),
  ));
  await tester.pump();
}

Future<void> _sendWithModifiers(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
  bool shift = false,
}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  testWidgets('video shortcuts dispatch to favorite, replay, and list actions',
      (WidgetTester tester) async {
    final List<String> log = <String>[];
    await _pumpShortcutHarness(tester, log);

    await _sendWithModifiers(tester, LogicalKeyboardKey.keyD, control: true);
    await _sendWithModifiers(tester, LogicalKeyboardKey.keyR);
    await _sendWithModifiers(tester, LogicalKeyboardKey.keyR, shift: true);
    await _sendWithModifiers(tester, LogicalKeyboardKey.keyL);

    expect(log, <String>[
      'toggleFavoriteSentence',
      'replayCurrentSubtitle',
      'replayPreviousSubtitle',
      'toggleSubtitleList',
    ]);
  });

  /// PR#632 审查 B2：videoEnterCaret 默认绑**裸 Enter**，而 Enter 是本 app 唯一的
  /// 焦点确认键（裸空格已被 `global_navigation.dart` 中和成 DoNothingIntent）。
  ///
  /// 若把它装进 media_kit controls 的 `keyboardShortcuts`，那层 [CallbackShortcuts]
  /// **包住整个 controls 子树**（顶栏 / 底栏按钮全在里面）且 activator 一匹配就无
  /// 条件消费 —— 控制条上每个按钮的 Enter 确认被整片吃掉：Tab / 手柄把焦点落到
  /// 播放、全屏、±10s 上按 Enter，按钮不会被按下，而是弹出选词光标。
  ///
  /// 本组按**真实祖先结构**复现并锁死契约：
  /// ```
  /// Focus(onKeyEvent → decideVideoEnterCaretKey)        ← 页面最外层（视频页真实层）
  ///   └ CallbackShortcuts(buildVideoPlayerShortcutsFromRegistry(...))  ← media_kit
  ///       └ Focus(videoNode, autofocus)                 ← 画面持焦（_videoFocusNode）
  ///           └ ElevatedButton                          ← bottomButtonBar 的按钮
  /// ```
  group('videoEnterCaret 的 Enter 不吃掉控制条按钮的确认（PR#632 B2）', () {
    testWidgets('焦点在控制条按钮上：Enter 按下按钮，不进选词光标', (WidgetTester tester) async {
      final FocusNode videoNode = FocusNode(debugLabel: 'videoKeyboard');
      final FocusNode buttonNode = FocusNode(debugLabel: 'bottomBarButton');
      final List<String> log = <String>[];
      await _pumpEnterCaretHarness(
        tester,
        videoNode: videoNode,
        buttonNode: buttonNode,
        log: log,
      );

      buttonNode.requestFocus();
      await tester.pump();
      expect(buttonNode.hasPrimaryFocus, isTrue, reason: '前置条件：焦点确实落在控制条按钮上');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(
        log,
        <String>['buttonPressed'],
        reason: 'Enter 是全局焦点确认键：焦点在控制条按钮上时必须触发 onPressed，'
            '既不能被 media_kit 的 keyboardShortcuts 整表吃掉（enterCaret），'
            '也不能被页面层判成进光标（caretEntered）',
      );

      videoNode.dispose();
      buttonNode.dispose();
    });

    testWidgets('焦点在视频画面上：Enter 进选词光标（功能本身没被删掉）', (WidgetTester tester) async {
      final FocusNode videoNode = FocusNode(debugLabel: 'videoKeyboard');
      final FocusNode buttonNode = FocusNode(debugLabel: 'bottomBarButton');
      final List<String> log = <String>[];
      await _pumpEnterCaretHarness(
        tester,
        videoNode: videoNode,
        buttonNode: buttonNode,
        log: log,
      );

      videoNode.requestFocus();
      await tester.pump();
      expect(videoNode.hasPrimaryFocus, isTrue, reason: '前置条件：焦点确实落在视频画面上');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(log, <String>['caretEntered'],
          reason: '画面持焦时 Enter 才算选词键，且不得误按到按钮');

      videoNode.dispose();
      buttonNode.dispose();
    });

    test('注册表 activator 整表里不含任何裸 Enter 绑定', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      final Map<ShortcutActivator, VoidCallback> map =
          buildVideoPlayerShortcutsFromRegistry(
        registry,
        _recordingVideoActions(<String>[]),
      );
      final bool hasBareEnter = map.keys.whereType<SingleActivator>().any(
            (SingleActivator a) =>
                a.trigger == LogicalKeyboardKey.enter &&
                !a.control &&
                !a.alt &&
                !a.meta &&
                !a.shift,
          );
      expect(hasBareEnter, isFalse,
          reason: '这张表装进的 CallbackShortcuts 包住整个 controls 子树、匹配即'
              '无条件消费；一旦含裸 Enter，控制条按钮的确认就没救了');
    });
  });
}

/// 复现视频页真实祖先结构的 Enter 派发 harness（见上方 group 文档）。
/// 页面层的判据完全走生产纯函数 [decideVideoEnterCaretKey]，不在测试里另写一份。
Future<void> _pumpEnterCaretHarness(
  WidgetTester tester, {
  required FocusNode videoNode,
  required FocusNode buttonNode,
  required List<String> log,
}) async {
  final FushiShortcutRegistry registry = FushiShortcutRegistry()
    ..loadDefaults(TargetPlatform.windows);
  final List<ShortcutActivator> enterActivators = registry
      .bindingsFor(ShortcutAction.videoEnterCaret)
      .keyboardBindings
      .map((InputBinding b) => b.toActivator(includeRepeats: false))
      .toList();
  expect(enterActivators, isNotEmpty,
      reason: '前置条件：videoEnterCaret 必须有键盘默认绑定，否则本组测了个寂寞');
  bool caretActive = false;

  await tester.pumpWidget(MaterialApp(
    home: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (FocusNode node, KeyEvent event) {
        switch (decideVideoEnterCaretKey(
          event: event,
          enterActivators: enterActivators,
          keyboardState: HardwareKeyboard.instance,
          caretActive: caretActive,
          hasEditableFocus: false,
          hasVisiblePopup: false,
          videoSurfaceHoldsFocus: videoNode.hasPrimaryFocus,
        )) {
          case VideoEnterCaretKeyDecision.notTrigger:
          case VideoEnterCaretKeyDecision.passThrough:
            return KeyEventResult.ignored;
          case VideoEnterCaretKeyDecision.dismissPopup:
            log.add('dismissPopup');
            return KeyEventResult.handled;
          case VideoEnterCaretKeyDecision.enterCaret:
            caretActive = true;
            log.add('caretEntered');
            return KeyEventResult.handled;
        }
      },
      child: CallbackShortcuts(
        bindings: buildVideoPlayerShortcutsFromRegistry(
          registry,
          _recordingVideoActions(log),
        ),
        child: Focus(
          focusNode: videoNode,
          autofocus: true,
          child: Center(
            child: ElevatedButton(
              focusNode: buttonNode,
              onPressed: () => log.add('buttonPressed'),
              child: const Text('play'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}
