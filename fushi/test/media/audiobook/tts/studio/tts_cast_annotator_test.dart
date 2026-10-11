import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_cast_prompt.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
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

List<TtsPlanSentence> _lines(int n, {int section = 2, String text = 'あ'}) =>
    <TtsPlanSentence>[
      for (int i = 0; i < n; i++) _s(section, i * 10, '$text$i'),
    ];

void main() {
  group('chunkTtsCastSection', () {
    test('按句数切块，前后带参考上下文', () {
      final List<TtsCastChunk> chunks = chunkTtsCastSection(
        _lines(250),
        maxSentences: 100,
        contextSentences: 4,
      );
      expect(chunks.map((TtsCastChunk c) => c.sentences.length), <int>[
        100,
        100,
        50,
      ]);
      expect(chunks.first.before, isEmpty);
      expect(chunks.first.after.map((TtsPlanSentence s) => s.text), <String>[
        'あ100',
        'あ101',
        'あ102',
        'あ103',
      ]);
      expect(chunks[1].before.map((TtsPlanSentence s) => s.text).last, 'あ99');
      expect(chunks.last.after, isEmpty);
    });

    test('按字数切块，超长单句自成一块', () {
      final List<TtsPlanSentence> sentences = <TtsPlanSentence>[
        _s(0, 0, 'a' * 40),
        _s(0, 40, 'b' * 40),
        _s(0, 80, 'c' * 200),
        _s(0, 280, 'd' * 10),
      ];
      final List<TtsCastChunk> chunks = chunkTtsCastSection(
        sentences,
        maxChars: 100,
      );
      expect(chunks.map((TtsCastChunk c) => c.sentences.length), <int>[
        2,
        1,
        1,
      ]);
    });

    test('空章没有块', () {
      expect(chunkTtsCastSection(const <TtsPlanSentence>[]), isEmpty);
    });
  });

  group('hasDialogue', () {
    test('只认引号开头的句子', () {
      expect(ttsCastLooksLikeDialogue('「行くぞ」'), isTrue);
      expect(ttsCastLooksLikeDialogue('　『待って』'), isTrue);
      expect(ttsCastLooksLikeDialogue('“Hello,” he said.'), isTrue);
      expect(ttsCastLooksLikeDialogue('彼は「魔女」と呼ばれた。'), isFalse);
      expect(
        TtsCastChunk(
          sentences: <TtsPlanSentence>[_s(0, 0, '地の文。')],
          before: const <TtsPlanSentence>[],
          after: const <TtsPlanSentence>[],
        ).hasDialogue,
        isFalse,
      );
    });
  });

  group('buildTtsCastUserPrompt', () {
    test('编号 1..n、上下文不编号、已知角色、去旁白、去换行', () {
      final TtsCastChunk chunk = TtsCastChunk(
        before: <TtsPlanSentence>[_s(1, 0, '前の文。')],
        sentences: <TtsPlanSentence>[
          _s(1, 10, '「おはよう」'),
          _s(1, 20, 'とエミリアは\n言った。'),
        ],
        after: <TtsPlanSentence>[_s(1, 40, '後の文。')],
      );
      final String prompt = buildTtsCastUserPrompt(
        chunk,
        knownSpeakers: <String>['スバル', kTtsNarrator, 'エミリア'],
      );
      expect(
        prompt,
        contains('Known characters (reuse these exact names): スバル、エミリア\n'),
      );
      expect(prompt, isNot(contains(kTtsNarrator)));
      expect(prompt, contains('context: 前の文。'));
      expect(prompt, contains('1: 「おはよう」\n'));
      expect(prompt, contains('2: とエミリアは 言った。\n'));
      expect(prompt, contains('context: 後の文。'));
      expect(prompt, contains('lines 1-2 only'));
      expect(
        prompt.indexOf('context: 前の文。') < prompt.indexOf('1: 「おはよう」'),
        isTrue,
      );
    });

    test('没有已知角色时不出现那一行', () {
      final String prompt = buildTtsCastUserPrompt(
        TtsCastChunk(
          sentences: <TtsPlanSentence>[_s(0, 0, '「あ」')],
          before: const <TtsPlanSentence>[],
          after: const <TtsPlanSentence>[],
        ),
        knownSpeakers: const <String>[],
      );
      expect(prompt, isNot(contains('Known characters')));
      expect(prompt, isNot(contains('context')));
    });

    test('系统提示要求纯 JSON、原文字形、统一名字', () {
      expect(kTtsCastSystemPrompt, contains('ONLY a JSON array'));
      expect(kTtsCastSystemPrompt, contains('original script'));
      expect(kTtsCastSystemPrompt, contains('ONE canonical name'));
      expect(kTtsCastSystemPrompt, contains('「…」とスバルは言った'));
    });
  });

  group('parseTtsCastReply', () {
    test('纯 JSON 数组', () {
      final TtsCastParseResult? r = parseTtsCastReply(
        '[{"i":1,"s":"エミリア","e":"怒り"},{"i":3,"s":"スバル"}]',
        3,
      );
      expect(r, isNotNull);
      expect(r!.rawCount, 2);
      expect(
        r.labels.map((TtsCastLabel l) => (l.index, l.speaker, l.emotion)),
        <(int, String, String?)>[(1, 'エミリア', '怒り'), (3, 'スバル', null)],
      );
    });

    test('剥 ```json 围栏与前后多余文字', () {
      final TtsCastParseResult? r = parseTtsCastReply(
        'Here you go [see below]:\n```json\n[{"i":2,"s":"レム"}]\n```\nDone.',
        2,
      );
      expect(r!.labels.single.speaker, 'レム');
      expect(r.labels.single.index, 2);
    });

    test('字符串里的括号不打乱配对', () {
      final TtsCastParseResult? r = parseTtsCastReply(
        '[{"i":1,"s":"男[仮]","e":"\\"笑\\""}]',
        1,
      );
      expect(r!.labels.single.speaker, '男[仮]');
      expect(r.labels.single.emotion, '"笑"');
    });

    test('越界 / 非法 / 重复编号丢弃，字符串与整数小数编号接受', () {
      final TtsCastParseResult? r = parseTtsCastReply(
        '[{"i":0,"s":"A"},{"i":4,"s":"B"},{"i":"2","s":"C"},'
        '{"i":2,"s":"D"},{"i":3.0,"s":"E"},{"i":1.5,"s":"F"},'
        '{"s":"G"},"junk",{"i":1,"s":"  "},{"i":1,"s":7}]',
        3,
      );
      expect(r!.rawCount, 10);
      expect(
        r.labels.map((TtsCastLabel l) => '${l.index}${l.speaker}'),
        <String>['2C', '3E'],
      );
    });

    test('旁白别名不收、空 / 过长情绪丢弃', () {
      final TtsCastParseResult? r = parseTtsCastReply(
        '[{"i":1,"s":"Narrator"},{"i":2,"s":"地の文"},'
        '{"i":3,"s":"スバル","e":""},{"i":4,"s":"レム","e":"${'長' * 40}"}]',
        4,
      );
      expect(
        r!.labels.map((TtsCastLabel l) => (l.speaker, l.emotion)),
        <(String, String?)>[('スバル', null), ('レム', null)],
      );
    });

    test('空数组可解析；没有数组 / 坏 JSON 返回 null', () {
      final TtsCastParseResult? empty = parseTtsCastReply('[]', 5);
      expect(empty!.labels, isEmpty);
      expect(empty.rawCount, 0);
      expect(parseTtsCastReply('', 5), isNull);
      expect(parseTtsCastReply('no dialogue here', 5), isNull);
      expect(parseTtsCastReply('[{"i":1,"s":"A"', 5), isNull);
      expect(parseTtsCastReply('{"i":1,"s":"A"}', 5), isNull);
    });

    test('先出现的非 JSON 方括号被跳过', () {
      final TtsCastParseResult? r = parseTtsCastReply(
        '[note] lines [1-2]: [{"i":1,"s":"A"}]',
        2,
      );
      expect(r!.labels.single.speaker, 'A');
    });
  });

  group('ttsCastLinesForChunk', () {
    test('回了的行归角色，其余行记旁白（llm 来源），键按章 + 匹配偏移', () {
      final TtsCastChunk chunk = TtsCastChunk(
        sentences: <TtsPlanSentence>[
          _s(3, 0, '「あ」'),
          _s(3, 5, '地の文。'),
          _s(3, 9, '「い」'),
        ],
        before: const <TtsPlanSentence>[],
        after: const <TtsPlanSentence>[],
      );
      final Map<String, TtsCastLine> lines =
          ttsCastLinesForChunk(chunk, const <TtsCastLabel>[
            TtsCastLabel(index: 1, speaker: 'スバル', emotion: '驚き'),
            TtsCastLabel(index: 3, speaker: 'エミリア'),
          ]);
      expect(lines.keys, <String>['3:0', '3:5', '3:9']);
      expect(lines['3:0']!.speaker, 'スバル');
      expect(lines['3:0']!.emotion, '驚き');
      expect(lines['3:5']!.speaker, kTtsNarrator);
      expect(lines['3:9']!.speaker, 'エミリア');
      expect(
        lines.values.every((TtsCastLine l) => l.source == TtsCastSource.llm),
        isTrue,
      );
    });
  });
}
