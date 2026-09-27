import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/workspace_pubspec.dart';

/// BUG-235 source-scan guard: the vendored `media_kit_video` desktop seek bar
/// must keep its use-after-dispose guards.
///
/// Root cause: upstream `media_kit_video` 2.0.1's `MaterialDesktopSeekBarState`
/// calls `controller(context)` (which dereferences `State.context`) inside both
/// `onPointerUp()` and `onPointerMove()` with no `mounted` guard. Hibiki tears
/// down the controls subtree on fullscreen enter/exit and episode switch
/// (VideoControlsFocusGate), so releasing the seek bar drag right then lands on
/// a disposed State and crashes with
/// `Null check operator used on a null value`
/// (`material_desktop.dart`, MaterialDesktopSeekBarState.onPointerUp).
///
/// Fix: the package is vendored to `third_party/media_kit_video/` and both
/// handlers get `if (!mounted) return;` (matching the State's existing
/// `if (mounted)` setState guard). This test guards the *patch* — if a future
/// re-vendor of media_kit_video drops the guard, the crash returns and this
/// goes red. See `third_party/media_kit_video/PATCHES.md`.
///
/// BUG-566: the *mobile* controls (`material.dart`, `MaterialSeekBarState`)
/// have the exact same unguarded `controller(context)` dereference in their
/// `onPointerMove()`/`onPointerUp()`; BUG-235 only patched the desktop file.
/// The mobile handlers carry the same `if (!mounted) return;` guard, asserted
/// by the mirrored group below.
void main() {
  // Tests run with CWD = `fushi/`; vendored packages live at the workspace root.
  const String controlsPath =
      '../third_party/media_kit_video/lib/media_kit_video_controls/'
      'src/controls/material_desktop.dart';
  const String mobileControlsPath =
      '../third_party/media_kit_video/lib/media_kit_video_controls/'
      'src/controls/material.dart';

  test('vendored media_kit_video override is wired in pubspec', () {
    final WorkspacePubspec ws = WorkspacePubspec.load();
    expect(
      ws.isVendored('media_kit_video', 'third_party/media_kit_video'),
      isTrue,
      reason:
          'dependency_overrides must point media_kit_video at '
          '../third_party/media_kit_video (BUG-235). Without it the pub.dev '
          'package returns and the seek bar onPointerUp UAF crash comes back.',
    );
  });

  group('MaterialDesktopSeekBarState pointer handlers guard !mounted', () {
    late String source;

    setUp(() {
      source = File(controlsPath).readAsStringSync();
    });

    /// Returns the body of `void <name>(...) { ... }` by brace matching, so the
    /// assertion is about the handler itself and never matches an unrelated
    /// `if (!mounted) return;` elsewhere in the file.
    String bodyOf(String name) {
      final int sig = source.indexOf(RegExp('void\\s+$name\\s*\\('));
      expect(
        sig,
        isNonNegative,
        reason: 'expected a `void $name(` handler in $controlsPath',
      );
      final int open = source.indexOf('{', sig);
      expect(open, isNonNegative);
      int depth = 0;
      for (int i = open; i < source.length; i++) {
        final String c = source[i];
        if (c == '{') depth++;
        if (c == '}') {
          depth--;
          if (depth == 0) return source.substring(open, i + 1);
        }
      }
      fail('unbalanced braces in $name body of $controlsPath');
    }

    test('onPointerUp returns early when unmounted', () {
      expect(
        bodyOf(
          'onPointerUp',
        ).contains(RegExp(r'if\s*\(\s*!mounted\s*\)\s*return')),
        isTrue,
        reason:
            'onPointerUp dereferences controller(context); it must bail out '
            'with `if (!mounted) return;` before that, or the disposed-State '
            'crash (BUG-235) returns.',
      );
    });

    test('onPointerMove returns early when unmounted', () {
      expect(
        bodyOf(
          'onPointerMove',
        ).contains(RegExp(r'if\s*\(\s*!mounted\s*\)\s*return')),
        isTrue,
        reason:
            'onPointerMove also dereferences controller(context); it must '
            'bail out with `if (!mounted) return;` (BUG-235).',
      );
    });
  });

  group('MaterialSeekBarState (mobile) pointer handlers guard !mounted', () {
    late String source;

    setUp(() {
      source = File(mobileControlsPath).readAsStringSync();
    });

    /// Same brace-matching body extraction as the desktop group, applied to
    /// the mobile `material.dart`.
    String bodyOf(String name) {
      final int sig = source.indexOf(RegExp('void\\s+$name\\s*\\('));
      expect(
        sig,
        isNonNegative,
        reason: 'expected a `void $name(` handler in $mobileControlsPath',
      );
      final int open = source.indexOf('{', sig);
      expect(open, isNonNegative);
      int depth = 0;
      for (int i = open; i < source.length; i++) {
        final String c = source[i];
        if (c == '{') depth++;
        if (c == '}') {
          depth--;
          if (depth == 0) return source.substring(open, i + 1);
        }
      }
      fail('unbalanced braces in $name body of $mobileControlsPath');
    }

    test('onPointerUp returns early when unmounted', () {
      expect(
        bodyOf(
          'onPointerUp',
        ).contains(RegExp(r'if\s*\(\s*!mounted\s*\)\s*return')),
        isTrue,
        reason:
            'mobile onPointerUp dereferences controller(context); it must '
            'bail out with `if (!mounted) return;` before that, or the '
            'disposed-State crash (BUG-566, mobile mirror of BUG-235) returns.',
      );
    });

    test('onPointerMove returns early when unmounted', () {
      expect(
        bodyOf(
          'onPointerMove',
        ).contains(RegExp(r'if\s*\(\s*!mounted\s*\)\s*return')),
        isTrue,
        reason:
            'mobile onPointerMove also dereferences controller(context); '
            'it must bail out with `if (!mounted) return;` (BUG-566).',
      );
    });
  });

  group('TODO-669: seek-bar onHoverPosition patch survives re-vendor', () {
    late String source;

    setUp(() {
      source = File(controlsPath).readAsStringSync();
    });

    test('theme data class exposes onHoverPosition field', () {
      expect(
        source.contains(
          RegExp(r'void Function\(double\? fraction\)\?\s+onHoverPosition'),
        ),
        isTrue,
        reason:
            'MaterialDesktopVideoControlsThemeData must keep the '
            'onHoverPosition field (TODO-669); without it the host can no '
            'longer drive the progress-bar thumbnail preview.',
      );
    });

    test('copyWith carries onHoverPosition', () {
      expect(
        source.contains(
          RegExp(
            r'onHoverPosition:\s*onHoverPosition \?\? this\.onHoverPosition',
          ),
        ),
        isTrue,
        reason: 'copyWith must propagate onHoverPosition (TODO-669).',
      );
    });

    test('onHover/onEnter call onHoverPosition with the fraction', () {
      // Two call sites with a clamped percent (onHover + onEnter).
      final Iterable<Match> calls = RegExp(
        r'widget\.onHoverPosition\?\.call\(percent\.clamp',
      ).allMatches(source);
      expect(
        calls.length,
        greaterThanOrEqualTo(2),
        reason:
            'onHover and onEnter must surface the hover fraction to the '
            'host (TODO-669).',
      );
    });

    test('onExit clears the preview with null', () {
      expect(
        source.contains(RegExp(r'widget\.onHoverPosition\?\.call\(null\)')),
        isTrue,
        reason:
            'onExit must clear the host thumbnail preview with null '
            '(TODO-669).',
      );
    });

    test('seek bar widget forwards the theme callback', () {
      expect(
        source.contains(
          RegExp(r'onHoverPosition:\s*_theme\(context\)\s*\.onHoverPosition'),
        ),
        isTrue,
        reason:
            'The seek bar must be constructed with the theme '
            "onHoverPosition (TODO-669), or the host's callback never fires.",
      );
    });
  });

  group('TODO-669: host wiring (desktop only)', () {
    test('desktop controls theme injects onHoverPosition', () {
      final String themeSrc = File(
        'lib/src/pages/implementations/video_fushi/controls_theme.part.dart',
      ).readAsStringSync();
      final int desktopStart = themeSrc.indexOf('_desktopControlsTheme(');
      final int mobileStart = themeSrc.indexOf('_mobileControlsTheme(');
      expect(desktopStart, isNonNegative);
      expect(mobileStart, isNonNegative);
      final String desktopBody = themeSrc.substring(desktopStart, mobileStart);
      final String mobileBody = themeSrc.substring(mobileStart);
      expect(
        desktopBody.contains('onHoverPosition: _onSeekBarHover'),
        isTrue,
        reason:
            'desktop controls theme must wire onHoverPosition to '
            '_onSeekBarHover (TODO-669).',
      );
      expect(
        mobileBody.contains('onHoverPosition'),
        isFalse,
        reason:
            'mobile controls theme must NOT wire onHoverPosition — touch '
            'has no hover, mobile stays unchanged (TODO-669).',
      );
    });

    test('thumbnail preview overlay is mounted in the controls Stack', () {
      final String layoutSrc = File(
        'lib/src/pages/implementations/video_fushi/layout.part.dart',
      ).readAsStringSync();
      expect(
        layoutSrc.contains('_buildThumbnailPreviewOverlay(controller)'),
        isTrue,
        reason:
            'the thumbnail preview overlay must ride the controls Stack '
            '(TODO-669).',
      );
    });
  });

  // BUG-796 后续：进度条 seek 落点在途保护补丁（onSeekEnd(target)）必须在 re-vendor 后存活。
  // 缺任一环，进度条拖到无字幕段（尤其暂停）旧字幕不消失的 bug 复发。
  group('BUG-796 follow-up: seek-bar onSeekEnd(target) patch survives re-vendor', () {
    for (final String path in <String>[controlsPath, mobileControlsPath]) {
      test('$path theme data class exposes onSeekEnd(Duration) field', () {
        final String source = File(path).readAsStringSync();
        expect(
          source.contains(RegExp(r'void Function\(Duration\)\?\s+onSeekEnd')),
          isTrue,
          reason:
              'the theme data class must expose a '
              'void Function(Duration)? onSeekEnd field (BUG-796 follow-up); '
              'without it the host cannot learn the progress-bar seek target.',
        );
      });

      test('$path copyWith carries onSeekEnd', () {
        final String source = File(path).readAsStringSync();
        expect(
          source.contains(
            RegExp(r'onSeekEnd:\s*onSeekEnd \?\? this\.onSeekEnd'),
          ),
          isTrue,
          reason: 'copyWith must propagate onSeekEnd (BUG-796 follow-up).',
        );
      });

      test('$path seek bar forwards the committed target to onSeekEnd', () {
        final String source = File(path).readAsStringSync();
        // The seek-commit point passes the target Duration (duration * slider).
        expect(
          source.contains(
            RegExp(r'widget\.onSeekEnd\?\.call\(duration \* slider\)'),
          ),
          isTrue,
          reason:
              'the seek bar onPointerUp must call '
              'onSeekEnd(duration * slider) so the host gets the destination '
              '(BUG-796 follow-up).',
        );
        // The widget instantiation forwards the theme callback with the target.
        expect(
          source.contains(
            RegExp(r'_theme\(context\)\s*\.onSeekEnd\s*\?\.call\(target\)'),
          ),
          isTrue,
          reason:
              'the seek bar must be constructed forwarding '
              '_theme(context).onSeekEnd(target) (BUG-796 follow-up), or the '
              "host's callback never fires.",
        );
      });
    }

    test(
      'host wires onSeekEnd -> notifyExternalSeek in BOTH control themes',
      () {
        final String themeSrc = File(
          'lib/src/pages/implementations/video_fushi/controls_theme.part.dart',
        ).readAsStringSync();
        final int desktopStart = themeSrc.indexOf('_desktopControlsTheme(');
        final int mobileStart = themeSrc.indexOf('_mobileControlsTheme(');
        expect(desktopStart, isNonNegative);
        expect(mobileStart, isNonNegative);
        final String desktopBody = themeSrc.substring(
          desktopStart,
          mobileStart,
        );
        final String mobileBody = themeSrc.substring(mobileStart);
        final RegExp wiring = RegExp(
          r'onSeekEnd:\s*\(Duration target\)\s*=>\s*'
          r'controller\.notifyExternalSeek\(target\.inMilliseconds\)',
        );
        expect(
          wiring.hasMatch(desktopBody),
          isTrue,
          reason:
              'desktop controls theme must wire onSeekEnd to '
              'notifyExternalSeek (BUG-796 follow-up).',
        );
        expect(
          wiring.hasMatch(mobileBody),
          isTrue,
          reason:
              'mobile controls theme must wire onSeekEnd to '
              'notifyExternalSeek (BUG-796 follow-up) — progress-bar drag '
              'affects touch too.',
        );
      },
    );
  });

  group('BUG-2731: swipe / double-tap seeks report onSeekEnd(target)', () {
    test('horizontal swipe commit reports the target before seeking', () {
      final String source = File(mobileControlsPath).readAsStringSync();
      final int start = source.indexOf('void onHorizontalDragEnd()');
      expect(start, isNonNegative);
      final String body = source.substring(start, start + 1200);
      final int notify = body.indexOf(
        '_theme(context).onSeekEnd?.call(newPosition);',
      );
      // BUG-2731 follow-up: the seek itself goes through `_dispatchSeek`
      // (player.seek + onSeekDispatched), still right after onSeekEnd.
      final int seek = body.indexOf('_dispatchSeek(context, newPosition);');
      expect(
        notify,
        isNonNegative,
        reason:
            'swipe seek must tell the host its target (BUG-2731); '
            'otherwise a quality reload during the in-flight seek reopens '
            'the stream at the stale pre-swipe position.',
      );
      expect(seek, greaterThan(notify));
    });

    test('both double-tap seek indicators report the target', () {
      final String source = File(mobileControlsPath).readAsStringSync();
      final RegExp pair = RegExp(
        r'_theme\(context\)\.onSeekEnd\?\.call\(result\);\s*'
        r'_dispatchSeek\(context, result\);',
      );
      expect(
        pair.allMatches(source).length,
        2,
        reason:
            'backward and forward double-tap seeks must both report '
            'onSeekEnd(result) right before player.seek (BUG-2731).',
      );
    });

    test('video page reloads resume from resumePositionMs, and adaptive '
        'quality treats seeks as seeks', () {
      final String quality = File(
        'lib/src/pages/implementations/video_fushi/quality.part.dart',
      ).readAsStringSync();
      expect(
        quality.contains('positionMs ?? 0'),
        isFalse,
        reason:
            'reload-at-position sites must use resumePositionMs so an '
            'in-flight seek target wins over the lagging player position '
            '(BUG-2731).',
      );
      expect(
        quality.contains('_adaptiveQuality.noteSeek()'),
        isTrue,
        reason:
            'adaptive sampling must tell the controller about seeks, or '
            'seek re-buffering is read as a network stall (BUG-2731).',
      );
    });
  });

  group('BUG-2731 follow-up: relative seeks measure from the pending target', () {
    test('swipe and double-tap seeks never read the raw player position', () {
      final String source = File(mobileControlsPath).readAsStringSync();
      expect(
        source.contains('final Duration Function()? relativeSeekBasePosition;'),
        isTrue,
        reason: 'theme must expose the host base-position hook',
      );
      expect(
        source.contains(
          'relativeSeekBasePosition ?? this.relativeSeekBasePosition',
        ),
        isTrue,
        reason: 'copyWith must carry the hook over',
      );
      expect(
        source.contains(
          'Duration newPosition = _currentSwipeBase(context) + '
          'swipeDuration;',
        ),
        isTrue,
        reason:
            'swipe commit must be measured from the pending seek target, or '
            'a second swipe during a buffering seek erases the first one',
      );
      expect(
        RegExp(
          r'var result =\s*_relativeSeekBase\(context\) [-+] value;',
        ).allMatches(source).length,
        2,
        reason: 'both double-tap indicators must use the same base',
      );
      expect(
        source.contains('position: _currentSwipeBase(context),'),
        isTrue,
        reason: 'horizontalSeekResolver must see the same base position',
      );
      // Everything relative inside the main controls state goes through the
      // helper; the only raw reads left are the helper's own fallback and the
      // seek bars' absolute drag math.
      final int start = source.indexOf('void onHorizontalDragUpdate(');
      final int end = source.indexOf('bool _isInSegment(');
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      expect(
        source.substring(start, end).contains('player.state.position'),
        isFalse,
        reason: 'swipe handlers must not read the lagging raw position',
      );
    });

    test('one drag measures from one snapshotted base', () {
      final String source = File(mobileControlsPath).readAsStringSync();
      final int start = source.indexOf('void onHorizontalDragUpdate(');
      final String update = source.substring(
        start,
        source.indexOf('void onHorizontalDragEnd()', start),
      );
      expect(
        RegExp(
          r'if \(_dragInitialDelta == Offset\.zero\) \{\s*'
          r'_dragInitialDelta = details\.localPosition;\s*'
          r'_swipeBase = _relativeSeekBase\(context\);',
        ).hasMatch(update),
        isTrue,
        reason: 'the base is captured once, when the drag starts',
      );
      expect(update.contains('_relativeSeekBase(context).'), isFalse);
      final int end = source.indexOf('void onHorizontalDragEnd()');
      expect(
        source.substring(end, end + 1500).contains('_swipeBase = null;'),
        isTrue,
        reason: 'the snapshot must not leak into the next gesture',
      );
    });

    test('seek bar drag preview adds delta to the same base', () {
      final String source = File(mobileControlsPath).readAsStringSync();
      expect(
        source.contains('deltaBase: () => _currentSwipeBase(context),'),
        isTrue,
      );
      final int start = source.indexOf('class MaterialSeekBarState');
      final int listener = source.indexOf('void listener()', start);
      final String body = source.substring(
        listener,
        source.indexOf('void initState()', listener),
      );
      expect(body.contains('widget.deltaBase?.call()'), isTrue);
      expect(body.contains('position = base + delta;'), isTrue);
    });

    test('committed seeks hand their dispatch future to the host', () {
      for (final String path in <String>[mobileControlsPath, controlsPath]) {
        final String source = File(path).readAsStringSync();
        expect(
          source.contains(
            'final void Function(Future<void> seek)? onSeekDispatched;',
          ),
          isTrue,
          reason: '$path theme must expose onSeekDispatched',
        );
        expect(
          source.contains('onSeekDispatched ?? this.onSeekDispatched'),
          isTrue,
          reason: '$path copyWith must carry onSeekDispatched',
        );
        // Seek bar commit (pointer up).
        expect(
          RegExp(
            r'final Future<void> seek =\s*controller\(context\)\.player\.seek\('
            r'duration \* slider\);\s*'
            r'_theme\(context\)\.onSeekDispatched\?\.call\(seek\);',
          ).hasMatch(source),
          isTrue,
          reason: '$path seek bar commit must hand its future to the host',
        );
      }
      final String mobile = File(mobileControlsPath).readAsStringSync();
      final int helper = mobile.indexOf('void _dispatchSeek(');
      expect(helper, isNonNegative);
      final String helperBody = mobile.substring(helper, helper + 300);
      expect(
        RegExp(
          r'final Future<void> seek =\s*controller\(context\)\.player\.seek\('
          r'target\);\s*'
          r'_theme\(context\)\.onSeekDispatched\?\.call\(seek\);',
        ).hasMatch(helperBody),
        isTrue,
      );
      // swipe + two double-taps.
      expect(RegExp(r'_dispatchSeek\(context, ').allMatches(mobile).length, 3);
    });

    test('video page wires the base and the dispatch future', () {
      final String theme = File(
        'lib/src/pages/implementations/video_fushi/controls_theme.part.dart',
      ).readAsStringSync();
      expect(
        RegExp(
          r'relativeSeekBasePosition: \(\) =>\s*'
          r'Duration\(milliseconds: controller\.captureRelativeSeekBaseMs\(\) \?\? 0\)',
        ).hasMatch(theme),
        isTrue,
      );
      expect(
        'onSeekDispatched: controller.noteExternalSeekDispatched,'
            .allMatches(theme)
            .length,
        2,
        reason: 'both control themes must forward the dispatch future',
      );
      final int hud = theme.indexOf('Widget _buildSeekIndicator(');
      expect(
        theme
            .substring(hud, hud + 1200)
            .contains('controller.lastRelativeSeekBaseMs'),
        isTrue,
        reason: 'the HUD reads the same snapshotted base as the fork',
      );
    });

    test('controller: seekRelative and load register the in-flight target', () {
      final String controller = File(
        'lib/src/media/video/video_player_controller.dart',
      ).readAsStringSync();
      final int rel = controller.indexOf('Future<void> seekRelative(');
      expect(rel, isNonNegative);
      final String relBody = controller.substring(
        rel,
        controller.indexOf('static int clampSeekTargetMs(', rel),
      );
      expect(relBody.contains('final int? pos = resumePositionMs;'), isTrue);

      // Settle evidence only counts once the seek command is confirmed.
      final int check = controller.indexOf('void _checkSeekLanded(');
      final String checkBody = controller.substring(
        check,
        controller.indexOf('@visibleForTesting', check),
      );
      expect(
        checkBody.contains('if (!_pendingSeekDispatched) return;'),
        isTrue,
      );
      for (final String entry in <String>[
        'Future<void> seekMs(',
        'Future<void> _rawSeekMs(',
      ]) {
        final int at = controller.indexOf(entry);
        expect(at, isNonNegative);
        expect(
          controller
              .substring(at, at + 2500)
              .contains('await _awaitSeekDispatch('),
          isTrue,
          reason: '$entry must confirm dispatch after player.seek returns',
        );
      }

      // Reopen-at-position: the load's start point is the in-flight target
      // from the very beginning (before open), then re-armed with the
      // duration-checked resolvedStartMs before the restore seek.
      final int load = controller.indexOf('Future<void> load({');
      expect(load, isNonNegative);
      final int early = controller.indexOf(
        '_setPendingSeekLanding(preloadStartMs);',
        load,
      );
      final int armed = controller.indexOf(
        'applyMpvStartPosition(player, preloadStartMs)',
        load,
      );
      final int resolved = controller.indexOf(
        'final int restoreSeekToken = _setPendingSeekLanding(resolvedStartMs);',
        load,
      );
      final int restoreSeek = controller.indexOf(
        'await player.seek(Duration(milliseconds: resolvedStartMs));',
        load,
      );
      expect(early, isNonNegative);
      expect(armed, greaterThan(early));
      expect(resolved, greaterThan(armed));
      expect(restoreSeek, greaterThan(resolved));
      final int confirmed = controller.indexOf(
        '_confirmSeekDispatched(restoreSeekToken);',
        load,
      );
      expect(confirmed, greaterThan(restoreSeek));
      expect(
        controller.contains('_pendingSeekLandingMs = null;'),
        isFalse,
        reason:
            'clearing the target must go through _setPendingSeekLanding so '
            'the settle counters reset with it',
      );
    });
  });
}
