import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_player_shortcuts.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

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
    previousFrame: () => record('previousFrame'),
    nextFrame: () => record('nextFrame'),
    screenshot: () => record('screenshot'),
    toggleFullscreen: () => record('toggleFullscreen'),
    toggleSubtitleList: () => record('toggleSubtitleList'),
    toggleImmersiveLock: () => record('toggleImmersiveLock'),
    toggleSubtitleBlur: () => record('toggleSubtitleBlur'),
    cycleSubtitleObscure: () => record('cycleSubtitleObscure'),
    toggleSubtitleHide: () => record('toggleSubtitleHide'),
    toggleFavoriteSentence: () => record('toggleFavoriteSentence'),
    replayCurrentSubtitle: () => record('replayCurrentSubtitle'),
    replayPreviousSubtitle: () => record('replayPreviousSubtitle'),
    previousChapter: () => record('previousChapter'),
    nextChapter: () => record('nextChapter'),
    escape: () => record('escape'),
  );
}

Future<void> _pumpShortcutHarness(
  WidgetTester tester,
  List<String> log,
) async {
  final HibikiShortcutRegistry registry = HibikiShortcutRegistry()
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
}
