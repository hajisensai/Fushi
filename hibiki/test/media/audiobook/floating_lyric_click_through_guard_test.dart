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
    test('strip is created mouse-transparent so other apps stay usable', () {
      // WS_EX_TRANSPARENT in the CreateWindowEx flags is what lets clicks fall
      // through to the apps underneath by default.
      expect(
        cpp.contains('WS_EX_TRANSPARENT'),
        isTrue,
        reason: 'The strip must be born click-through (WS_EX_TRANSPARENT).',
      );
      // It must still not steal keyboard focus.
      expect(cpp.contains('WS_EX_NOACTIVATE'), isTrue);
      // And it must float over every app, not just the Hibiki window.
      expect(cpp.contains('WS_EX_TOPMOST'), isTrue);
    });

    test('a cursor poll restores interactivity over the strip', () {
      // Transparent windows receive no WM_MOUSEMOVE, so hover must be detected
      // by polling the global cursor on a WM_TIMER.
      expect(cpp.contains('WM_TIMER'), isTrue);
      expect(cpp.contains('SetTimer('), isTrue);
      expect(cpp.contains('KillTimer('), isTrue);
      expect(cpp.contains('PollCursorInteractivity'), isTrue);
      expect(cpp.contains('GetCursorPos'), isTrue);
    });

    test('interactivity toggles WS_EX_TRANSPARENT instead of staying on', () {
      // ApplyInteractive clears the bit when the cursor is over the strip and
      // sets it again when the cursor leaves, so the desktop is usable the rest
      // of the time. Both directions must exist.
      expect(
          cpp.contains('&= ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT)'), isTrue);
      expect(
          cpp.contains('|= static_cast<LONG_PTR>(WS_EX_TRANSPARENT)'), isTrue);
      expect(cpp.contains('SetWindowLongPtr(hwnd_, GWL_EXSTYLE'), isTrue);
    });

    test('a drag never drops interactivity mid-move', () {
      // The poll must keep the strip interactive while dragging, otherwise
      // flipping transparent would abort the move.
      expect(cpp.contains('if (dragging_)'), isTrue);
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
