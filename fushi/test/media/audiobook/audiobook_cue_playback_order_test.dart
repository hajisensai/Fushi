import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 章节 cue 必须按播放顺序（文件下标, 文件内起点）排列。
///
/// 只按 startMs 排时，多文件书各文件的 cue 交错（startMs 是文件内相对值），上一句 /
/// 下一句跳到别的文件；TTS 朗读每句一个文件、startMs 全为 0，只按它排顺序完全随机。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.ryanheise.audio_session'),
          (_) async => null,
        );
  });

  AudioCue cue(int file, int startMs, int endMs) => AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = file
    ..textFragmentId = 'cue-$file-$startMs'
    ..text = 'cue $file'
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = file;

  test('one cue per file with equal startMs keeps file order', () {
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);
    final List<AudioCue> cues = <AudioCue>[
      for (final int f in <int>[5, 2, 9, 0, 7, 1, 3, 8, 4, 6]) cue(f, 0, 1000),
    ];
    c.setChapterCues(cues);
    expect(
      c.chapterCuesSnapshot.map((AudioCue x) => x.audioFileIndex),
      List<int>.generate(10, (int i) => i),
    );
  });

  test('multi-file cues are ordered by file before start time', () {
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);
    c.setChapterCues(<AudioCue>[
      cue(1, 0, 500),
      cue(0, 9000, 9500),
      cue(0, 0, 500),
      cue(1, 4000, 4500),
    ]);
    expect(
      c.chapterCuesSnapshot.map(
        (AudioCue x) => '${x.audioFileIndex}:${x.startMs}',
      ),
      <String>['0:0', '0:9000', '1:0', '1:4000'],
    );
  });

  test('refreshCueTimings rebuilds file durations from mutated cues', () {
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);
    final List<AudioCue> cues = <AudioCue>[cue(0, 0, 1000), cue(1, 0, 1000)];
    c.setAllBookCues(cues);
    expect(c.fileDurationsMs, <int>[1000, 1000]);
    int notified = 0;
    c.addListener(() => notified++);
    cues[1].endMs = 2500;
    c.refreshCueTimings();
    expect(c.fileDurationsMs, <int>[1000, 2500]);
    expect(notified, 1);
    expect(c.globalMsOfCue(cues[1]), 1000);
  });

  group('multi-file position fallback (no current cue) stays inside the '
      'current file', () {
    // 播放顺序：0:0(0) 0:1000(1) 1:0(2) 1:1000(3) 2:0(4)。整表 startMs 是
    // 0,1000,0,1000,0——不单调，对整表二分的结果无意义。
    final List<AudioCue> cues = <AudioCue>[
      cue(0, 0, 500),
      cue(0, 1000, 1500),
      cue(1, 0, 500),
      cue(1, 1000, 1500),
      cue(2, 0, 500),
    ];

    test('next: inside a cue of file 1 goes to the following cue', () {
      expect(
        AudiobookPlayerController.nextCueIndexForTesting(
          cues: cues,
          currentCueIndex: -1,
          audioFileIndex: 1,
          positionMs: 1200,
        ),
        4,
      );
    });

    test('next: in a gap of file 1 goes to the first cue of file 1', () {
      expect(
        AudiobookPlayerController.nextCueIndexForTesting(
          cues: cues,
          currentCueIndex: -1,
          audioFileIndex: 1,
          positionMs: 700,
        ),
        2,
      );
    });

    test('next: a file after every cue is the chapter boundary', () {
      expect(
        AudiobookPlayerController.nextCueIndexForTesting(
          cues: cues,
          currentCueIndex: -1,
          audioFileIndex: 5,
          positionMs: 0,
        ),
        isNull,
      );
    });

    test('prev: in a gap of file 1 goes to the last cue started before it', () {
      expect(
        AudiobookPlayerController.prevCueIndexForTesting(
          cues: cues,
          currentCueIndex: -1,
          currentCue: null,
          audioFileIndex: 1,
          positionMs: 700,
        ),
        2,
      );
    });

    test(
      'prev: before the first cue of file 1 goes to the last cue of file 0',
      () {
        expect(
          AudiobookPlayerController.prevCueIndexForTesting(
            cues: cues,
            currentCueIndex: -1,
            currentCue: null,
            audioFileIndex: 1,
            positionMs: 0,
          ),
          1,
        );
      },
    );

    test('prev: before the first cue of the first file stays at index 0', () {
      expect(
        AudiobookPlayerController.prevCueIndexForTesting(
          cues: cues,
          currentCueIndex: -1,
          currentCue: null,
          audioFileIndex: 0,
          positionMs: 0,
        ),
        0,
      );
    });

    test('skipByCues anchor resolves inside the current file', () {
      expect(
        AudiobookPlayerController.cueIndexAtFilePositionForTesting(
          cues: cues,
          audioFileIndex: 1,
          positionMs: 1200,
        ),
        3,
      );
      expect(
        AudiobookPlayerController.cueIndexAtFilePositionForTesting(
          cues: cues,
          audioFileIndex: 1,
          positionMs: 700,
        ),
        2,
      );
      expect(
        AudiobookPlayerController.cueIndexAtFilePositionForTesting(
          cues: cues,
          audioFileIndex: 2,
          positionMs: 200,
        ),
        4,
      );
      expect(
        AudiobookPlayerController.cueIndexAtFilePositionForTesting(
          cues: cues,
          audioFileIndex: 5,
          positionMs: 0,
        ),
        4,
      );
    });
  });
}
