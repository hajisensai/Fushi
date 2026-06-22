import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_defaults.dart';

import '../../pages/video_hibiki_page_source_corpus.dart';

/// Source guard: video keyboard interaction + autoplay both need a real libmpv
/// player (the host has none; load()/Player construction throws), so structure
/// is pinned at the source level.
///
/// TODO-134: the video keyboard keys were migrated out of the hard-coded
/// Map<ShortcutActivator, VoidCallback> in video_player_shortcuts.dart into the
/// remappable registry. The DEFAULT bindings now live in shortcut_defaults.dart
/// (ShortcutDefaults.forPlatform); the action->callback WIRING is
/// videoActionCallbacks in video_player_shortcuts.dart; the callback BEHAVIOUR
/// still lives in video_hibiki_page.dart. Assertions that used to scan the
/// shortcuts source for LogicalKeyboardKey.xxx strings now assert the registry
/// defaults (using the real enum / InputBinding, stronger than string scans);
/// the page behaviour assertions are unchanged.
void main() {
  String read(String relPath) => File(relPath).readAsStringSync();

  String region(String src, String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  // Windows defaults are the canonical desktop video bindings (asbplayer/mpv).
  final Map<ShortcutAction, ShortcutBindingSet> videoDefaults =
      ShortcutDefaults.forPlatform(TargetPlatform.windows);

  // Whether [action] has a keyboard default matching [key] + [modifiers].
  bool defaultHasKey(
    ShortcutAction action,
    LogicalKeyboardKey key, {
    Set<ModifierKey> modifiers = const <ModifierKey>{},
  }) {
    final InputBinding target = InputBinding(key: key, modifiers: modifiers);
    return videoDefaults[action]!.keyboardBindings.contains(target);
  }

  group('video page Escape overrides media_kit default', () {
    final String page = readVideoHibikiSource();

    test('desktop controls theme overrides keyboardShortcuts', () {
      expect(
          page.contains('keyboardShortcuts: _videoKeyboardShortcuts('), isTrue,
          reason:
              'media_kit default Escape only exits fullscreen; must replace '
              'the whole table');
    });

    test('Escape exits page when windowed, exits fullscreen when fullscreen',
        () {
      // Escape default key now comes from the registry videoEscape default.
      expect(
          defaultHasKey(ShortcutAction.videoEscape, LogicalKeyboardKey.escape),
          isTrue,
          reason: 'videoEscape default must bind Escape');
      expect(page.contains('escape: () {'), isTrue,
          reason: 'page must wire the Escape action to real exit logic');
      expect(page.contains('isFullscreen('), isTrue,
          reason: 'fullscreen Escape exits fullscreen');
      expect(page.contains('_exitVideoFullscreen('), isTrue,
          reason: 'Escape fullscreen exit goes through the neutralised helper');
      expect(page.contains('_handleBackOrExit()'), isTrue,
          reason: 'windowed Escape exits the video page');
    });

    test('Escape cancels video control edit mode before video exit handling',
        () {
      final String escapeBody = region(page, 'escape: () {', '},\n      ),');
      final int editGate = escapeBody.indexOf('_videoControlEditMode.value');
      final int cancelEdit = escapeBody.indexOf(
        '_hideVideoControlEditOverlay(revealControls: false)',
      );
      final int fullscreenExit = escapeBody.indexOf('_exitVideoFullscreen(');
      final int backExit = escapeBody.indexOf('_handleBackOrExit()');

      expect(editGate, greaterThanOrEqualTo(0),
          reason: 'Escape must first test on-video control edit mode');
      expect(cancelEdit, greaterThan(editGate),
          reason: 'editing Escape should cancel the draft overlay');
      expect(fullscreenExit, greaterThan(cancelEdit),
          reason: 'fullscreen exit must only run after edit cancel gate');
      expect(backExit, greaterThan(cancelEdit),
          reason: 'page exit must only run after edit cancel gate');
    });

    test('exit confluence: PopScope and Escape share _handleBackOrExit', () {
      expect(page.contains('Future<void> _handleBackOrExit() async'), isTrue);
      expect('_handleBackOrExit()'.allMatches(page).length,
          greaterThanOrEqualTo(2),
          reason:
              'PopScope onPop and Escape both converge on _handleBackOrExit');
    });

    test('fullscreen helper uses the controls-subtree context', () {
      expect(page.contains('_videoControlsContext = controlsContext'), isTrue,
          reason: 'isFullscreen/toggle/exitFullscreen need a controls-subtree '
              'context');
    });
  });

  group('asbplayer-style playback shortcuts', () {
    final String page = readVideoHibikiSource();
    final String shortcuts =
        read('lib/src/media/video/video_player_shortcuts.dart');

    test('TODO-090: bare arrowLeft = time seek (seekBackward)', () {
      // Bare (unmodified) arrows are time seek, not sentence skip (asbplayer).
      // Default-key source of truth is now the registry: videoSeekBackward
      // binds bare arrowLeft.
      expect(
          defaultHasKey(
              ShortcutAction.videoSeekBackward, LogicalKeyboardKey.arrowLeft),
          isTrue,
          reason: 'bare arrowLeft must bind videoSeekBackward (TODO-090)');
      // Bare arrowLeft must NOT be sentence skip (that is the Ctrl combo).
      expect(
          defaultHasKey(ShortcutAction.videoPreviousSubtitle,
              LogicalKeyboardKey.arrowLeft),
          isFalse,
          reason: 'bare arrowLeft does not bind previousSubtitle');
      // action->callback wiring: videoSeekBackward -> actions.seekBackward.
      expect(
          shortcuts.contains(
              'ShortcutAction.videoSeekBackward: actions.seekBackward'),
          isTrue);
    });

    test('TODO-090: bare arrowRight = time seek (seekForward)', () {
      expect(
          defaultHasKey(
              ShortcutAction.videoSeekForward, LogicalKeyboardKey.arrowRight),
          isTrue,
          reason: 'bare arrowRight must bind videoSeekForward (TODO-090)');
      expect(
          defaultHasKey(
              ShortcutAction.videoNextSubtitle, LogicalKeyboardKey.arrowRight),
          isFalse,
          reason: 'bare arrowRight does not bind nextSubtitle');
      expect(
          shortcuts
              .contains('ShortcutAction.videoSeekForward: actions.seekForward'),
          isTrue);
    });

    test('TODO-090: Ctrl+Left/Right = prev/next subtitle (sentence seek)', () {
      // Ctrl+arrow = sentence skip; default keys provided by the registry
      // (videoPreviousSubtitle / videoNextSubtitle bind Ctrl+arrow); wiring in
      // videoActionCallbacks.
      expect(
          defaultHasKey(ShortcutAction.videoPreviousSubtitle,
              LogicalKeyboardKey.arrowLeft,
              modifiers: const <ModifierKey>{ModifierKey.ctrl}),
          isTrue,
          reason: 'Ctrl+Left must bind videoPreviousSubtitle (sentence skip)');
      expect(
          defaultHasKey(
              ShortcutAction.videoNextSubtitle, LogicalKeyboardKey.arrowRight,
              modifiers: const <ModifierKey>{ModifierKey.ctrl}),
          isTrue,
          reason: 'Ctrl+Right must bind videoNextSubtitle (sentence skip)');
      expect(
          shortcuts.contains(
              'ShortcutAction.videoPreviousSubtitle: actions.previousSubtitle'),
          isTrue);
      expect(
          shortcuts.contains(
              'ShortcutAction.videoNextSubtitle: actions.nextSubtitle'),
          isTrue);
    });

    test('TODO-085: Ctrl+Left far-prev degrades to seek back Xs', () {
      expect(page.contains('skipToPrevCueOrSeekBack('), isTrue,
          reason: 'Ctrl+Left goes through the degrade decision method');
      expect(page.contains('seekSeconds: _asbConfig.seekSeconds'), isTrue,
          reason: 'degrade threshold uses the configured seekSeconds');
      expect(page.contains('skipToNextCueOrSeekForward('), isTrue,
          reason:
              'next sentence uses the centralised decision method (TODO-073)');
      expect(page.contains('_asbSeekMs'), isTrue);
    });

    test('TODO-119: prev-sentence button degrades on no-subtitle segments', () {
      // No bare controller.skipToPrevCue() left in the page (BUG-200).
      expect(page.contains('controller.skipToPrevCue()'), isFalse,
          reason: 'no bare controller.skipToPrevCue() (no-op on gap, BUG-200)');
      expect(page.contains('skipToPrevCueOrSeekBack('), isTrue,
          reason: 'prev-sentence must go through skipToPrevCueOrSeekBack');

      final int helperAt =
          page.indexOf('Future<void> _skipCueAndPokeControls(');
      expect(helperAt, greaterThanOrEqualTo(0),
          reason: 'cannot find _skipCueAndPokeControls');
      final int helperEnd =
          page.indexOf('AudioCue? _currentCueForAction(', helperAt);
      expect(helperEnd, greaterThan(helperAt));
      final String body = page.substring(helperAt, helperEnd);
      expect(body.contains('skipToPrevCueOrSeekBack('), isTrue,
          reason: 'backward branch uses skipToPrevCueOrSeekBack (TODO-119)');
      expect(body.contains('skipToNextCueOrSeekForward('), isTrue,
          reason: 'forward branch uses skipToNextCueOrSeekForward (TODO-073)');
    });

    test('TODO-085 prevSeekDecisionFor exists and degrades on seekSeconds', () {
      final String controller =
          read('lib/src/media/video/video_player_controller.dart');
      expect(
          controller.contains('static PrevSeekDecision prevSeekDecisionFor('),
          isTrue);
      expect(controller.contains('final int thresholdMs = seekSeconds * 1000;'),
          isTrue,
          reason: 'threshold = seekSeconds');
      expect(controller.contains('if (gapMs > thresholdMs)'), isTrue,
          reason: 'only degrade when gap exceeds threshold');
    });

    test('A/D and Shift+F use one configured asbplayer seek value', () {
      expect(page.contains('int get _asbSeekMs =>'), isTrue);
      expect(page.contains('_asbConfig.seekSeconds * 1000'), isTrue);
      expect(page.contains('_asbFastSeekMs'), isFalse);
      expect(page.contains('fastSeekSeconds'), isFalse);
      // A/D time-seek default keys now come from the registry
      // (videoSeekBackward has KeyA; videoSeekForward has KeyD and Shift+KeyF).
      expect(
          defaultHasKey(
              ShortcutAction.videoSeekBackward, LogicalKeyboardKey.keyA),
          isTrue,
          reason: 'A = seek back');
      expect(page.contains('seekRelative(-_asbSeekMs)'), isTrue);
      expect(
          defaultHasKey(
              ShortcutAction.videoSeekForward, LogicalKeyboardKey.keyD),
          isTrue,
          reason: 'D = seek forward');
      expect(
          defaultHasKey(
              ShortcutAction.videoSeekForward, LogicalKeyboardKey.keyF,
              modifiers: const <ModifierKey>{ModifierKey.shift}),
          isTrue,
          reason: 'Shift+F = seek forward');
      expect(page.contains('seekRelative(_asbSeekMs)'), isTrue);
    });

    test('up/down remain volume keys and do not adjust subtitle offset', () {
      // Up/Down are always volume (registry: videoVolumeUp has arrowUp,
      // videoVolumeDown has arrowDown); never subtitle sync.
      expect(
          defaultHasKey(
              ShortcutAction.videoVolumeUp, LogicalKeyboardKey.arrowUp),
          isTrue);
      expect(
          defaultHasKey(
              ShortcutAction.videoVolumeDown, LogicalKeyboardKey.arrowDown),
          isTrue);
      expect(page.contains('_adjustVolume(_volumeStep)'), isTrue);
      expect(page.contains('_adjustVolume(-_volumeStep)'), isTrue);
      expect(shortcuts.contains('_adjustSubtitleOffset'), isFalse);

      final String volumeHud = region(
        page,
        'void _showVolumeOsd(double volume) {',
        'void _showBrightnessOsd(double brightness) {',
      );
      expect(volumeHud.contains('_showLevelHud('), isTrue,
          reason:
              'Keyboard volume keys must show the right-side page-level HUD.');
      expect(volumeHud.contains('_showOsd('), isFalse,
          reason:
              'Keyboard volume keys must not display volume in the top-left OSD.');
    });

    test('subtitle sync is a settings control, not an arrow-key binding', () {
      // TODO-060: subtitle sync moved to the settings panel row, committed via
      // onSetDelay -> _setDelayMs; no arrow-key increment binding.
      expect(page.contains('onSetDelay: _setDelayMs'), isTrue);
      expect(page.contains('_setDelayMs'), isTrue);
      expect(shortcuts.contains('_setDelayMs'), isFalse,
          reason: 'subtitle sync is not bound to arrows, only in settings');
      expect(page.contains('_adjustSubtitleOffset'), isFalse);
      expect(page.contains('_subtitleOffsetStepMs'), isFalse);
    });

    test('speed changes by configured asbplayer step', () {
      expect(page.contains('double get _speedStep => _asbConfig.speedStep'),
          isTrue);
      expect(page.contains('_adjustSpeed(_speedStep)'), isTrue);
      expect(page.contains('_adjustSpeed(-_speedStep)'), isTrue);
    });

    test('mpv-style common playback shortcuts are mapped where supported', () {
      // mpv-style default keys all live in the registry now (TODO-134). Assert
      // each registry default; assert the callback behaviour on the page side.
      expect(
          defaultHasKey(
              ShortcutAction.videoTogglePlayPause, LogicalKeyboardKey.keyP),
          isTrue,
          reason: 'mpv default: p toggles play/pause');
      expect(
          defaultHasKey(
              ShortcutAction.videoVolumeDown, LogicalKeyboardKey.digit9),
          isTrue,
          reason: 'mpv default: 9 decreases volume');
      expect(
          defaultHasKey(
              ShortcutAction.videoVolumeUp, LogicalKeyboardKey.digit0),
          isTrue,
          reason: 'mpv default: 0 increases volume');
      expect(
          defaultHasKey(
              ShortcutAction.videoToggleMute, LogicalKeyboardKey.keyM),
          isTrue,
          reason: 'mpv default: m toggles mute');
      expect(
          defaultHasKey(
              ShortcutAction.videoSpeedDown, LogicalKeyboardKey.bracketLeft),
          isTrue,
          reason: 'mpv default: [ decreases speed');
      expect(
          defaultHasKey(
              ShortcutAction.videoSpeedUp, LogicalKeyboardKey.bracketRight),
          isTrue,
          reason: 'mpv default: ] increases speed');
      expect(
          defaultHasKey(
              ShortcutAction.videoResetSpeed, LogicalKeyboardKey.backspace),
          isTrue,
          reason: 'mpv default: Backspace resets speed');
      expect(
          defaultHasKey(
              ShortcutAction.videoPreviousFrame, LogicalKeyboardKey.comma),
          isTrue,
          reason: 'mpv default: , steps one frame backward');
      expect(
          defaultHasKey(
              ShortcutAction.videoNextFrame, LogicalKeyboardKey.period),
          isTrue,
          reason: 'mpv default: . steps one frame forward');
      expect(
          defaultHasKey(
              ShortcutAction.videoScreenshot, LogicalKeyboardKey.keyS),
          isTrue,
          reason: 'mpv default: s takes a screenshot');
      expect(page.contains('_toggleMute()'), isTrue);
      expect(page.contains('_setSpeed(1.0)'), isTrue);
      expect(page.contains('frameStep(forward: false)'), isTrue);
      expect(page.contains('frameStep(forward: true)'), isTrue);
      expect(page.contains('_saveScreenshot()'), isTrue);
    });
  });

  group('lookup popup re-tap on same sentence: switch word, keep paused', () {
    final String page = readVideoHibikiSource();

    test('dismiss barrier uses onTapUp -> _onDismissBarrierTap (coord check)',
        () {
      expect(page.contains('onTapUp: (TapUpDetails d) =>'), isTrue);
      expect(page.contains('_onDismissBarrierTap(d.globalPosition)'), isTrue,
          reason: 'barrier needs a coordinate check, not a blind pop');
    });

    test('_onDismissBarrierTap: hit char -> lookup handler; else dismiss', () {
      final RegExpMatch? body = RegExp(
        r'void _onDismissBarrierTap\(Offset globalPos\) \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(page);
      expect(body, isNotNull, reason: 'cannot find _onDismissBarrierTap body');
      final String b = body!.group(1)!;
      final int hitAt = b.indexOf('_subtitleHitTester.hitTest(globalPos)');
      final int handlerAt = b.indexOf('_handleSubtitleLookupTap(');
      final int popAt = b.indexOf('_popNestedPopupAt(_topVisiblePopupIndex)');
      expect(hitAt, greaterThanOrEqualTo(0), reason: 'hit-test the char first');
      expect(handlerAt, greaterThan(hitAt),
          reason: 'on hit, switch lookup through the lookup gate handler');
      expect(popAt, greaterThan(handlerAt),
          reason: 'only dismiss + resume when no char is hit');
    });

    test('_handleSubtitleLookupTap gates lookup before _lookupAt', () {
      final RegExpMatch? body = RegExp(
        r'void _handleSubtitleLookupTap\(\n'
        r'    String sentence,\n'
        r'    int graphemeIndex,\n'
        r'    Rect charRect,\n'
        r'  \) \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(page);
      expect(body, isNotNull,
          reason: 'cannot find _handleSubtitleLookupTap body');
      final String b = body!.group(1)!;
      final int gate = b.indexOf('_immersiveAllowsLookup');
      final int lookupAt = b.indexOf('_lookupAt(');
      expect(gate, greaterThanOrEqualTo(0),
          reason: 'subtitle lookup must respect lookup-only immersive modes');
      expect(lookupAt, greaterThan(gate),
          reason: 'lookup handler must call _lookupAt only after the gate');
    });

    test('subtitle overlay binds _subtitleHitTester', () {
      expect(page.contains('hitTester: _subtitleHitTester'), isTrue);
    });
  });

  group('autoplay on enter page / episode switch', () {
    final String controller =
        read('lib/src/media/video/video_player_controller.dart');
    final String page = readVideoHibikiSource();

    test('load supports the autoPlay parameter', () {
      expect(controller.contains('bool autoPlay = false'), isTrue,
          reason: 'autoPlay defaults to false to preserve existing behaviour');
    });

    test('autoPlay calls player.play() after the restore seek', () {
      final int restore = controller.indexOf('await player.seek(');
      // BUG-344: autoPlay 守卫用 _isCurrentLoad 双判据（换集复用同一 player 时单判
      // `_player == player` 会误向被新 load 接管的 player 发 play()）。
      final int auto = controller
          .indexOf('if (autoPlay && _isCurrentLoad(player, loadToken))');
      final int play = controller.indexOf('await player.play();');
      expect(restore, greaterThanOrEqualTo(0));
      expect(auto, greaterThan(restore),
          reason: 'autoPlay must play after the restore seek');
      expect(play, greaterThan(auto));
    });

    test('page _loadVideo passes autoPlay: true', () {
      expect(page.contains('autoPlay: true'), isTrue,
          reason: 'enter page / episode switch should start playing');
    });
  });
}
