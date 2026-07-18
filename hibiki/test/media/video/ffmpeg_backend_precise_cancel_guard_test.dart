import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-898 source-scan guard: the mobile [KitFfmpegBackend] must cancel **only
/// the timed-out session**, never every running ffmpeg-kit session.
///
/// Root cause: both timeout paths (`run` / `runProbe`) called the argument-less
/// `FFmpegKit.cancel()`, which cancels ALL sessions. The class doc excused it as
/// safe "because callers are serial" — a fragile assumption. As soon as two
/// sessions overlap (e.g. concurrent subtitle extraction + card mining), a
/// timeout on one wipes out the unrelated one, surfacing as intermittent loss
/// of embedded subtitles.
///
/// Fix: start asynchronously (`executeWithArgumentsAsync`) so the session is
/// available before the timeout fires, then cancel exactly that session via
/// `FFmpegKit.cancel(session.getSessionId())`. This guard fails if a bare
/// `FFmpegKit.cancel()` (cancel-all) is ever reintroduced into the backend.
void main() {
  String libFile(String relative) =>
      File(relative).readAsStringSync().replaceAll('\r\n', '\n');

  /// Drop comment-only lines (`///` doc / `//` line comments) so the scan only
  /// sees executable code — the class doc legitimately mentions the old buggy
  /// `FFmpegKit.cancel()` form as a cautionary note.
  String codeOnly(String source) => source.split('\n').where((String line) {
        final String t = line.trimLeft();
        return !t.startsWith('//');
      }).join('\n');

  group('ffmpeg backend precise cancel guard (BUG-898)', () {
    const String path = 'lib/src/media/video/ffmpeg_backend.dart';

    test('no argument-less FFmpegKit.cancel() (cancel-all) survives', () {
      final String source = codeOnly(libFile(path));

      // Match `FFmpegKit.cancel()` with nothing but whitespace inside the
      // parens — the cancel-all form. `FFmpegKit.cancel(sessionId)` is allowed.
      final RegExp cancelAll = RegExp(r'FFmpegKit\.cancel\(\s*\)');
      expect(cancelAll.hasMatch(source), isFalse,
          reason: 'FFmpegKit.cancel() with no sessionId cancels EVERY session '
              'and kills concurrent ffmpeg-kit tasks (dropped embedded '
              'subtitles). Cancel only the timed-out session with '
              'FFmpegKit.cancel(session.getSessionId()) — BUG-898.');
    });

    test('timeout paths cancel via the session id', () {
      final String source = libFile(path);

      expect(source, contains('FFmpegKit.cancel(sessionId)'),
          reason: 'Timeout handling must cancel the specific session id '
              'obtained from session.getSessionId() — BUG-898.');
      expect(source, contains('session.getSessionId()'),
          reason: 'The timed-out session id must come from '
              'session.getSessionId() so only that session is cancelled — '
              'BUG-898.');
    });

    test('sessions are started async so the id is known before timeout', () {
      final String source = libFile(path);

      // The synchronous executeWithArguments(...).timeout(...) form never yields
      // the session until completion, so on timeout there is no id to cancel
      // precisely. The async form returns the session immediately.
      expect(source, contains('FFmpegKit.executeWithArgumentsAsync('),
          reason: 'run() must start via executeWithArgumentsAsync so the '
              'session (and its id) is available inside the TimeoutException '
              'handler — BUG-898.');
      expect(source, contains('FFprobeKit.executeWithArgumentsAsync('),
          reason: 'runProbe() must start via executeWithArgumentsAsync so the '
              'session id is available on timeout — BUG-898.');
    });
  });
}
