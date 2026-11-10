import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/audiobook_companion_schema.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// Runs one audiobook panel command ([AudiobookCompanionActions]) on the top
/// reader's player. Each action reuses the player entry the top screen's own
/// control uses, so both screens behave the same:
///
/// - `seekLine` = the lyrics view's line tap (`onLyricsCueTap` →
///   [AudiobookPlayerController.playCueAndContinue]): play from that line,
///   also when paused.
/// - chapter skips go through [boundarySkip] (the page's
///   `_handleBoundarySkip`, which owns the chapter list).
///
/// Unknown actions and out-of-range arguments are ignored (a stale panel can
/// send an index from the previous chapter).
Future<void> runAudiobookCompanionCommand(
  AudiobookPlayerController audio,
  String action,
  Map<String, Object?> args, {
  required Future<void> Function(int delta) boundarySkip,
}) async {
  switch (action) {
    case AudiobookCompanionActions.playPause:
      await audio.togglePlayPause();
    case AudiobookCompanionActions.seekRelative:
      final int? seconds = args.intOrNull(AudiobookCompanionActions.seconds);
      if (seconds != null) await audio.seekRelative(seconds);
    case AudiobookCompanionActions.seekLine:
      final int? index = args.intOrNull(AudiobookCompanionActions.index);
      final List<AudioCue> cues = audio.chapterCuesSnapshot;
      if (index != null && index >= 0 && index < cues.length) {
        await audio.playCueAndContinue(cues[index]);
      }
    case AudiobookCompanionActions.previousChapter:
      await boundarySkip(-1);
    case AudiobookCompanionActions.nextChapter:
      await boundarySkip(1);
    case AudiobookCompanionActions.setSpeed:
      final double? speed = args.doubleOrNull(AudiobookCompanionActions.speed);
      if (speed != null && speed > 0) await audio.setSpeed(speed);
  }
}
