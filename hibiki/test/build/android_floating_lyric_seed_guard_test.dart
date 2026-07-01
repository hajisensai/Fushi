import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guards for BUG-400 / TODO-711 (also the "opened but nothing
/// appears" half of TODO-707).
///
/// Root cause: the Android floating-lyric overlay is started with
/// startForegroundService, which returns before FloatingLyricService.onCreate
/// runs. Dart pushes the current cue via updateText right after show(), so
/// FloatingLyricService.getInstance() is still null and the line is dropped —
/// the current line shows blank until the next cue arrives.
///
/// Fix (mirrors the existing style-persistence path): MainActivity persists the
/// text unconditionally on every updateText (and the playback state on
/// setPlaybackState) into the floating_lyric prefs, and the service replays both
/// in readInitialState so createContentView renders the current line on its
/// first frame. No delay/poll/native-ready round-trip — pure prefs replay,
/// structurally identical to how style is already replayed.
///
/// Native Java behaviour cannot run on the Dart host, so these guards pin the
/// wire contract at the source level. The Dart-side ordering (updateText after
/// show, carrying the current cue) is covered by a real behaviour test in
/// test/media/audiobook/floating_lyric_seed_test.dart.
void main() {
  const String androidRoot =
      '../hibiki/android/app/src/main/java/app/hibiki/reader';

  String read(String relative) =>
      File('$androidRoot/$relative').readAsStringSync();

  group('BUG-400 floating lyric current-line seeding', () {
    test('PreferenceKeys declares the current-text (and playing) replay keys',
        () {
      final String keys = read('constants/PreferenceKeys.java');
      expect(keys, contains('LYRIC_CURRENT_TEXT'),
          reason: 'a prefs key is needed to carry the current line across the '
              'startForegroundService gap');
      expect(keys, contains('LYRIC_PLAYING'),
          reason: 'playback state is replayed too so the play/pause icon is '
              'correct on the first frame');
    });

    test('MainActivity.updateText persists the line unconditionally', () {
      final String main = read('MainActivity.java');

      // Inspect only the updateText handler body.
      final int start = main.indexOf('case "updateText":');
      expect(start, isNonNegative, reason: 'updateText handler must exist');
      final int end = main.indexOf('case "updateStyle":', start);
      expect(end, greaterThan(start));
      final String body = main.substring(start, end);

      // TODO-708 P4 threaded the current-line interval (currentLineStart /
      // currentLineLength) through the persist call, so the exact arg list is
      // persistFloatingLyricText(text, curStart, curLen). Match the call by
      // prefix (tolerant of the extra interval args) while still pinning that
      // the *text* is the first thing persisted.
      final RegExp persistCall = RegExp(r'persistFloatingLyricText\(\s*text');
      expect(persistCall.hasMatch(body), isTrue,
          reason: 'the line must be persisted before checking the live '
              'instance, so a not-yet-created service still gets it via '
              'readInitialState');

      // The persist call must precede the live-instance guard, otherwise an
      // early null-instance return would skip it.
      final int persistAt = persistCall.firstMatch(body)!.start;
      final int guardAt = body.indexOf('FloatingLyricService.getInstance()');
      expect(persistAt, isNonNegative);
      expect(guardAt, greaterThan(persistAt),
          reason: 'persist must run regardless of whether the service is live '
              '(it runs before the svc != null branch)');

      expect(main, contains('private void persistFloatingLyricText('),
          reason: 'the persist helper must exist (mirrors '
              'persistFloatingLyricOptions)');
      expect(main, contains('PreferenceKeys.LYRIC_CURRENT_TEXT'),
          reason: 'the helper must write the current-text key');

      // TODO-708 P4: the persist helper must also thread the current-line
      // interval so the pre-onCreate replay renders the correct highlighted
      // line inside the multi-line context block, not just the raw text.
      expect(main, contains('PreferenceKeys.LYRIC_CURRENT_LINE_START'),
          reason: 'the helper must persist the current-line start offset '
              '(TODO-708 P4 context-block highlighting)');
      expect(main, contains('PreferenceKeys.LYRIC_CURRENT_LINE_LENGTH'),
          reason: 'the helper must persist the current-line length '
              '(TODO-708 P4 context-block highlighting)');
    });

    test('MainActivity.setPlaybackState persists the playing flag', () {
      final String main = read('MainActivity.java');
      expect(main, contains('persistFloatingLyricPlaying('),
          reason: 'playback state must be replayable on service startup');
      expect(main, contains('PreferenceKeys.LYRIC_PLAYING'));
    });

    test('FloatingLyricService.readInitialState replays the current line', () {
      final String service = read('FloatingLyricService.java');

      final int start = service.indexOf('private void readInitialState()');
      expect(start, isNonNegative, reason: 'readInitialState must exist');
      final int end = service.indexOf('private void bringAppToFront()', start);
      expect(end, greaterThan(start));
      final String body = service.substring(start, end);

      expect(body, contains('PreferenceKeys.LYRIC_CURRENT_TEXT'),
          reason: 'currentText must be replayed so createContentView shows the '
              'current line on the first frame instead of an empty string');
      expect(body, contains('currentText = prefs.getString('),
          reason: 'currentText field must be seeded from prefs');
      expect(body, contains('PreferenceKeys.LYRIC_PLAYING'),
          reason:
              'isPlaying must be replayed so the play/pause icon is correct '
              'on the first frame');
    });
  });
}
