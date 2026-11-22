import 'package:test/test.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_cast_passes.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_cast_prompt.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';

TtsPlanSentence _s(int section, int matchStart, String text) => TtsPlanSentence(
  section: section,
  href: 'c$section.xhtml',
  text: text,
  spokenText: text,
  matchStart: matchStart,
  matchEnd: matchStart + text.length,
  studyStart: matchStart,
  studyEnd: matchStart + text.length,
);

/// 后记章：没有角色说出口的台词，但有独立一行的『書名』和「標牌」——切句后
/// 两行都以括弧开头，[ttsCastLooksLikeDialogue] 判为台词，块的 hasDialogue 为真。
final List<TtsPlanSentence> _afterword = <TtsPlanSentence>[
  _s(7, 0, 'あとがき'),
  _s(7, 10, '『ドレスな僕がやんごとなき方々の家庭教師様な件』'),
  _s(7, 40, '六巻です！'),
  _s(7, 50, '「立ち入り禁止」'),
  _s(7, 60, 'ありがとうございました。'),
];

/// 跑一次两遍标注：第一遍回 [rosterReply]、第二遍回 [linesReply]。
Future<({TtsCast cast, int saves, List<String> systems})> _run({
  required List<TtsPlanSentence> sentences,
  required String rosterReply,
  required String linesReply,
}) async {
  final TtsCast cast = TtsCast();
  final List<String> systems = <String>[];
  int saves = 0;
  final int section = sentences.first.section;
  await runTtsCastPasses(
    cast: cast,
    bySection: <int, List<TtsPlanSentence>>{section: sentences},
    todo: <int>[section],
    substitutions: const <CastTextSubstitution>[],
    ask: (String system, String user) async {
      systems.add(system);
      return system == kTtsRosterSystemPrompt ? rosterReply : linesReply;
    },
    save: () async => saves++,
    onProgress: (int done, int total) {},
    isCancelled: () => false,
  );
  return (cast: cast, saves: saves, systems: systems);
}

void main() {
  group('两遍标注主循环', () {
    test('无台词章含句首『書名』/「標牌」：两遍都回 [] 不报 bad_output，章标完', () async {
      expect(chunkTtsCastSection(_afterword).single.hasDialogue, isTrue);

      final ({TtsCast cast, int saves, List<String> systems}) r = await _run(
        sentences: _afterword,
        rosterReply: '[]',
        linesReply: '[]',
      );

      expect(r.systems, <String>[
        kTtsRosterSystemPrompt,
        kTtsCastLinesSystemPrompt,
      ]);
      expect(r.saves, 2);
      expect(r.cast.annotatedSections, <int>{7});
      // 模型没回的括弧行按现有兜底记「不明、零把握」进复核，其余记旁白。
      expect(r.cast.lines[ttsLineKey(7, 10)]?.speaker, kTtsUnknown);
      expect(r.cast.lines[ttsLineKey(7, 10)]?.confidence, 0);
      expect(r.cast.lines[ttsLineKey(7, 50)]?.speaker, kTtsUnknown);
      for (final int start in <int>[0, 40, 60]) {
        expect(r.cast.lines[ttsLineKey(7, start)]?.speaker, kTtsNarrator);
      }
    });

    test('有效标注照常并入', () async {
      final ({TtsCast cast, int saves, List<String> systems}) r = await _run(
        sentences: <TtsPlanSentence>[
          _s(3, 0, 'スバルは振り返った。'),
          _s(3, 20, '「行くぞ」'),
        ],
        rosterReply: '[{"op":"add","name":"スバル"}]',
        linesReply: '[{"i":2,"s":"スバル"}]',
      );
      expect(r.cast.roster.keys, contains('スバル'));
      expect(r.cast.lines[ttsLineKey(3, 20)]?.speaker, 'スバル');
      expect(r.cast.lines[ttsLineKey(3, 0)]?.speaker, kTtsNarrator);
    });

    test('第二遍非空数组全废仍报 bad_output', () async {
      await expectLater(
        _run(
          sentences: _afterword,
          rosterReply: '[]',
          linesReply: '[{"line":1,"speaker":"スバル"}]',
        ),
        throwsA(
          isA<TtsCastAnnotateFailure>()
              .having(
                (TtsCastAnnotateFailure f) => f.code,
                'code',
                'bad_output',
              )
              .having(
                (TtsCastAnnotateFailure f) => f.detail,
                'detail',
                'lines, section 7: no usable entries',
              ),
        ),
      );
    });

    test('第一遍缺 JSON 数组报 bad_output', () async {
      await expectLater(
        _run(sentences: _afterword, rosterReply: '抱歉', linesReply: '[]'),
        throwsA(
          isA<TtsCastAnnotateFailure>().having(
            (TtsCastAnnotateFailure f) => f.detail,
            'detail',
            'roster, section 7: no JSON array',
          ),
        ),
      );
    });
  });
}
