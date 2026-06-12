import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guards for the desktop floating-subtitle strip's click-through
/// contract (TODO-038). The native Win32 window cannot run on the host, so
/// these guards pin the load-bearing wiring that makes the strip both
/// non-blocking to other apps AND tappable for word lookup. A refactor that
/// silently drops any of these would re-introduce the rejected "steals focus /
/// blocks other apps" behaviour.
void main() {
  late String cpp;
  late String header;
  late String flutterWindow;

  setUpAll(() {
    cpp = File('windows/runner/floating_lyric_window.cpp').readAsStringSync();
    header = File('windows/runner/floating_lyric_window.h').readAsStringSync();
    flutterWindow =
        File('windows/runner/flutter_window.cpp').readAsStringSync();
  });

  group('desktop floating-lyric click-through guards', () {
    test(
        'strip is created mouse-interactive so first clicks cannot fall through',
        () {
      final int createWindow = cpp.indexOf('CreateWindowExW(');
      final int className = cpp.indexOf('kWindowClassName', createWindow);
      final String createFlags = cpp.substring(createWindow, className);

      // The native strip must be interactive from the first hit-test. Keeping
      // WS_EX_TRANSPARENT in the creation flags reopens the race where a fast
      // first click reaches the app underneath before a timer clears the bit.
      expect(
        createFlags.contains('WS_EX_TRANSPARENT'),
        isFalse,
        reason: 'The strip must not be born mouse-transparent.',
      );
      // It must still not steal keyboard focus.
      expect(createFlags.contains('WS_EX_NOACTIVATE'), isTrue);
      // And it must float over every app, not just the Hibiki window.
      expect(createFlags.contains('WS_EX_TOPMOST'), isTrue);
    });

    test('interactivity is not driven by a hover timer', () {
      // A timer-driven transparent/interactive flip is inherently racy: a fast
      // mouse-enter + click can arrive while WS_EX_TRANSPARENT is still set.
      expect(cpp.contains('PollCursorInteractivity'), isFalse);
      expect(cpp.contains('ApplyInteractive'), isFalse);
      expect(cpp.contains('SetTimer('), isFalse);
      expect(cpp.contains('KillTimer('), isFalse);
      expect(cpp.contains('&= ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT)'),
          isFalse);
      expect(
          cpp.contains('|= static_cast<LONG_PTR>(WS_EX_TRANSPARENT)'), isFalse);
    });

    test('word lookup is preserved — taps still report a char index', () {
      // The whole point of the redo: lookup must survive the click-through
      // rework. A tap is hit-tested to a character and sent up as on_lookup_.
      expect(cpp.contains('CharIndexAt'), isTrue);
      expect(cpp.contains('on_lookup_'), isTrue);
      expect(cpp.contains('click_lookup_enabled_'), isTrue);
      expect(header.contains('SetClickLookupEnabled'), isTrue);
    });

    test('control buttons are still hit-tested and reported', () {
      expect(cpp.contains('ControlActionAt'), isTrue);
      expect(cpp.contains('on_control_'), isTrue);
    });

    test('padlock glyphs are drawn as full UTF-16 strings', () {
      expect(cpp.contains('GlyphLength'), isTrue,
          reason: 'Emoji glyphs need their full UTF-16 code-unit length.');
      expect(cpp.contains('DrawTextW(\n          glyph, GlyphLength(glyph),'),
          isTrue,
          reason: 'DrawTextW must not truncate surrogate-pair glyphs.');
      expect(cpp.contains('DrawTextW(\n          glyph, 1,'), isFalse,
          reason: 'Length 1 truncates U+1F512/U+1F513 padlock glyphs.');
    });
  });

  // ── TODO-136: desktop strip lock button + resize + draggable-from-text ──
  group('desktop floating-lyric lock / resize / drag-fix guards', () {
    test('a fifth "lock" control slot exists and is hit-tested', () {
      // The control row grew from 4 to 5 slots; both the renderer and the
      // hit-tester must agree on the count, and the lock slot must be wired.
      expect(cpp.contains('kControlSlotCount'), isTrue,
          reason: 'Slot count must be a single source of truth.');
      expect(cpp.contains('return "lock";'), isTrue,
          reason: 'ControlActionAt must report the lock button.');
      // The lock glyph (padlock) must be drawn, tinted by the locked state.
      expect(
        cpp.contains(r'\U0001F512') && cpp.contains(r'\U0001F513'),
        isTrue,
        reason: 'Locked / unlocked padlock glyphs must both be drawn.',
      );
    });

    test('the lock is a real state that gates dragging (not a no-op)', () {
      // Native side owns a locked_ flag and toggles it; a locked strip must
      // refuse to start a drag (the press->drag promotion is gated on !locked_).
      expect(cpp.contains('locked_'), isTrue);
      expect(header.contains('void SetLocked(bool locked);'), isTrue);
      expect(header.contains('bool IsLocked()'), isTrue);
      expect(cpp.contains('if (pressed_ && !locked_)'), isTrue,
          reason: 'Drag promotion must be suppressed while locked.');
      // The lock button toggle reports back to Dart via the lock callback.
      expect(cpp.contains('on_lock_'), isTrue);
      expect(header.contains('SetLockCallback'), isTrue);
    });

    test('flutter_window wires setLocked to the real native lock', () {
      // The old desktop strip stubbed setLocked as a no-op; it must now drive
      // the window and surface user toggles back over "lockChanged".
      expect(
          flutterWindow.contains('floating_lyric_window_->SetLocked('), isTrue);
      expect(flutterWindow.contains('"lockChanged"'), isTrue);
      // And it must NOT still carry the old no-op excuse comment.
      expect(flutterWindow.contains('desktop strip has no lock affordance'),
          isFalse,
          reason: 'The lock no-op was removed; setLocked is now real.');
    });

    test('the bar is draggable from the text, not only blank margins', () {
      // Root-cause fix for "can\'t drag": a press no longer immediately fires a
      // lookup-or-drag decision. A still press is a lookup on button-up; a
      // moving press is promoted to a drag past a threshold.
      expect(cpp.contains('press_was_text_'), isTrue);
      expect(cpp.contains('kDragThresholdDip'), isTrue);
      expect(cpp.contains('dragging_ = true;'), isTrue);
    });

    test('the bottom-right grip resizes via the system NC hit-test', () {
      // WM_NCHITTEST hands the corner to the system resize loop (QQ-Music
      // style); WM_SIZE re-syncs the logical strip size so text + controls
      // follow, clamped by WM_GETMINMAXINFO.
      expect(cpp.contains('case WM_NCHITTEST'), isTrue);
      expect(cpp.contains('HTBOTTOMRIGHT'), isTrue);
      expect(cpp.contains('ResizeGripContains'), isTrue);
      expect(cpp.contains('case WM_SIZE'), isTrue);
      expect(cpp.contains('SyncStripSizeFromWindow'), isTrue);
      expect(cpp.contains('case WM_GETMINMAXINFO'), isTrue);
      // The strip size must be a mutable member, not a fixed constant.
      expect(header.contains('strip_width_dip_'), isTrue);
      expect(header.contains('strip_height_dip_'), isTrue);
    });
  });
}
