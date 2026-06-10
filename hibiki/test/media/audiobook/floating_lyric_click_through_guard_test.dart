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

  setUpAll(() {
    cpp = File('windows/runner/floating_lyric_window.cpp').readAsStringSync();
    header = File('windows/runner/floating_lyric_window.h').readAsStringSync();
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
}
