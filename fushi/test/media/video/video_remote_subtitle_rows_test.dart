import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi_audio/fushi_audio.dart';

AudioCue _cue(String text, int startMs, int endMs) => AudioCue()
  ..bookKey = 'video/remote'
  ..chapterHref = 'video://default'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..audioFileIndex = 0
  ..text = text
  ..startMs = startMs
  ..endMs = endMs;

// Same source fixture as video_subtitle_list_per_char_merge_test.dart:
// Tensei Oujo OP, PlayRes 1280x720, x step 30, fade step 40 ms.
List<AudioCue> _opLine() {
  const List<String> characters = <String>['手', 'を', '伸', 'ば', 'し', 'て'];
  return <AudioCue>[
    for (int i = 0; i < characters.length; i++)
      _cue(characters[i], 41350 + i * 40, 44480 + i * 40)
        ..markup = parseSubtitleMarkup(
          '{\\an7\\pos(${461 + i * 30},672)\\fad(250,250)\\blur2}${characters[i]}',
          playResX: 1280,
          playResY: 720,
        ),
  ];
}

void main() {
  test('duplicate effects retain first raw index and separate translation', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue('台詞', 1000, 2000),
      _cue('台詞', 1000, 2000),
      _cue('translation', 1000, 2000),
    ];
    final rows = subtitleTranscriptRows(cues);
    expect(rows.indexes, <int>[0, 2]);
    expect(rows.representativeByRaw, <int, int>{0: 0, 1: 0, 2: 2});
    expect(rows.mergedByRep, isEmpty);
    expect(cues.map((AudioCue cue) => cue.text), <String>[
      '台詞',
      '台詞',
      'translation',
    ]);
  });

  test(
    'ASS character fixture produces one whole sentence without changing cues',
    () {
      final List<AudioCue> cues = _opLine();
      final rows = subtitleTranscriptRows(cues);
      expect(rows.indexes, <int>[0]);
      expect(rows.representativeByRaw.values, everyElement(0));
      final AudioCue sentence = rows.mergedByRep[0]!;
      expect(sentence.text, '手を伸ばして');
      expect(sentence.startMs, 41350);
      expect(sentence.endMs, 44680);
      expect(sentence.markup, isNull);
      expect(cues.map((AudioCue cue) => cue.text), <String>[
        '手',
        'を',
        '伸',
        'ば',
        'し',
        'て',
      ]);
      expect(cues.every((AudioCue cue) => cue.markup != null), isTrue);
    },
  );

  test('OP effect chains map every segment to stable first representative', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue('OP lyric', 61670, 63130),
      _cue('OP lyric', 61670, 63130),
      _cue('OP lyric', 63130, 64670),
      _cue('OP lyric', 63130, 64670),
      _cue('OP lyric', 64670, 66210),
      _cue('OP lyric', 66210, 68050),
    ];
    final rows = subtitleTranscriptRows(cues);
    expect(rows.indexes, <int>[0]);
    expect(rows.representativeByRaw.values, everyElement(0));
    // Preserve desktop row semantics: chain folding does not expand the cue.
    expect(rows.mergedByRep, isEmpty);
    expect(cues[rows.indexes.single].endMs, 63130);
    // The folded row spans the whole chain, not only its head segment.
    expect(rows.chainEndMsByRep, <int, int>{0: 68050});
    final spans = subtitleTranscriptRowSpans(cues);
    expect(spans, hasLength(1));
    expect(spans.single.rawIndex, 0);
    expect(spans.single.text, 'OP lyric');
    expect(spans.single.startMs, 61670);
    expect(spans.single.endMs, 68050);
    expect(
      subtitleTranscriptRows(List<AudioCue>.of(cues)).indexes,
      rows.indexes,
    );
  });

  test(
    '40 ms effects fold, repeated dialogue after silence keeps its raw id',
    () {
      final List<AudioCue> cues = <AudioCue>[
        _cue('はい', 1000, 2000),
        _cue('はい', 2040, 3000),
        _cue('はい', 3041, 4000),
      ];
      final rows = subtitleTranscriptRows(cues);
      expect(rows.indexes, <int>[0, 2]);
      expect(rows.representativeByRaw, <int, int>{0: 0, 1: 0, 2: 2});
      expect(rows.chainEndMsByRep, <int, int>{0: 3000});
      expect(subtitleTranscriptRowSpans(cues).map((row) => row.endMs), <int>[
        3000,
        4000,
      ]);
    },
  );

  test(
    'primary and secondary share raw starts but keep independent clocks',
    () {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[
        _cue('台詞', 1000, 2000),
        _cue('台詞', 1000, 2000),
      ]);
      controller.setSecondaryCues(<AudioCue>[
        _cue('translation', 1000, 2200),
        _cue('translation', 1000, 2200),
      ]);
      controller.setDelayMs(250);
      controller.setSecondaryDelayMs(-400);
      final primary = subtitleTranscriptRows(controller.cues);
      final secondary = subtitleTranscriptRows(controller.secondaryCues);
      expect(primary.indexes, <int>[0]);
      expect(secondary.indexes, <int>[0]);
      final AudioCue primaryCue = controller.cues[primary.indexes.single];
      final AudioCue secondaryCue =
          controller.secondaryCues[secondary.indexes.single];
      expect(primaryCue.text, '台詞');
      expect(secondaryCue.text, 'translation');
      expect(primaryCue.startMs, secondaryCue.startMs);
      expect(controller.delayMsForCue(primaryCue), 250);
      expect(controller.delayMsForCue(secondaryCue), -400);
    },
  );

  test('empty transcripts keep all maps empty', () {
    final rows = subtitleTranscriptRows(<AudioCue>[]);
    expect(rows.indexes, isEmpty);
    expect(rows.representativeByRaw, isEmpty);
    expect(rows.mergedByRep, isEmpty);
    expect(rows.chainEndMsByRep, isEmpty);
    expect(subtitleTranscriptRowSpans(<AudioCue>[]), isEmpty);
  });
}
