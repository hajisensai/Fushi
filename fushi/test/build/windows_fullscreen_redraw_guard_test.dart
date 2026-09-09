import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

// Native presentation needs device coverage; these guards pin the scheduling
// contract, including the equal-client-size path where WM_SIZE is insufficient.
void main() {
  test(
    'fullscreen presents after native restoration and before channel reply',
    () {
      final String source = maskComments(
        File('windows/runner/flutter_window.cpp').readAsStringSync(),
      );
      final int start = source.indexOf('call.method_name() == "setFullscreen"');
      final int end = source.indexOf(
        'call.method_name() == "isFullscreen"',
        start,
      );
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final String handler = source.substring(start, end);
      final int before = handler.indexOf(
        'const bool was_fullscreen = IsFullscreen();',
      );
      final int transition = handler.indexOf('SetFullscreen(enter);');
      final int redraw = handler.indexOf('flutter_controller_->ForceRedraw();');
      final int reply = handler.indexOf('result->Success();');
      expect(before, isNonNegative);
      expect(transition, greaterThan(before));
      expect(redraw, greaterThan(transition));
      expect(reply, greaterThan(redraw));
      expect(
        handler,
        contains(
          'if (flutter_controller_ && was_fullscreen != IsFullscreen())',
        ),
        reason:
            'Only a completed transition with a live controller schedules a frame.',
      );
      expect('ForceRedraw'.allMatches(handler), hasLength(1));
      expect(handler, isNot(contains('SetWindowPos(')));
      expect(handler, isNot(contains('SetTimer(')));
    },
  );
}
