import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guard for the video subtitle-list panel wiring (TODO-278 / TODO-301 /
/// TODO-309, BUG-266 / BUG-267 / BUG-268). The page-level wiring lives in the
/// 5500-line [VideoHibikiPage] which cannot be driven under headless libmpv, so
/// these invariants are guarded by source scan (the widget behaviour itself is
/// covered by video_subtitle_jump_panel_test.dart / video_subtitle_overlay_test.dart):
///
/// 1. TODO-278: the jump panel is given an [onLookupCue] callback so list rows
///    can word-look-up through the same `_lookupAt` chain as the bottom overlay.
/// 2. TODO-301: both the jump panel and the bottom overlay receive
///    `isCueFavorited`, and the favorite cache is refreshed on video open (not
///    only when the list is first opened) so the bottom star marker is available.
/// 3. The favorite cache refresh is wired right after the warm-popup seed on the
///    successful open path.
void main() {
  final String src =
      File('lib/src/pages/implementations/video_hibiki_page.dart')
          .readAsStringSync();

  group('TODO-278/BUG-266 list-row word lookup wiring', () {
    test('VideoSubtitleJumpPanel is given onLookupCue', () {
      expect(
        src.contains('onLookupCue: _handleSubtitleListLookup'),
        isTrue,
        reason: 'jump panel must receive onLookupCue so list rows can look up '
            'words (revert -> rows cannot look up, BUG-266)',
      );
    });

    test('_handleSubtitleListLookup routes through the _lookupAt chain', () {
      // TODO-340: signature now carries the hit graphemeIndex (precise lookup,
      // not always 0); still routes through the shared _lookupAt chain.
      expect(
        RegExp(
          r'void _handleSubtitleListLookup\(\s*AudioCue cue,\s*'
          r'int graphemeIndex,\s*Rect charRect,?\s*\)'
          r'[\s\S]*?_lookupAt\(sentence, graphemeIndex, charRect\)',
        ).hasMatch(src),
        isTrue,
        reason:
            'list lookup must pass the hit graphemeIndex through the shared '
            '_lookupAt chain (TODO-340: precise per-char lookup, not index 0)',
      );
    });
  });

  group('TODO-301/BUG-267 favorite marker wiring', () {
    test('VideoSubtitleOverlay receives isCueFavorited', () {
      expect(
        RegExp(r'VideoSubtitleOverlay\([\s\S]*?isCueFavorited: _isCueFavorited')
            .hasMatch(src),
        isTrue,
        reason: 'bottom overlay must know if the current cue is favorited to '
            'draw the star marker (BUG-267)',
      );
    });

    test('VideoSubtitleJumpPanel receives isCueFavorited', () {
      expect(
        RegExp(r'VideoSubtitleJumpPanel\([\s\S]*?isCueFavorited: _isCueFavorited')
            .hasMatch(src),
        isTrue,
        reason: 'list rows must know favorite state to draw the row marker',
      );
    });

    test('favorite cache is refreshed on video open (after warm-popup seed)',
        () {
      expect(
        RegExp(r'_seedWarmPopup\(\);[\s\S]*?_refreshFavoritedCueCache\(\)')
            .hasMatch(src),
        isTrue,
        reason:
            'favorite cache must be filled on open so the bottom star shows '
            'before the subtitle list is ever opened (BUG-267)',
      );
    });
  });

  group('TODO-566 favorite star shows instantly when opening the list', () {
    test('opening the subtitle list does NOT re-query the favorite DB', () {
      // The fix removes the redundant async DB re-query when opening the panel.
      // The cache ([_favoritedVideoSentences]) is the single source of truth:
      // filled once on video open, then kept in sync by row / popup favorite
      // toggles. Re-querying it on panel open made the list render first with
      // hollow stars and only fill the filled stars after the async DB
      // round-trip -- the "star loads slowly" symptom (TODO-566).
      final RegExp openBranch = RegExp(
        r'_subtitleListVisible\.value = true;[\s\S]*?_refocusVideo\(\);',
      );
      final Match? match = openBranch.firstMatch(src);
      expect(match, isNotNull,
          reason: 'must find the open branch of _toggleSubtitleJumpList');
      expect(
        match!.group(0)!.contains('_refreshFavoritedCueCache'),
        isFalse,
        reason: 'opening the subtitle list must read the already-filled '
            'favorite cache (O(1) instant stars), not trigger another async '
            'DB round-trip that delays the filled stars (TODO-566)',
      );
    });
  });

  group('TODO-611 subtitle-list / favorite-panel lock wiring', () {
    test('the favorite-panel lock notifier exists and is disposed', () {
      // TODO-637: the subtitle-list lock (_subtitleListLocked) was removed with
      // its barrier; only the overlay favorite-list lock (_sidePanelLocked)
      // remains.
      expect(
        src.contains(
          'final ValueNotifier<bool> _sidePanelLocked = '
          'ValueNotifier<bool>(false);',
        ),
        isTrue,
        reason: 'side-panel (favorite list) lock state notifier must exist',
      );
      expect(src.contains('_sidePanelLocked.dispose();'), isTrue);
      // The subtitle-list lock is gone (TODO-634).
      expect(src.contains('_subtitleListLocked'), isFalse,
          reason: 'subtitle-list lock removed with its barrier (TODO-637/634)');
    });

    test('subtitle-list video area no longer has a tap-outside barrier', () {
      // TODO-637/636: the subtitle list is a non-blocking sidebar; the video
      // area carries no opaque "tap to close" barrier (it used to cover the
      // picture-subtitle lookup gesture). The locked-gated `onTap: locked ?
      // null :` form must be gone.
      expect(
        RegExp(r'onTap:\s*locked\s*\?\s*null\s*:').hasMatch(src),
        isFalse,
        reason: 'subtitle-list close barrier removed (non-blocking sidebar, '
            'TODO-637)',
      );
    });

    test('side-panel tap-outside barrier is gated by the favorite-list lock',
        () {
      // The overlay barrier onTap must no-op when the favorite list is locked.
      expect(
        src.contains(
          'onTap: (lockable && locked) ? null : _hideVideoSidePanel,',
        ),
        isTrue,
        reason:
            'favorite-list close barrier must no-op while locked (TODO-611)',
      );
    });

    test('only the favoriteSentences side panel is lockable', () {
      expect(
        src.contains(
          'panelState.kind == _VideoSidePanelKind.favoriteSentences',
        ),
        isTrue,
        reason:
            'lock toggle must only show for the favorite-sentences list panel',
      );
    });

    test('jump panel no longer receives a lock (X-close sidebar, TODO-637)',
        () {
      expect(
        RegExp(r'VideoSubtitleJumpPanel\([\s\S]*?onToggleLock:').hasMatch(src),
        isFalse,
        reason:
            'jump panel no longer wires a lock; closing is via the header X / '
            'Esc / subtitle button (TODO-637/634)',
      );
    });

    test('favorite-panel lock state is reset (not persisted) when it hides',
        () {
      // TODO-637: _resetSubtitleListLockWhenHidden was removed with the
      // subtitle-list lock; only the favorite-panel reset remains.
      expect(src.contains('_resetSidePanelLockWhenHidden'), isTrue);
      expect(src.contains('_resetSubtitleListLockWhenHidden'), isFalse);
    });
  });

  group('TODO-613 subtitle-list auto-scroll persistence wiring', () {
    test('jump panel reads the persisted auto-scroll value on open', () {
      expect(
        src.contains(
          'initialAutoScroll: appModel.videoSubtitleListAutoScroll,',
        ),
        isTrue,
        reason: 'auto-scroll initial state must come from Drift preferences '
            '(TODO-613)',
      );
    });

    test('toggling auto-scroll persists through appModel setter', () {
      expect(
        RegExp(r'onAutoScrollChanged:\s*\(bool value\) => unawaited\(\s*'
                r'appModel\.setVideoSubtitleListAutoScroll\(value\)')
            .hasMatch(src),
        isTrue,
        reason: 'auto-scroll toggle must be persisted via the appModel setter '
            '(TODO-613)',
      );
    });
  });
}
