import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/bluray_disc_track_selection.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';

void main() {
  test('disc PGS wins over stored Off and external subtitle candidates', () {
    for (final String previous in <String>[
      SubtitleSource.offSentinel,
      'old.srt',
    ]) {
      final BlurayDiscTrackSelection selection =
          resolveBlurayDiscTrackSelection(
            discOwnsTracks: true,
            nativeAudioId: '3',
            nativeSubtitleId: '7',
            nativeSubtitleStreamIndex: 1,
            currentSubtitleSource: previous,
            currentSecondarySubtitleSource: 'old-secondary.ass',
          );
      expect(selection.subtitleSource, '${SubtitleSource.embeddedPrefix}1');
      expect(selection.secondarySubtitleSource, isNull);
      expect(selection.audioId, '3');
    }
  });

  test(
    'Fushi explicit override lasts until the next real menu takes ownership',
    () {
      BlurayDiscTrackSelection resolve(bool disc) =>
          resolveBlurayDiscTrackSelection(
            discOwnsTracks: disc,
            nativeAudioId: '2',
            nativeSubtitleId: 'no',
            nativeSubtitleStreamIndex: null,
            currentSubtitleSource: 'manual.srt',
            currentSecondarySubtitleSource: 'manual-secondary.srt',
          );
      expect(resolve(false).subtitleSource, 'manual.srt');
      expect(resolve(false).secondarySubtitleSource, 'manual-secondary.srt');
      expect(resolve(true).subtitleSource, SubtitleSource.offSentinel);
      expect(resolve(true).secondarySubtitleSource, isNull);
    },
  );

  test(
    'unknown native track does not fabricate Off or a stored active track',
    () {
      final BlurayDiscTrackSelection selection =
          resolveBlurayDiscTrackSelection(
            discOwnsTracks: true,
            nativeAudioId: 'auto',
            nativeSubtitleId: 'auto',
            nativeSubtitleStreamIndex: null,
            currentSubtitleSource: 'old.srt',
            currentSecondarySubtitleSource: null,
          );
      expect(selection.subtitleSource, isNull);
      expect(selection.audioId, 'auto');
    },
  );
}
