import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:test/test.dart';

const List<String> _roster = <String>['A', 'B'];

Map<String, Object?> _raw(
  List<Object?> blocks, {
  String speaker = 'A',
  String kind = 'spoken',
  Map<String, Object?> extra = const <String, Object?>{},
}) => <String, Object?>{'b': blocks, 's': speaker, 'k': kind, ...extra};

MangaPageValidation _validate(List<Object?> raw, {int blockCount = 4}) =>
    validateMangaPageLines(
      page: 2,
      blockCount: blockCount,
      rawLines: raw,
      roster: _roster,
    );

MokuroBlock _block(List<String> lines) => MokuroBlock(
  rectangle: const MokuroRect.fromLTRB(0, 0, 10, 10),
  isVertical: true,
  fontSize: 12,
  zIndex: 0,
  lines: lines,
);

void main() {
  group('validateMangaPageLines', () {
    test('合格行全部保留，来源一律 AI，数值夹到范围', () {
      final MangaPageValidation r = _validate(<Object?>[
        _raw(
          <int>[1, 0],
          extra: <String, Object?>{
            'p': 2,
            'beat': -50,
            'e': 'joy',
            'ei': 150,
            'src': 'user',
            'seed': 3,
          },
        ),
        _raw(<int>[2], speaker: kTtsNarrator, kind: 'narration'),
        _raw(<int>[3], speaker: kTtsUnknown, kind: 'skip'),
      ]);
      expect(r.rejected, isEmpty);
      expect(r.accepted, hasLength(3));
      final MangaScriptLine l = r.accepted.first;
      expect(l.page, 2);
      expect(l.blocks, <int>[1, 0]);
      expect(l.beatMs, 0);
      expect(l.emotion, CastEmotion.joy);
      expect(l.intensity, MangaScriptLimits.maxIntensity);
      expect(l.source, TtsCastSource.llm);
      expect(l.seed, 3);
      expect(r.unclaimedBlocks, isEmpty);
    });

    test('每种拒绝原因各自识别，不抛异常', () {
      final MangaPageValidation r = _validate(<Object?>[
        'not a map',
        <String, Object?>{
          'b': <int>[0],
          'k': 'spoken',
        },
        _raw(<int>[0], extra: <String, Object?>{'p': 5}),
        _raw(<int>[]),
        _raw(<int>[4]),
        _raw(<int>[-1]),
        _raw(<Object?>['0']),
        _raw(<int>[1, 1]),
        _raw(<int>[0], speaker: 'C'),
        _raw(<int>[0], kind: 'whisper'),
        _raw(<int>[0], extra: <String, Object?>{'e': 'ecstatic'}),
        _raw(<int>[0]),
        _raw(<int>[2, 0], speaker: 'B'),
      ]);
      expect(
        r.rejected.map((MangaRejectedLine e) => (e.index, e.reason)),
        <(int, MangaLineRejection)>[
          (0, MangaLineRejection.malformed),
          (1, MangaLineRejection.malformed),
          (2, MangaLineRejection.wrongPage),
          (3, MangaLineRejection.noBlocks),
          (4, MangaLineRejection.blockOutOfRange),
          (5, MangaLineRejection.blockOutOfRange),
          (6, MangaLineRejection.blockOutOfRange),
          (7, MangaLineRejection.blockRepeated),
          (8, MangaLineRejection.unknownSpeaker),
          (9, MangaLineRejection.unknownKind),
          (10, MangaLineRejection.unknownEmotion),
          (12, MangaLineRejection.blockAlreadyClaimed),
        ],
      );
      expect(r.accepted.single.blocks, <int>[0]);
      expect(r.rejected.last.raw, isA<Map<String, Object?>>());
    });

    test('同一块先到先得；被拒行不认领块，未认领的块按「不读」列出', () {
      final MangaPageValidation r = _validate(<Object?>[
        _raw(<int>[1], speaker: 'C'),
        _raw(<int>[1]),
        _raw(<int>[1, 3], speaker: 'B'),
      ]);
      expect(r.accepted.single.speaker, 'A');
      expect(
        r.rejected.map((MangaRejectedLine e) => e.reason),
        <MangaLineRejection>[
          MangaLineRejection.unknownSpeaker,
          MangaLineRejection.blockAlreadyClaimed,
        ],
      );
      expect(r.unclaimedBlocks, <int>[0, 2, 3]);
    });

    test('空页：没有块时任何下标都越界', () {
      final MangaPageValidation r = _validate(<Object?>[
        _raw(<int>[0]),
      ], blockCount: 0);
      expect(r.rejected.single.reason, MangaLineRejection.blockOutOfRange);
      expect(r.unclaimedBlocks, isEmpty);
    });
  });

  group('台词文本解析', () {
    test('前一段不以句读结尾时块之间加「、」', () {
      expect(joinMangaBlockTexts(<String>['あいう', 'えお']), 'あいう、えお');
    });

    test('前一段以句读或闭括号结尾时直接相连', () {
      for (final String end in <String>[
        '。',
        '、',
        '！',
        '？',
        '!',
        '?',
        '…',
        '～',
        'ー',
        '」',
        '』',
      ]) {
        expect(joinMangaBlockTexts(<String>['あい$end', 'うえ']), 'あい$endうえ');
      }
    });

    test('去首尾空白、跳过空段', () {
      expect(joinMangaBlockTexts(<String>[' あい ', '  ', '\nうえ']), 'あい、うえ');
      expect(joinMangaBlockTexts(<String>[]), '');
    });

    test('按行的块顺序取 OCR 文字，块内多行直接相连，有修正用修正值', () {
      final List<MokuroBlock> blocks = <MokuroBlock>[
        _block(<String>['かき', 'く']),
        _block(<String>['さし']),
        _block(<String>['たち。']),
      ];
      final MangaScriptLine line = MangaScriptLine(
        page: 0,
        blocks: <int>[2, 0, 1],
        speaker: 'A',
        kind: CastLineKind.spoken,
        textFixes: <int, String>{1: 'なに'},
      );
      expect(resolveMangaLineText(line, blocks), 'たち。かきく、なに');
    });

    test('越界块下标跳过', () {
      final MangaScriptLine line = MangaScriptLine(
        page: 0,
        blocks: <int>[0, 9],
        speaker: 'A',
        kind: CastLineKind.spoken,
      );
      expect(
        resolveMangaLineText(line, <MokuroBlock>[
          _block(<String>['まみ']),
        ]),
        'まみ',
      );
    });
  });

  group('mangaOcrSignature', () {
    test('engine signature wins', () {
      expect(
        mangaOcrSignature(
          engineSignature: 'lens:ja',
          pages: <List<MokuroBlock>>[],
        ),
        'lens:ja',
      );
    });

    test('content signature is stable and changes with text or layout', () {
      final List<List<MokuroBlock>> a = <List<MokuroBlock>>[
        <MokuroBlock>[
          _block(<String>['あ', 'い']),
        ],
        <MokuroBlock>[],
      ];
      final String sig = mangaOcrSignature(engineSignature: null, pages: a);
      expect(sig, startsWith('content:'));
      expect(mangaOcrSignature(engineSignature: '', pages: a), sig);
      expect(
        mangaOcrSignature(
          engineSignature: null,
          pages: <List<MokuroBlock>>[
            <MokuroBlock>[
              _block(<String>['あい']),
            ],
            <MokuroBlock>[],
          ],
        ),
        isNot(sig),
      );
      expect(
        mangaOcrSignature(
          engineSignature: null,
          pages: <List<MokuroBlock>>[
            <MokuroBlock>[
              _block(<String>['あ', 'い']),
            ],
          ],
        ),
        isNot(sig),
      );
    });
  });
}
