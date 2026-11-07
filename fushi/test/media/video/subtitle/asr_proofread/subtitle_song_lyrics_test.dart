import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_song_lyrics.dart';
import 'package:path/path.dart' as p;

import '../../../../helpers/fake_ai_text_completer.dart';

/// 歌词来源替身：记下查询，给固定候选。
class _FakeFinder implements SubtitleLyricsFinder {
  _FakeFinder(this.candidates);

  final List<SubtitleLyricsCandidate> candidates;
  final List<SubtitleSongQuery> queries = <SubtitleSongQuery>[];

  @override
  Future<List<SubtitleLyricsCandidate>> find(
    SubtitleSongQuery query, {
    required AiTextCompleter completer,
    required SubtitleAiUsageTally usage,
    required SubtitleCancelToken cancel,
  }) async {
    queries.add(query);
    return candidates;
  }
}

class _ExplodingFinder implements SubtitleLyricsFinder {
  @override
  Future<List<SubtitleLyricsCandidate>> find(
    SubtitleSongQuery query, {
    required AiTextCompleter completer,
    required SubtitleAiUsageTally usage,
    required SubtitleCancelToken cancel,
  }) => throw StateError('finder should not be called');
}

SubtitleDraftCue _c(int start, String text) =>
    SubtitleDraftCue(startMs: start, endMs: start + 2500, text: text);

/// 台词 + 三句歌（♪，ASR 有误） + 台词。
final List<SubtitleDraftCue> _cues = <SubtitleDraftCue>[
  _c(0, 'おはよう'),
  _c(60000, '♪君の声が聞こえれ'),
  _c(63000, '♪空へ飛んで行く'),
  _c(66000, '♪明日もまた会おう'),
  _c(120000, 'またね'),
];

const SubtitleLyricsCandidate _candidate = SubtitleLyricsCandidate(
  source: 'lrclib',
  lines: <String>['君の声が聞こえる', '空へ飛んでいく', '明日もまた会おう'],
);

final RegExp _kAlignId = RegExp(r'^id=(\d+) ', multiLine: true);

String _answer(String prompt, int call) {
  if (prompt.startsWith(kSubtitleSongIdentifyPrompt)) {
    return 'TITLE\tキミの声\tテストバンド\n$kAiLineReplyEnd';
  }
  if (prompt.startsWith(kSubtitleLyricsAlignPrompt)) {
    final List<int> ids = <int>[
      for (final RegExpMatch m in _kAlignId.allMatches(prompt))
        int.parse(m.group(1)!),
    ];
    expect(ids, <int>[1, 2, 3]);
    return <String>[
      '1\t君の声が聞こえる',
      '2\t空へ飛んでいく',
      // 模型编的：歌词里没有，必须丢掉。
      '3\t明後日も会おう',
      kAiLineReplyEnd,
    ].join('\n');
  }
  throw StateError('unexpected prompt');
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('lyrics_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('歌曲段检测', () {
    test('♪ 行按间隔成段，不足 3 行不成段', () {
      final List<SubtitleSongSpan> spans = detectSubtitleSongSpans(_cues);
      expect(spans, hasLength(1));
      expect(spans.single.cueIndexes, <int>[1, 2, 3]);
      expect(
        detectSubtitleSongSpans(<SubtitleDraftCue>[
          _c(0, '♪a'),
          _c(3000, '♪b'),
        ]),
        isEmpty,
      );
    });

    test('证据里的歌词行能把没标 ♪ 的行认成歌，并带进段的证据', () {
      final List<SubtitleDraftCue> plain = <SubtitleDraftCue>[
        _c(0, 'きみのこえが'),
        _c(3000, 'そらへ'),
        _c(6000, 'あしたも'),
      ];
      final List<SubtitleSongSpan> spans = detectSubtitleSongSpans(
        plain,
        evidence: <SubtitleEvidenceTrack>[
          const SubtitleEvidenceTrack(
            label: 'en.ass',
            kind: SubtitleEvidenceKind.text,
            language: 'en',
            cues: <SubtitleEvidenceCue>[
              SubtitleEvidenceCue(
                startMs: 0,
                endMs: 9000,
                text: 'I can hear your voice',
                role: SubtitleEvidenceRole.song,
              ),
            ],
          ),
        ],
      );
      expect(spans.single.cueIndexes, <int>[0, 1, 2]);
      expect(spans.single.evidenceLines, contains('I can hear your voice'));
    });

    test('allSung：整段一首', () {
      final List<SubtitleDraftCue> plain = <SubtitleDraftCue>[
        _c(0, 'a'),
        _c(30000, 'b'),
        _c(60000, 'c'),
      ];
      expect(
        detectSubtitleSongSpans(plain, allSung: true).single.cueIndexes,
        <int>[0, 1, 2],
      );
    });
  });

  group('归一化与相似度', () {
    test('片假名转平假名、去标点空白、全角转半角', () {
      expect(normalizeLyricsForMatch('キミの 声、ＡＢＣ!'), 'きみの声abc');
      expect(lyricsBigramDice('君の声が聞こえれ', '君の声が聞こえる'), greaterThan(0.8));
      expect(lyricsBigramDice('全然違う', 'まったく別物'), 0);
    });

    test('LRC 时间戳 / 元信息行去掉', () {
      expect(lyricsTextLines('[ar:x]\n[00:01.00]君の声\n\n[00:05.00]空へ'), <String>[
        '君の声',
        '空へ',
      ]);
    });
  });

  test('校验：编的歌词丢掉；覆盖率不足整段不采用', () {
    final SubtitleSongSpan span = detectSubtitleSongSpans(_cues).single;
    final Map<int, String>? ok = verifySubtitleLyricsAlignment(
      cues: _cues,
      span: span,
      candidate: _candidate,
      mapped: <int, String>{1: '君の声が聞こえる', 2: '空へ飛んでいく', 3: '明後日も会おう'},
    );
    expect(ok, <int, String>{1: '♪君の声が聞こえる', 2: '♪空へ飛んでいく'});
    expect(
      verifySubtitleLyricsAlignment(
        cues: _cues,
        span: span,
        candidate: _candidate,
        mapped: <int, String>{1: '君の声が聞こえる'},
      ),
      isNull,
    );
  });

  test('补齐：认歌 → 查 → 对齐 → 校验写回，标 origin；第二次走缓存不发请求', () async {
    final File cache = File(p.join(tmp.path, 'lyrics.json'));
    final FakeAiCompleter ai = FakeAiCompleter(_answer);
    final _FakeFinder finder = _FakeFinder(<SubtitleLyricsCandidate>[
      _candidate,
    ]);
    final SubtitleLyricsPassResult r = await SubtitleLyricsPass(
      completer: ai,
      finder: finder,
    ).run(cues: _cues, workTitle: 'BanG Dream!', cacheFile: cache);
    expect(r.filledSpans, 1);
    expect(r.cues[1].text, '♪君の声が聞こえる');
    expect(r.cues[1].origin, 'lyrics:lrclib');
    expect(isSubtitleLyricsCue(r.cues[2]), isTrue);
    // 没过校验的行保持 ASR 原文。
    expect(r.cues[3].text, '♪明日もまた会おう');
    expect(isSubtitleLyricsCue(r.cues[3]), isFalse);
    expect(r.cues[0].text, 'おはよう');
    expect(finder.queries.single.title, 'キミの声');
    expect(finder.queries.single.artist, 'テストバンド');
    expect(cache.existsSync(), isTrue);

    final ExplodingAiCompleter exploding = ExplodingAiCompleter();
    final SubtitleLyricsPassResult again = await SubtitleLyricsPass(
      completer: exploding,
      finder: _ExplodingFinder(),
    ).run(cues: _cues, workTitle: 'BanG Dream!', cacheFile: cache);
    expect(exploding.calls, 0);
    expect(
      <String>[for (final SubtitleDraftCue c in again.cues) c.text],
      <String>[for (final SubtitleDraftCue c in r.cues) c.text],
    );
  });

  test('认不出歌、候选全不过校验：原样返回，结果也缓存', () async {
    final File cache = File(p.join(tmp.path, 'lyrics.json'));
    final FakeAiCompleter ai = FakeAiCompleter(
      (String prompt, int call) => 'UNKNOWN\n$kAiLineReplyEnd',
    );
    final _FakeFinder finder = _FakeFinder(const <SubtitleLyricsCandidate>[]);
    final SubtitleLyricsPassResult r = await SubtitleLyricsPass(
      completer: ai,
      finder: finder,
    ).run(cues: _cues, workTitle: 'w', cacheFile: cache);
    expect(r.filledSpans, 0);
    expect(r.cues, _cues);
    expect(finder.queries.single.title, isNull);
    expect(cache.existsSync(), isTrue);
  });
}
