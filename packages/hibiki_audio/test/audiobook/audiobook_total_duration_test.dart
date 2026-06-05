import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

AudioCue _cue({
  required int fileIndex,
  required int startMs,
  required int endMs,
}) {
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = 0
    ..textFragmentId = '#s'
    ..text = 't'
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = fileIndex;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('totalDuration sums the max endMs of every audio file', () {
    final controller = AudiobookPlayerController();
    addTearDown(controller.dispose);

    // 文件0 末句 endMs=12000；文件1 末句 endMs=8000 → 全书=20000ms。
    controller.setAllBookCues(<AudioCue>[
      _cue(fileIndex: 0, startMs: 0, endMs: 5000),
      _cue(fileIndex: 0, startMs: 5000, endMs: 12000),
      _cue(fileIndex: 1, startMs: 0, endMs: 8000),
    ]);

    expect(controller.totalDuration, const Duration(milliseconds: 20000));
  });

  test('totalDuration falls back to zero when no cues and no player duration',
      () {
    final controller = AudiobookPlayerController();
    addTearDown(controller.dispose);

    expect(controller.totalDuration, Duration.zero);
  });

  test('globalPosition is zero before any file is loaded', () {
    final controller = AudiobookPlayerController();
    addTearDown(controller.dispose);

    controller.setAllBookCues(<AudioCue>[
      _cue(fileIndex: 0, startMs: 0, endMs: 5000),
    ]);

    expect(controller.globalPosition, Duration.zero);
  });
}
