import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// BUG-905 source-scan guard: the mobile [KitFfmpegBackend] must cancel **only
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

  /// Blank out comments (`///` doc, `//` line **and** `/* */` block) so the scan
  /// only sees executable code — the class doc legitimately mentions the old
  /// buggy `FFmpegKit.cancel()` form as a cautionary note.
  ///
  /// The previous local implementation dropped whole lines starting with `//`,
  /// which left two holes: a `/* FFmpegKit.cancel() */` block still tripped the
  /// cancel-all guard below (false red), and — worse — commenting a *required*
  /// call out with `/* ... */` kept the `isTrue` assertions green (false pass).
  /// [maskComments] is a lexer, so all three comment shapes are replaced with
  /// **equal-length** whitespace and offsets stay byte-aligned with the source.
  String codeOnly(String source) => maskComments(source);

  group('ffmpeg backend precise cancel guard (BUG-905)', () {
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
              'FFmpegKit.cancel(session.getSessionId()) — BUG-905.');
    });

    test('timeout paths cancel via the session id', () {
      // Comments are masked here too: an `isTrue` assertion on the raw source
      // stays green when the real call is commented out with `/* ... */`.
      final String source = codeOnly(libFile(path));

      expect(source, contains('FFmpegKit.cancel(sessionId)'),
          reason: 'Timeout handling must cancel the specific session id '
              'obtained from session.getSessionId() — BUG-905.');
      expect(source, contains('session.getSessionId()'),
          reason: 'The timed-out session id must come from '
              'session.getSessionId() so only that session is cancelled — '
              'BUG-905.');
    });

    test('sessions are started async so the id is known before timeout', () {
      // Same reasoning as above — a commented-out start call must not pass.
      final String source = codeOnly(libFile(path));

      // The synchronous executeWithArguments(...).timeout(...) form never yields
      // the session until completion, so on timeout there is no id to cancel
      // precisely. The async form returns the session immediately.
      expect(source, contains('FFmpegKit.executeWithArgumentsAsync('),
          reason: 'run() must start via executeWithArgumentsAsync so the '
              'session (and its id) is available inside the TimeoutException '
              'handler — BUG-905.');
      expect(source, contains('FFprobeKit.executeWithArgumentsAsync('),
          reason: 'runProbe() must start via executeWithArgumentsAsync so the '
              'session id is available on timeout — BUG-905.');
    });
  });
}
