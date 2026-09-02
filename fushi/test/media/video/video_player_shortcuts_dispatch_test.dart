import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/input_binding.dart'
    show ModifierKey, MouseBinding, ShortcutBindingSet;
import 'package:fushi/src/shortcuts/mouse_binding_dispatch.dart';
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
  /// 本组按**真实祖先结构**复现并锁死契约（方案 D 之后键盘只剩一个挂载点）：
  /// ```
  /// Focus(onKeyEvent → resolveVideoKeyboardShortcut)   ← 页面最外层（唯一挂载点）
  ///   └ Focus(videoNode, autofocus)                    ← 画面持焦（_videoFocusNode）
  ///       └ ElevatedButton                             ← bottomButtonBar 的按钮
  /// ```
  /// press-time 解析让「命中了绑定键但这次不消费」成为一等结论：焦点不在画面上时
  /// 判 [VideoKeyboardDispatch.ignore]，Enter 继续上浮到 Enter→ActivateIntent。
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
            '不能被页面主通道判成进光标（enterCaret）',
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

      expect(log, <String>['enterCaret'],
          reason: '画面持焦时 Enter 才算选词键，且不得误按到按钮');

      videoNode.dispose();
      buttonNode.dispose();
    });

    test('弹窗复用的 activator 表里不含任何裸 Enter 绑定', () {
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
          reason: '这张表现在只服务字幕对轴弹窗，但它仍是一个 CallbackShortcuts：'
              '匹配即无条件消费，一旦含裸 Enter，弹窗里每颗按钮的确认就没救了');
    });
  });

  /// BUG-2031：**鼠标与键盘的「返回上一级」必须落在同一个执行体上。**
  ///
  /// `shortcut_channel_wiring_guard_test` 里那条枚举守卫钉的是「每条鼠标阶梯都含
  /// universal」——那只保证鼠标**解析得到** `globalBack`。本条钉的是另一半：解析到
  /// 之后拿到的回调，与键盘 Esc 拿到的**是同一个对象**（视频页的逐级退出
  /// `_handleVideoEscapeAction`，经 `VideoPlayerShortcutActions.escape` 注入）。
  ///
  /// 两半都要：阶梯对了但 `videoActionCallbacks` 里没有 `globalBack` 这一项，鼠标那条
  /// 腿就是死项（解析得到、执行不了、还因为没执行而不认领，最后由 app 根的平
  /// `maybePop()` 兜底）——症状与阶梯修窄时**一模一样**，而枚举守卫看不见。
  test('GUARD: 鼠标 / 键盘解析出的 globalBack 落在同一个执行体（视频页逐级退出）', () {
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    // 只加鼠标键、保留 globalBack 的默认键盘绑定（整份覆盖会把 Esc 一起抹掉，
    // 那样键盘侧解析成 null，本条就变成测试环境自造的假红）。
    final ShortcutBindingSet current =
        registry.bindingsFor(ShortcutAction.globalBack);
    registry.updateBinding(
      ShortcutAction.globalBack,
      ShortcutBindingSet(
        keyboardBindings: current.keyboardBindings,
        gamepadBindings: current.gamepadBindings,
        wheelBindings: current.wheelBindings,
        mouseBindings: const <MouseBinding>[MouseBinding(3)],
      ),
    );

    // 鼠标腿：阶梯与 `_VideoFushiPageState.kVideoMouseLadder` 同形（该常量是私有
    // static，取不到；「它必须含 universal」由上面提到的枚举守卫另行钉死）。
    final ShortcutAction? byMouse = resolveMouseBindingAction(
      registry: registry,
      buttons: kBackMouseButton,
      ladder: const <ShortcutScope>[
        ShortcutScope.video,
        ShortcutScope.universal,
      ],
    );
    expect(byMouse, ShortcutAction.globalBack);

    // 键盘腿：同一个动作。
    final ShortcutAction? byKeyboard = registry.resolveKeyboard(
      LogicalKeyboardKey.escape,
      modifiers: const <ModifierKey>{},
      scope: ShortcutScope.universal,
    );
    expect(byKeyboard, ShortcutAction.globalBack);

    final List<String> log = <String>[];
    final VideoPlayerShortcutActions actions = _recordingVideoActions(log);
    final Map<ShortcutAction, VoidCallback> callbacks =
        videoActionCallbacks(actions);

    expect(
      callbacks[byMouse],
      isNotNull,
      reason: '解析得到却没有执行体 = 鼠标那条腿是死项，会静默降级成 app 根的平 pop',
    );
    expect(identical(callbacks[byMouse], callbacks[byKeyboard]), isTrue);
    expect(
      identical(callbacks[byMouse], actions.escape),
      isTrue,
      reason: 'globalBack 必须映到 escape（= 本页逐级退出），不是别的动作',
    );
    callbacks[byMouse]!();
    expect(log, <String>['escape']);
  });
}

/// 复现视频页真实祖先结构的 Enter 派发 harness（见上方 group 文档）。
///
/// 方案 D 之后页面只剩**一个**键盘挂载点，判据完全走生产纯函数
/// [resolveVideoKeyboardShortcut]，不在测试里另写一份。
Future<void> _pumpEnterCaretHarness(
  WidgetTester tester, {
  required FocusNode videoNode,
  required FocusNode buttonNode,
  required List<String> log,
}) async {
  final FushiShortcutRegistry registry = FushiShortcutRegistry()
    ..loadDefaults(TargetPlatform.windows);
  expect(
    registry.bindingsFor(ShortcutAction.videoEnterCaret).keyboardBindings,
    isNotEmpty,
    reason: '前置条件：videoEnterCaret 必须有键盘默认绑定，否则本组测了个寂寞',
  );

  await tester.pumpWidget(MaterialApp(
    home: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (FocusNode node, KeyEvent event) {
        final VideoKeyboardResolution resolution = resolveVideoKeyboardShortcut(
          registry,
          event,
          modifiers: currentKeyboardModifiers(HardwareKeyboard.instance),
          hasEditableFocus: false,
          hasVisiblePopup: false,
          videoSurfaceHoldsFocus: videoNode.hasPrimaryFocus,
          videoNavigablePanelOpen: false,
        );
        switch (resolution.dispatch) {
          case VideoKeyboardDispatch.swallowRepeat:
            return KeyEventResult.handled;
          case VideoKeyboardDispatch.ignore:
            return KeyEventResult.ignored;
          case VideoKeyboardDispatch.dismissPopup:
            log.add('dismissPopup');
            return KeyEventResult.handled;
          case VideoKeyboardDispatch.run:
            videoActionCallbacks(_recordingVideoActions(log))[resolution.action]
                ?.call();
            return KeyEventResult.handled;
        }
      },
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
  ));
  await tester.pump();
}
