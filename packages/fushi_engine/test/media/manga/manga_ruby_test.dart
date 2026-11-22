import 'package:fushi_engine/media/manga/manga_ruby.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render_plan.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:test/test.dart';

MokuroBlock _v(
  double l,
  double t,
  double r,
  double b,
  List<String> lines, {
  double fontSize = 40,
  List<List<List<double>>>? linesCoords,
}) => MokuroBlock(
  rectangle: MokuroRect.fromLTRB(l, t, r, b),
  isVertical: true,
  fontSize: fontSize,
  zIndex: 0,
  lines: lines,
  linesCoords: linesCoords,
);

/// 竖排一列「CRYCHICじゃない」（11 字、字距 40），右侧注音「クライシック」比底本短，
/// 只盖住中间几个字母。
final MokuroBlock _crychic = _v(600, 100, 640, 540, <String>['CRYCHICじゃない']);
final MokuroBlock _crychicRuby = _v(642, 140, 660, 340, <String>[
  'クライシック',
], fontSize: 18);

/// 三列「これがあれば / 春日影を / やらずに済む」，注音在第二列右侧、第一列左侧。
final MokuroBlock _harukage = _v(280, 100, 440, 340, <String>[
  'これがあれば',
  '春日影を',
  'やらずに済む',
]);

MangaScriptLine _line(List<int> blocks, {Map<int, String>? fixes}) =>
    MangaScriptLine(
      page: 0,
      blocks: blocks,
      speaker: kTtsUnknown,
      kind: CastLineKind.spoken,
      textFixes: fixes,
    );

void main() {
  test('拉丁字母底本：注音按整词换掉，后面的假名不动', () {
    final List<MokuroBlock> page = <MokuroBlock>[_crychic, _crychicRuby];
    final MangaPageRuby ruby = detectMangaPageRuby(page);
    expect(ruby.baseOfRuby, <int, int>{1: 0});
    expect(ruby.spokenLinesOf(0, _crychic.lines), <String>['クライシックじゃない']);
  });

  test('多行底本：注音落到它左边最近的那一列、只换被注的汉字', () {
    final MokuroBlock ruby = _v(382, 105, 398, 215, <String>[
      'はるひかげ',
    ], fontSize: 16);
    final MangaPageRuby result = detectMangaPageRuby(<MokuroBlock>[
      _harukage,
      ruby,
    ]);
    expect(result.spokenLinesOf(0, _harukage.lines), <String>[
      'これがあれば',
      'はるひかげを',
      'やらずに済む',
    ]);
  });

  test('逐字分开识别的注音按位置依次换', () {
    final MangaPageRuby result = detectMangaPageRuby(<MokuroBlock>[
      _harukage,
      _v(382, 105, 398, 135, <String>['はる'], fontSize: 16),
      _v(382, 145, 398, 175, <String>['ひ'], fontSize: 16),
      _v(382, 185, 398, 215, <String>['かげ'], fontSize: 16),
    ]);
    expect(result.baseOfRuby.keys, unorderedEquals(<int>[1, 2, 3]));
    expect(result.spokenLinesOf(0, _harukage.lines)[1], 'はるひかげを');
  });

  test('重叠的注音合成一条（读音按起点相连）', () {
    // 两块注音都盖到「日」：合并成 春日 一段，不把「日」换两遍。
    final MangaPageRuby result = detectMangaPageRuby(<MokuroBlock>[
      _harukage,
      _v(382, 105, 398, 165, <String>['はるひ'], fontSize: 16),
      _v(382, 150, 398, 215, <String>['かげ'], fontSize: 16),
    ]);
    expect(result.annotations, hasLength(1));
    expect(result.spokenLinesOf(0, _harukage.lines)[1], 'はるひかげを');
  });

  test('有 lines_coords 时按行框定位', () {
    final MokuroBlock base = _v(
      280,
      100,
      440,
      400,
      <String>['あの', '新曲だ'],
      linesCoords: <List<List<double>>>[
        <List<double>>[
          <double>[400, 100],
          <double>[440, 100],
          <double>[440, 180],
          <double>[400, 180],
        ],
        // 第二列下移一字起头：新曲 在 y 140..220。
        <List<double>>[
          <double>[320, 140],
          <double>[360, 140],
          <double>[360, 260],
          <double>[320, 260],
        ],
      ],
    );
    final MangaPageRuby result = detectMangaPageRuby(<MokuroBlock>[
      base,
      _v(362, 145, 378, 215, <String>['しんきょく'], fontSize: 16),
    ]);
    expect(result.spokenLinesOf(0, base.lines), <String>['あの', 'しんきょくだ']);
  });

  test('假名底本旁的小字不算注音', () {
    final MangaPageRuby result = detectMangaPageRuby(<MokuroBlock>[
      _v(600, 100, 640, 300, <String>['だよな']),
      _v(642, 120, 660, 260, <String>['ねえ'], fontSize: 18),
    ]);
    expect(result.baseOfRuby, isEmpty);
  });

  group('有声剧台词', () {
    final List<MokuroBlock> page = <MokuroBlock>[_crychic, _crychicRuby];

    test('底本与注音同一句：显示底本，合成念注音，注音块不重复', () {
      final ({String text, String spoken}) t = resolveMangaLineTexts(
        _line(<int>[0, 1]),
        page,
      );
      expect(t.text, 'CRYCHICじゃない');
      expect(t.spoken, 'クライシックじゃない');
      expect(resolveMangaLineText(_line(<int>[1, 0]), page), 'CRYCHICじゃない');
    });

    test('注音块没进句子也照样按注音念', () {
      final ({String text, String spoken}) t = resolveMangaLineTexts(
        _line(<int>[0]),
        page,
      );
      expect(t.text, 'CRYCHICじゃない');
      expect(t.spoken, 'クライシックじゃない');
    });

    test('底本有文本修正时不换读音；只有注音的行念注音本身', () {
      expect(
        resolveMangaLineTexts(
          _line(<int>[0, 1], fixes: <int, String>{0: 'CRYCHICじゃないの'}),
          page,
        ).spoken,
        'CRYCHICじゃないの',
      );
      expect(resolveMangaLineTexts(_line(<int>[1]), page).spoken, 'クライシック');
    });
  });

  group('只注首次的词：同卷后文沿用', () {
    final List<MokuroBlock> firstPage = <MokuroBlock>[
      _harukage,
      _v(382, 105, 398, 135, <String>['はる'], fontSize: 16),
      _v(382, 145, 398, 175, <String>['ひ'], fontSize: 16),
      _v(382, 185, 398, 215, <String>['かげ'], fontSize: 16),
      _crychic,
      _crychicRuby,
    ];
    final List<MokuroBlock> laterPage = <MokuroBlock>[
      _v(600, 100, 640, 540, <String>['春日影とCRYCHICの話']),
    ];

    test('逐字注音合成整词学下来；拉丁按整词匹配', () {
      final MangaRubyReadings learned = MangaRubyReadings()
        ..learnPage(firstPage);
      expect(learned.readings, <String, String>{
        '春日影': 'はるひかげ',
        'CRYCHIC': 'クライシック',
      });
      expect(learned.apply('春日影とCRYCHICの話'), 'はるひかげとクライシックの話');
      expect(learned.apply('CRYCHICS'), 'CRYCHICS');
      expect(learned.apply('春日影', skip: <String>{'春日影'}), '春日影');
    });

    test('单字底本不学；同一底本两种读音作废', () {
      final MangaRubyReadings learned = MangaRubyReadings()
        ..learnPage(<MokuroBlock>[
          _v(600, 100, 640, 300, <String>['日だ']),
          _v(642, 110, 660, 190, <String>['ひ'], fontSize: 18),
          _v(400, 100, 440, 300, <String>['本気だ']),
          _v(442, 105, 460, 230, <String>['マジ'], fontSize: 18),
        ])
        ..learnPage(<MokuroBlock>[
          _v(400, 100, 440, 300, <String>['本気だ']),
          _v(442, 105, 460, 230, <String>['ほんき'], fontSize: 18),
        ]);
      expect(learned.readings, isEmpty);
      // 片假名 / 平假名差别不算两种读音。
      final MangaRubyReadings same = MangaRubyReadings()
        ..learnPage(firstPage)
        ..learnPage(<MokuroBlock>[
          _crychic,
          _v(642, 140, 660, 340, <String>['くらいしっく'], fontSize: 18),
        ]);
      expect(same.readings['CRYCHIC'], 'クライシック');
    });

    test('有声剧：后面页没注音的同一个词也按注音念，替换表优先', () {
      final List<List<MokuroBlock>> volume = <List<MokuroBlock>>[
        firstPage,
        laterPage,
      ];
      final MangaScriptLine later = MangaScriptLine(
        page: 1,
        blocks: <int>[0],
        speaker: kTtsUnknown,
        kind: CastLineKind.spoken,
      );
      final ({String text, String spoken}) t = mangaLineTexts(later, volume);
      expect(t.text, '春日影とCRYCHICの話');
      expect(t.spoken, 'はるひかげとクライシックの話');
      expect(
        mangaLineTexts(
          later,
          volume,
          substitutions: const <CastTextSubstitution>[
            CastTextSubstitution(source: '春日影', replacement: 'はるかげ'),
          ],
        ).spoken,
        'はるかげとクライシックの話',
      );
    });
  });
}
