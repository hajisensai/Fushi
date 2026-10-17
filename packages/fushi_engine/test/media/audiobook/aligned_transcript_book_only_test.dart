import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 正文两句；第二条 cue 是书里没有的念白（人物介绍图片页上的「趣味」）。
const String _book = '夢見る時がある。転入生がやってくる。';
const List<EpubSection> _sections = <EpubSection>[
  EpubSection(index: 0, href: 'ch0.xhtml', text: _book),
];

AudioCue _cue(int i, String text, int start) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = ''
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = text
  ..startMs = start
  ..endMs = start + 900
  ..audioFileIndex = 0;

CueMatch _hit(int i, int s, int e) => CueMatch(
  cueSentenceIndex: i,
  sectionIndex: 0,
  normCharStart: s,
  normCharEnd: e,
  score: 1,
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('aligned_book_only_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String asrJob(List<AudioCue> cues) {
    File(p.join(tmp.path, AsrJobFiles.state)).writeAsStringSync('{}');
    final File srt = File(p.join(tmp.path, AsrJobFiles.srt))
      ..writeAsStringSync(serializeAudioCuesToSrt(cues));
    return srt.path;
  }

  Future<List<String>> readTexts(String path) async => <String>[
    for (final AudioCue c in await SrtParser.parse(
      srtFile: File(path),
      bookKey: 'b',
      audioFileIndex: 0,
    ))
      c.text,
  ];

  test('对齐版只放命中正文的 cue，未命中的念白另写 speech 版', () async {
    final List<AudioCue> cues = <AudioCue>[
      _cue(0, '夢見る時がある', 1000),
      _cue(1, '趣味', 3000),
      _cue(2, '転入生がやってくる', 5000),
    ];
    final String srt = asrJob(cues);
    await finalizeAlignedCues(
      sections: _sections,
      cues: cues,
      result: MatchResult(
        matches: <CueMatch>[_hit(0, 0, 7), CueMatch.unmatched, _hit(2, 7, 16)],
        totalCues: 3,
        matchedCues: 2,
      ),
      subtitlePath: srt,
      hasTokenTiming: false,
    );
    expect(await readTexts(asrAlignedTranscriptPathFor(srt)), <String>[
      '夢見る時がある。',
      '転入生がやってくる。',
    ]);
    expect(
      await readTexts(p.join(tmp.path, kAsrSpeechTranscriptFileName)),
      <String>['趣味'],
    );
  });

  test('命中率过低（多半配错书）：对齐版退回全量，不写 speech 版', () async {
    final List<AudioCue> cues = <AudioCue>[
      _cue(0, '夢見る時がある', 1000),
      _cue(1, '趣味', 3000),
      _cue(2, '特技', 5000),
    ];
    final String srt = asrJob(cues);
    await finalizeAlignedCues(
      sections: _sections,
      cues: cues,
      result: MatchResult(
        matches: <CueMatch>[
          _hit(0, 0, 7),
          CueMatch.unmatched,
          CueMatch.unmatched,
        ],
        totalCues: 3,
        matchedCues: 1,
      ),
      subtitlePath: srt,
      hasTokenTiming: false,
    );
    expect(await readTexts(asrAlignedTranscriptPathFor(srt)), hasLength(3));
    expect(
      File(p.join(tmp.path, kAsrSpeechTranscriptFileName)).existsSync(),
      isFalse,
    );
  });
}
