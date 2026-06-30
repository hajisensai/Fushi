// BUG-483 / TODO-1034: importing an audiobook (m4b + same-name epub) where the
// epub has no cover and the cover must come from the m4b's embedded artwork.
// The embedded-cover extraction (`extractEmbeddedCover` -> ffmpeg probe on
// desktop) is async with hundreds-of-ms to multi-second latency. If the user
// taps "Import" before the probe returns, the import path read `_audioCoverPath`
// while it was still null and silently dropped the cover; restarting the app
// re-imported with the m4b already disk-cached so the probe returned instantly
// and the cover came back -- the tell-tale of an import-time race, not a render
// staleness bug.
//
// Fix: `_tryExtractAudioCover()` stores its in-flight Future in
// `_coverExtraction`, and `_applyBestCoverToEpub` awaits that Future (zero wait
// if already done) before reading `_audioCoverPath`.
//
// Test 1 (behavioral) models the exact ordering contract: an extraction Future
// that resolves the cover only after a delay; awaiting it before the read must
// observe the non-null cover. Reverting the await (reading before the Future
// completes) makes this red.
//
// Test 2 (source guard) pins that `_applyBestCoverToEpub` actually awaits
// `_coverExtraction` ahead of the `_audioCoverPath` branch in production code.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Mirror of the production ordering: the audio-cover path is only known after
  // an async extraction settles. Awaiting the stored extraction Future before
  // reading the path is what prevents the cover from being dropped (BUG-483).
  Future<String?> applyBestCover({
    required String? coverPath,
    required Future<void>? coverExtraction,
    required String? Function() readAudioCoverPath,
  }) async {
    if (coverExtraction != null) {
      await coverExtraction;
    }
    if (coverPath != null) return coverPath;
    return readAudioCoverPath();
  }

  test(
      'awaiting the in-flight extraction before reading the audio cover yields '
      'a non-null cover (BUG-483)', () async {
    String? audioCover;
    // Extraction settles the cover only after a delay, simulating the ffmpeg
    // probe that has not yet returned when the user taps Import.
    final Future<void> extraction = Future<void>.delayed(
      const Duration(milliseconds: 50),
      () => audioCover = '/tmp/audio_cover_123.jpg',
    );

    final String? applied = await applyBestCover(
      coverPath: null,
      coverExtraction: extraction,
      readAudioCoverPath: () => audioCover,
    );

    // Without awaiting `extraction`, `audioCover` would still be null here and
    // the cover would be dropped -- exactly the swallowed-cover race.
    expect(applied, '/tmp/audio_cover_123.jpg');
  });

  test('a settled extraction adds zero wait and still surfaces the cover',
      () async {
    String? audioCover = '/tmp/audio_cover_warm.jpg';
    final Future<void> extraction = Future<void>.value();

    final Stopwatch sw = Stopwatch()..start();
    final String? applied = await applyBestCover(
      coverPath: null,
      coverExtraction: extraction,
      readAudioCoverPath: () => audioCover,
    );
    sw.stop();

    expect(applied, '/tmp/audio_cover_warm.jpg');
    // Already-completed extraction must not introduce artificial latency.
    expect(sw.elapsedMilliseconds, lessThan(1000));
  });

  test(
      '_applyBestCoverToEpub awaits _coverExtraction before reading '
      '_audioCoverPath (source guard, BUG-483)', () {
    final String source =
        File('lib/src/media/audiobook/book_import_dialog.dart')
            .readAsStringSync();

    // The in-flight-extraction field must exist.
    expect(source, contains('Future<void>? _coverExtraction'),
        reason: 'the in-flight cover-extraction Future field must exist so '
            'fire-and-forget extraction can be awaited at import time.');

    final int start = source.indexOf('Future<void> _applyBestCoverToEpub(');
    expect(start, isNonNegative, reason: '_applyBestCoverToEpub must exist.');

    // Inspect only the body of _applyBestCoverToEpub.
    final int audioBranch = source.indexOf('_audioCoverPath != null', start);
    expect(audioBranch, greaterThan(start),
        reason: 'the _audioCoverPath fallback branch must exist.');

    final String head = source.substring(start, audioBranch);
    // Before the _audioCoverPath branch the method must both reference the
    // in-flight extraction Future and await it (production reads it into a
    // local `extraction` then awaits that local). Reverting the await makes
    // this red.
    expect(head, contains('_coverExtraction'),
        reason: '_applyBestCoverToEpub must read _coverExtraction before the '
            '_audioCoverPath branch.');
    expect(
        RegExp(r'await\s+extraction|await\s+_coverExtraction').hasMatch(head),
        isTrue,
        reason: '_applyBestCoverToEpub must `await` the in-flight extraction '
            'BEFORE the _audioCoverPath branch, otherwise a cover whose ffmpeg '
            'probe is still in flight at Import time is dropped (BUG-483).');
  });
}
