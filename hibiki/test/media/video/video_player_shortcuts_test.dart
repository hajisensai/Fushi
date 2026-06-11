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
        toggleSubtitleList: () {},
        toggleImmersiveLock: () {},
        toggleCrossSubtitleRecording: () {},
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
        toggleSubtitleList: () => actions.add('subtitleList'),
        toggleImmersiveLock: () => actions.add('lock'),
        toggleCrossSubtitleRecording: () => actions.add('record'),
        escape: () => actions.add('escape'),
      ),
    );

    shortcuts[const SingleActivator(LogicalKeyboardKey.space)]!();
    // 普通 ←/→ = 时间 seek（TODO-090）。
    shortcuts[const SingleActivator(LogicalKeyboardKey.arrowLeft)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.arrowRight)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyA)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyD)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyC)]!();
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
      'seekBackward',
      'seekForward',
      'seekBackward',
      'seekForward',
      'shader',
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

  test('TODO-090: plain arrows = time seek, Ctrl+arrows = sentence seek', () {
    final List<String> actions = <String>[];
    final Map<ShortcutActivator, VoidCallback> shortcuts =
        buildVideoPlayerShortcuts(
      VideoPlayerShortcutActions(
        togglePlayPause: () {},
        play: () {},
        pause: () {},
        previousSubtitle: () => actions.add('previousSubtitle'),
        nextSubtitle: () => actions.add('nextSubtitle'),
        seekBackward: () => actions.add('seekBackward'),
        seekForward: () => actions.add('seekForward'),
        toggleShaderCompare: () {},
        volumeUp: () {},
        volumeDown: () {},
        toggleMute: () {},
        speedUp: () {},
        speedDown: () {},
        resetSpeed: () {},
        previousFrame: () {},
        nextFrame: () {},
        screenshot: () {},
        toggleFullscreen: () {},
        toggleSubtitleList: () {},
        toggleImmersiveLock: () {},
        toggleCrossSubtitleRecording: () {},
        escape: () {},
      ),
    );

    // 普通方向键 → 时间 seek（±秒）。
    shortcuts[const SingleActivator(LogicalKeyboardKey.arrowLeft)]!();
    shortcuts[const SingleActivator(LogicalKeyboardKey.arrowRight)]!();
    // Ctrl+方向键 → 句子跳转（上/下一句字幕）。
    shortcuts[
        const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true)]!();
    shortcuts[
        const SingleActivator(LogicalKeyboardKey.arrowRight, control: true)]!();

    expect(actions, <String>[
      'seekBackward',
      'seekForward',
      'previousSubtitle',
      'nextSubtitle',
    ]);
  });

  test('TODO-069: bare L opens subtitle jump list', () {
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
        volumeUp: () {},
        volumeDown: () {},
        toggleMute: () {},
        speedUp: () {},
        speedDown: () {},
        resetSpeed: () {},
        previousFrame: () {},
        nextFrame: () {},
        screenshot: () {},
        toggleFullscreen: () {},
        toggleSubtitleList: () => actions.add('subtitleList'),
        toggleImmersiveLock: () => actions.add('lock'),
        toggleCrossSubtitleRecording: () => actions.add('record'),
        escape: () {},
      ),
    );

    // 裸 L 键映射到字幕跳转列表 toggle。
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyL)]!();
    // Shift+L = 锁定 / 沉浸模式 toggle（TODO-101），与裸 L 区分、互不撞键。
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyL, shift: true)]!();
    // R = 跨字幕制卡区间录制 toggle（TODO-102），未撞既有键。
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyR)]!();
    expect(actions, <String>['subtitleList', 'lock', 'record']);
  });

  test('TODO-048b: mpv-default keys present and do not clobber Hibiki keys',
      () {
    final List<String> actions = <String>[];
    final Map<ShortcutActivator, VoidCallback> shortcuts =
        buildVideoPlayerShortcuts(
      VideoPlayerShortcutActions(
        togglePlayPause: () => actions.add('togglePlayPause'),
        play: () => actions.add('play'),
        pause: () => actions.add('pause'),
        previousSubtitle: () => actions.add('previousSubtitle'),
        nextSubtitle: () => actions.add('nextSubtitle'),
        seekBackward: () => actions.add('seekBackward'),
        seekForward: () => actions.add('seekForward'),
        toggleShaderCompare: () => actions.add('shader'),
        volumeUp: () => actions.add('volumeUp'),
        volumeDown: () => actions.add('volumeDown'),
        toggleMute: () => actions.add('toggleMute'),
        speedUp: () => actions.add('speedUp'),
        speedDown: () => actions.add('speedDown'),
        resetSpeed: () => actions.add('resetSpeed'),
        previousFrame: () => actions.add('previousFrame'),
        nextFrame: () => actions.add('nextFrame'),
        screenshot: () => actions.add('screenshot'),
        toggleFullscreen: () => actions.add('fullscreen'),
        toggleSubtitleList: () => actions.add('subtitleList'),
        toggleImmersiveLock: () => actions.add('lock'),
        toggleCrossSubtitleRecording: () => actions.add('record'),
        escape: () => actions.add('escape'),
      ),
    );

    // 期望表：每个动作 → 应当触发它的 mpv 默认键集合。逐键调度后断言只走对应动作，
    // 既覆盖「mpv 键照抄到位」又覆盖「没撞掉 Hibiki 既有键」（L/Shift+L/R/S/C/Ctrl 箭头）。
    final Map<String, List<ShortcutActivator>> expected =
        <String, List<ShortcutActivator>>{
      // mpv 默认键（TODO-048b 照抄）。
      'toggleMute': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.keyM),
      ],
      'volumeUp': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.digit0),
        const SingleActivator(LogicalKeyboardKey.arrowUp),
      ],
      'volumeDown': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.digit9),
        const SingleActivator(LogicalKeyboardKey.arrowDown),
      ],
      'speedDown': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.bracketLeft),
        const SingleActivator(LogicalKeyboardKey.minus),
      ],
      'speedUp': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.bracketRight),
        const SingleActivator(LogicalKeyboardKey.equal),
      ],
      'resetSpeed': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.backspace),
      ],
      'previousFrame': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.comma),
      ],
      'nextFrame': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.period),
      ],
      'fullscreen': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.keyF),
      ],
      // Hibiki 既有键（不得被 mpv 照抄破坏，Never break userspace）。
      'subtitleList': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.keyL),
      ],
      'lock': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.keyL, shift: true),
      ],
      'record': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.keyR),
      ],
      'screenshot': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.keyS),
      ],
      'shader': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.keyC),
      ],
      'previousSubtitle': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true),
      ],
      'nextSubtitle': <ShortcutActivator>[
        const SingleActivator(LogicalKeyboardKey.arrowRight, control: true),
      ],
    };

    for (final MapEntry<String, List<ShortcutActivator>> entry
        in expected.entries) {
      for (final ShortcutActivator activator in entry.value) {
        final VoidCallback? handler = shortcuts[activator];
        expect(handler, isNotNull,
            reason: '${entry.key} key $activator must stay bound');
        actions.clear();
        handler!();
        expect(actions, <String>[entry.key],
            reason: '$activator must dispatch only ${entry.key}');
      }
    }
  });
}
