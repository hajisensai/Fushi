import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_player_shortcuts.dart';

void main() {
  test('volume and mute keys dispatch to real shortcut actions', () {
    final List<String> actions = <String>[];
    final Map<ShortcutActivator, VoidCallback> shortcuts =
        buildVideoPlayerShortcuts(
      VideoPlayerShortcutActions(
        togglePlayPause: () {},
        play: () {},
        pause: () {},
        previousSubtitle: () {},
        nextSubtitle: () {},
        seekBackward: () {},
        seekForward: () {},
        toggleShaderCompare: () {},
        volumeUp: () => actions.add('volumeUp'),
        volumeDown: () => actions.add('volumeDown'),
        toggleMute: () => actions.add('toggleMute'),
        speedUp: () {},
        speedDown: () {},
        resetSpeed: () {},
        previousFrame: () {},
        nextFrame: () {},
        screenshot: () {},
        toggleFullscreen: () {},
        escape: () {},
      ),
    );

    shortcuts[const SingleActivator(LogicalKeyboardKey.arrowUp)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.digit0)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.arrowDown)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.digit9)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyM)]!();

    expect(actions, <String>[
      'volumeUp',
      'volumeUp',
      'volumeDown',
      'volumeDown',
      'toggleMute',
    ]);
  });

  test('playback keys keep asbplayer and mpv-compatible aliases', () {
    final List<String> actions = <String>[];
    final Map<ShortcutActivator, VoidCallback> shortcuts =
        buildVideoPlayerShortcuts(
      VideoPlayerShortcutActions(
        togglePlayPause: () => actions.add('toggle'),
        play: () => actions.add('play'),
        pause: () => actions.add('pause'),
        previousSubtitle: () => actions.add('previousSubtitle'),
        nextSubtitle: () => actions.add('nextSubtitle'),
        seekBackward: () => actions.add('seekBackward'),
        seekForward: () => actions.add('seekForward'),
        toggleShaderCompare: () => actions.add('shader'),
        volumeUp: () {},
        volumeDown: () {},
        toggleMute: () {},
        speedUp: () => actions.add('speedUp'),
        speedDown: () => actions.add('speedDown'),
        resetSpeed: () => actions.add('resetSpeed'),
        previousFrame: () => actions.add('previousFrame'),
        nextFrame: () => actions.add('nextFrame'),
        screenshot: () => actions.add('screenshot'),
        toggleFullscreen: () => actions.add('fullscreen'),
        escape: () => actions.add('escape'),
      ),
    );

    shortcuts[const SingleActivator(LogicalKeyboardKey.space)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.arrowLeft)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.arrowRight)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyA)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyD)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.bracketLeft)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.bracketRight)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.backspace)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.comma)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.period)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyS)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyF)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.escape)]!();

    expect(actions, <String>[
      'toggle',
      'previousSubtitle',
      'nextSubtitle',
      'seekBackward',
      'seekForward',
      'speedDown',
      'speedUp',
      'resetSpeed',
      'previousFrame',
      'nextFrame',
      'screenshot',
      'fullscreen',
      'escape',
    ]);
  });
}
