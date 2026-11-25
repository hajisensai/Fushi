import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/second_screen/companion/modules/audiobook_companion_commands.dart';
import 'package:fushi/src/second_screen/companion/modules/audiobook_companion_schema.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../helpers/fake_just_audio.dart';

/// Audiobook panel commands on the top reader's player. The panel transcript
/// says "tap to play": `seekLine` must play from the line like the lyrics
/// view's own line tap, also when paused (Thor S7f: it only seeked and stayed
/// paused).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AudiobookPlayerController> pausedPlayer() async {
    final AudiobookPlayerController c = await loadFakeAudiobookController();
    c.setChapterCues(<AudioCue>[_cue(0), _cue(5000), _cue(9000)]);
    c.getCurrentReaderSection = () => 3;
    c.onCrossChapter = (_) {};
    expect(c.isPlaying, isFalse, reason: 'precondition: paused');
    return c;
  }

  Future<void> run(
    AudiobookPlayerController c,
    String action, [
    Map<String, Object?> args = const <String, Object?>{},
    List<int>? skips,
  ]) => runAudiobookCompanionCommand(
    c,
    action,
    args,
    boundarySkip: (int delta) async => skips?.add(delta),
  );

  test('seekLine while paused plays from that line', () async {
    final AudiobookPlayerController c = await pausedPlayer();
    addTearDown(c.dispose);

    await run(c, AudiobookCompanionActions.seekLine, <String, Object?>{
      AudiobookCompanionActions.index: 1,
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(c.currentCue?.startMs, 5000);
    expect(c.isPlaying, isTrue);
  });

  test('seekLine out of range does nothing', () async {
    final AudiobookPlayerController c = await pausedPlayer();
    addTearDown(c.dispose);

    await run(c, AudiobookCompanionActions.seekLine, <String, Object?>{
      AudiobookCompanionActions.index: 3,
    });
    await run(c, AudiobookCompanionActions.seekLine, <String, Object?>{
      AudiobookCompanionActions.index: -1,
    });

    expect(c.isPlaying, isFalse);
  });

  test('chapter skips go to the page, speed to the player', () async {
    final AudiobookPlayerController c = await pausedPlayer();
    addTearDown(c.dispose);
    final List<int> skips = <int>[];

    await run(
      c,
      AudiobookCompanionActions.previousChapter,
      const <String, Object?>{},
      skips,
    );
    await run(
      c,
      AudiobookCompanionActions.nextChapter,
      const <String, Object?>{},
      skips,
    );
    await run(c, AudiobookCompanionActions.setSpeed, <String, Object?>{
      AudiobookCompanionActions.speed: 1.25,
    });

    expect(skips, <int>[-1, 1]);
    expect(c.speed, closeTo(1.25, 0.001));
  });
}

AudioCue _cue(int startMs) {
  return AudioCue()
    ..id = null
    ..bookKey = 'book'
    ..chapterHref = 'chapter-3'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = SubtitleRematchCodec.encodeHit(
      sectionIndex: 3,
      normCharStart: startMs ~/ 100,
      normCharEnd: startMs ~/ 100 + 5,
    )
    ..startMs = startMs
    ..endMs = startMs + 3000
    ..text = 'line $startMs'
    ..audioFileIndex = 0;
}
