import 'package:fushi_engine/media/video/video_subtitle_source.dart';

typedef BlurayDiscTrackSelection = ({
  String? audioId,
  String? subtitleSource,
  String? secondarySubtitleSource,
});

/// Reflects the playback owner rather than replaying stored library candidates.
/// The disc's native PGS/off choice replaces Fushi's previous selection only
/// after ownership has returned to the authored menu.
BlurayDiscTrackSelection resolveBlurayDiscTrackSelection({
  required bool discOwnsTracks,
  required String? nativeAudioId,
  required String? nativeSubtitleId,
  required int? nativeSubtitleStreamIndex,
  required String? currentSubtitleSource,
  required String? currentSecondarySubtitleSource,
}) => (
  audioId: nativeAudioId,
  subtitleSource: discOwnsTracks
      ? nativeSubtitleId == 'no'
            ? SubtitleSource.offSentinel
            : nativeSubtitleStreamIndex != null &&
                  nativeSubtitleStreamIndex >= 0
            ? '${SubtitleSource.embeddedPrefix}$nativeSubtitleStreamIndex'
            : null
      : currentSubtitleSource,
  secondarySubtitleSource: discOwnsTracks
      ? null
      : currentSecondarySubtitleSource,
);
