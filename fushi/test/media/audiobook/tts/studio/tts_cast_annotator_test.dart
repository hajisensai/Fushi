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

TtsCastChunk _chunk(
  List<TtsPlanSentence> sentences, {
  List<TtsPlanSentence> before = const <TtsPlanSentence>[],
  List<TtsPlanSentence> after = const <TtsPlanSentence>[],
}) => TtsCastChunk(sentences: sentences, before: before, after: after);

const List<TtsCastCharacter> _roster = <TtsCastCharacter>[
  TtsCastCharacter(
    name: 'スバル',
    aliases: <String>['菜月昴', 'スバルくん'],
    gender: 'male',
    age: 'teen',
    description: '口数の多い少年',
  ),
  TtsCastCharacter(name: 'エミリア', aliases: <String>['銀髪の少女'], gender: 'female'),
  TtsCastCharacter(name: 'Rem', aliases: <String>['レム']),
];

final TtsCastSpeakerIndex _index = TtsCastSpeakerIndex(_roster);

void main() {
  group('分块', () {
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
      final List<TtsCastChunk> chunks = chunkTtsCastSection(<TtsPlanSentence>[
        _s(0, 0, 'a' * 40),
        _s(0, 40, 'b' * 40),
        _s(0, 80, 'c' * 200),
        _s(0, 280, 'd' * 10),
      ], maxChars: 100);
      expect(chunks.map((TtsCastChunk c) => c.sentences.length), <int>[
        2,
        1,
        1,
      ]);
    });

    test('角色表分块：大块、无上下文', () {
      final List<TtsCastChunk> chunks = chunkTtsRosterSection(
        _lines(300, text: 'あ' * 60),
      );
      expect(chunks.length, 2);
      expect(chunks.first.sentences.length, greaterThan(100));
      expect(chunks.every((TtsCastChunk c) => c.before.isEmpty), isTrue);
      expect(chunks.every((TtsCastChunk c) => c.after.isEmpty), isTrue);
    });

    test('空章没有块', () {
      expect(chunkTtsCastSection(const <TtsPlanSentence>[]), isEmpty);
    });
  });

  group('台词判定', () {
    test('只认引号开头的句子', () {
      expect(ttsCastLooksLikeDialogue('「行くぞ」'), isTrue);
      expect(ttsCastLooksLikeDialogue('　『待って』'), isTrue);
      expect(ttsCastLooksLikeDialogue('“Hello,” he said.'), isTrue);
      expect(ttsCastLooksLikeDialogue('彼は「魔女」と呼ばれた。'), isFalse);
      expect(_chunk(<TtsPlanSentence>[_s(0, 0, '地の文。')]).hasDialogue, isFalse);
    });

    test('引号未闭合的续行也算台词，闭合后恢复', () {
      final List<bool> flags = ttsCastDialogueFlags(<TtsPlanSentence>[
        _s(0, 0, '「長い台詞の前半で、'),
        _s(0, 10, '後半はここまで」'),
        _s(0, 20, 'と彼は言った。'),
        _s(0, 30, '彼女は「魔女」と呼ばれた。'),
        _s(0, 40, '地の文。'),
      ]);
      expect(flags, <bool>[true, true, false, false, false]);
    });

    test('漏了闭引号时续行有上限，不会把整章染成台词', () {
      final List<bool> flags = ttsCastDialogueFlags(<TtsPlanSentence>[
        _s(0, 0, '「閉じない'),
        for (int i = 1; i <= 20; i++) _s(0, i * 10, '地の文$i。'),
      ]);
      expect(flags.take(9).every((bool f) => f), isTrue);
      expect(flags.skip(9).any((bool f) => f), isFalse);
    });

    test('分块时台词标记跨块延续', () {
      final List<TtsCastChunk> chunks = chunkTtsCastSection(<TtsPlanSentence>[
        _s(0, 0, '「前半'),
        _s(0, 10, '後半」'),
      ], maxSentences: 1);
      expect(chunks[1].dialogue, <bool>[true]);
    });
  });

  group('说话人索引', () {
    test('规范名 / 别名 → 规范名，大小写不敏感', () {
      expect(_index.resolve('スバル'), 'スバル');
      expect(_index.resolve(' 菜月昴 '), 'スバル');
      expect(_index.resolve('銀髪の少女'), 'エミリア');
      expect(_index.resolve('rem'), 'Rem');
      expect(_index.resolve('レム'), 'Rem');
    });

    test('表外名字与 unknown → 不明；旁白别名 → 旁白', () {
      expect(_index.resolve('ラム'), kTtsUnknown);
      expect(_index.resolve('unknown'), kTtsUnknown);
      expect(_index.resolve('不明'), kTtsUnknown);
      expect(_index.resolve('Narrator'), kTtsNarrator);
      expect(_index.resolve('地の文'), kTtsNarrator);
      expect(_index.canonicalOf('ラム'), isNull);
    });

    test('别名撞上别人的规范名时规范名优先', () {
      final TtsCastSpeakerIndex index = TtsCastSpeakerIndex(
        const <TtsCastCharacter>[
          TtsCastCharacter(name: 'A', aliases: <String>['B']),
          TtsCastCharacter(name: 'B'),
        ],
      );
      expect(index.resolve('B'), 'B');
    });
  });

  group('第一遍：角色表', () {
    test('提示词带完整角色表与不编号的正文', () {
      final String prompt = buildTtsRosterUserPrompt(
        _chunk(<TtsPlanSentence>[_s(0, 0, '「おはよう」'), _s(0, 9, 'とエミリアは\n言った。')]),
        roster: _roster,
      );
      expect(
        prompt,
        contains('- スバル | aliases: 菜月昴、スバルくん | male | teen | 口数の多い少年\n'),
      );
      expect(prompt, contains('- エミリア | aliases: 銀髪の少女 | female\n'));
      expect(prompt, contains('[passage]\n「おはよう」\nとエミリアは 言った。\n'));
      expect(prompt, isNot(contains('1: ')));
    });

    test('空角色表写明 empty', () {
      final String prompt = buildTtsRosterUserPrompt(
        _chunk(<TtsPlanSentence>[_s(0, 0, 'x')]),
        roster: const <TtsCastCharacter>[],
      );
      expect(prompt, contains('[current cast list]\n(empty)\n'));
    });

    test('系统提示：操作种类、原文字形、规范名 + 别名', () {
      expect(kTtsRosterSystemPrompt, contains('ONLY a JSON array'));
      expect(kTtsRosterSystemPrompt, contains('"op":"merge"'));
      expect(kTtsRosterSystemPrompt, contains('original script'));
      expect(kTtsRosterSystemPrompt, contains('One canonical name'));
    });

    test('解析 add / update / merge，校验性别年龄、去重别名、丢弃坏元素', () {
      final TtsRosterParseResult? r = parseTtsRosterReply('''
```json
[{"op":"add","name":"エミリア","aliases":["エミリアたん","エミリア"," エミリアたん ","",3],"gender":"Female","age":"teen","desc":"優しい"},
 {"op":"update","name":"スバル","gender":"unknown","age":"old"},
 {"op":"merge","name":"昴","into":"スバル"},
 {"op":"merge","name":"昴"},
 {"op":"merge","name":"スバル","into":"スバル"},
 {"op":"delete","name":"X"},
 {"op":"add","name":"unknown"},
 {"op":"add","name":""},
 "junk"]
```''');
      expect(r, isNotNull);
      expect(r!.rawCount, 9);
      expect(r.looping, isFalse);
      expect(r.ops.length, 3);
      final TtsRosterOp add = r.ops[0];
      expect(add.kind, TtsRosterOpKind.add);
      expect(add.aliases, <String>['エミリアたん']);
      expect(add.gender, 'female');
      expect(add.age, 'teen');
      expect(add.description, '優しい');
      expect(r.ops[1].kind, TtsRosterOpKind.update);
      expect(r.ops[1].gender, isNull);
      expect(r.ops[1].age, isNull);
      expect(r.ops[2].kind, TtsRosterOpKind.merge);
      expect(r.ops[2].name, '昴');
      expect(r.ops[2].into, 'スバル');
    });

    test('空数组可解析；没有数组返回 null；大量重复判复读', () {
      expect(parseTtsRosterReply('[]')!.ops, isEmpty);
      expect(parseTtsRosterReply('none'), isNull);
      final String repeated = List<String>.filled(
        30,
        '{"op":"add","name":"A"}',
      ).join(',');
      expect(parseTtsRosterReply('[$repeated]')!.looping, isTrue);
      final String many = <String>[
        for (int i = 0; i < 100; i++) '{"op":"add","name":"N$i"}',
      ].join(',');
      expect(parseTtsRosterReply('[$many]')!.looping, isTrue);
    });

    test('应用：新增、别名命中按更新处理、不覆盖已有特征', () {
      final TtsCast cast = TtsCast(
        roster: <String, TtsCastCharacter>{
          'スバル': const TtsCastCharacter(
            name: 'スバル',
            aliases: <String>['菜月昴'],
            gender: 'male',
          ),
        },
      );
      applyTtsRosterOps(cast, const <TtsRosterOp>[
        TtsRosterOp(
          kind: TtsRosterOpKind.add,
          name: 'エミリア',
          aliases: <String>['銀髪の少女'],
          gender: 'female',
        ),
        TtsRosterOp(
          kind: TtsRosterOpKind.add,
          name: '菜月昴',
          aliases: <String>['スバルくん'],
          gender: 'female',
          age: 'teen',
        ),
      ]);
      expect(cast.roster.keys, <String>['スバル', 'エミリア']);
      final TtsCastCharacter subaru = cast.roster['スバル']!;
      expect(subaru.aliases, <String>['菜月昴', 'スバルくん']);
      expect(subaru.gender, 'male');
      expect(subaru.age, 'teen');
      expect(cast.roster['エミリア']!.aliases, <String>['銀髪の少女']);
    });

    test('应用：属于别人的别名不悄悄并人', () {
      final TtsCast cast = TtsCast(
        roster: <String, TtsCastCharacter>{
          'エミリア': const TtsCastCharacter(name: 'エミリア'),
          'スバル': const TtsCastCharacter(
            name: 'スバル',
            aliases: <String>['スバルくん'],
          ),
        },
      );
      applyTtsRosterOps(cast, const <TtsRosterOp>[
        TtsRosterOp(
          kind: TtsRosterOpKind.update,
          name: 'エミリア',
          aliases: <String>['スバルくん', 'スバル', 'エミリアたん'],
        ),
      ]);
      expect(cast.roster['エミリア']!.aliases, <String>['エミリアたん']);
    });

    test('应用 merge：台词、声音、角色表一起并，旧名成为别名', () {
      final TtsCast cast = TtsCast(
        roster: <String, TtsCastCharacter>{
          'スバル': const TtsCastCharacter(name: 'スバル'),
          '少年': const TtsCastCharacter(name: '少年', aliases: <String>['黒髪の少年']),
        },
        lines: <String, TtsCastLine>{
          '0:0': const TtsCastLine(speaker: '少年', source: TtsCastSource.llm),
        },
        voices: <String, String>{'少年': 'v1'},
      );
      applyTtsRosterOps(cast, const <TtsRosterOp>[
        TtsRosterOp(kind: TtsRosterOpKind.merge, name: '黒髪の少年', into: 'スバル'),
      ]);
      expect(cast.roster.keys, <String>['スバル']);
      expect(cast.roster['スバル']!.aliases.toSet(), <String>{'少年', '黒髪の少年'});
      expect(cast.speakerOf(0, 0), 'スバル');
      expect(cast.voices, <String, String>{'スバル': 'v1'});
    });

    test('应用 merge：into 不在表里忽略；表外的旧名记成别名并迁台词', () {
      final TtsCast cast = TtsCast(
        roster: <String, TtsCastCharacter>{
          'スバル': const TtsCastCharacter(name: 'スバル'),
        },
        lines: <String, TtsCastLine>{
          '0:0': const TtsCastLine(speaker: '昴', source: TtsCastSource.llm),
        },
      );
      applyTtsRosterOps(cast, const <TtsRosterOp>[
        TtsRosterOp(kind: TtsRosterOpKind.merge, name: 'スバル', into: 'ラム'),
        TtsRosterOp(kind: TtsRosterOpKind.merge, name: '昴', into: 'スバル'),
      ]);
      expect(cast.roster.keys, <String>['スバル']);
      expect(cast.roster['スバル']!.aliases, <String>['昴']);
      expect(cast.speakerOf(0, 0), 'スバル');
    });
  });

  group('第二遍：逐句归属', () {
    test('提示词：角色表（无人设）、滚动上下文、编号与上下文', () {
      final String prompt = buildTtsCastLinesUserPrompt(
        _chunk(
          <TtsPlanSentence>[_s(1, 10, '「おはよう」'), _s(1, 20, 'と彼女は\n言った。')],
          before: <TtsPlanSentence>[_s(1, 0, '前の文。')],
          after: <TtsPlanSentence>[_s(1, 40, '後の文。')],
        ),
        roster: _roster,
        recent: const <TtsCastRecentLine>[
          (speaker: 'スバル', text: '「よう」'),
          (speaker: kTtsUnknown, text: '「誰？」'),
        ],
      );
      expect(prompt, contains('- スバル | aliases: 菜月昴、スバルくん | male | teen\n'));
      expect(prompt, isNot(contains('口数の多い少年')));
      expect(
        prompt,
        contains(
          '[already attributed, just before]\nスバル: 「よう」\nunknown: 「誰？」\n',
        ),
      );
      expect(prompt, isNot(contains(kTtsUnknown)));
      expect(prompt, contains('context: 前の文。'));
      expect(prompt, contains('1: 「おはよう」\n2: と彼女は 言った。\n'));
      expect(prompt, contains('context: 後の文。'));
      expect(prompt, contains('lines 1-2 only'));
      expect(
        prompt.indexOf('already attributed') < prompt.indexOf('1: 「おはよう」'),
        isTrue,
      );
    });

    test('提示词：空角色表提示全部 unknown；没有滚动上下文时不出现那一节', () {
      final String prompt = buildTtsCastLinesUserPrompt(
        _chunk(<TtsPlanSentence>[_s(0, 0, '「あ」')]),
        roster: const <TtsCastCharacter>[],
        recent: const <TtsCastRecentLine>[],
      );
      expect(prompt, contains('use "unknown" for every dialogue line'));
      expect(prompt, isNot(contains('already attributed')));
      expect(prompt, isNot(contains('context')));
    });

    test('系统提示：只能从角色表选人、unknown、把握与依据', () {
      expect(kTtsCastLinesSystemPrompt, contains('ONLY a JSON array'));
      expect(
        kTtsCastLinesSystemPrompt,
        contains('Never use a name that is not'),
      );
      expect(kTtsCastLinesSystemPrompt, contains('"unknown"'));
      expect(kTtsCastLinesSystemPrompt, contains('"ev"'));
      expect(kTtsCastLinesSystemPrompt, contains('「…」とスバルは言った'));
    });

    test('解析：别名 → 规范名、表外名字 → 不明、把握与依据', () {
      final TtsCastParseResult? r = parseTtsCastReply(
        '[{"i":1,"s":"菜月昴","e":"怒り","c":0.9,"ev":"explicit"},'
        '{"i":2,"s":"ラム","c":"0.8","ev":"anaphoric"},'
        '{"i":3,"s":"unknown","c":0.1,"ev":"implicit"},'
        '{"i":4,"s":"エミリア","c":7,"ev":"guess"},'
        '{"i":5,"s":"narrator","e":"x","c":0.5,"ev":"explicit"}]',
        5,
        speakers: _index,
      );
      expect(r, isNotNull);
      expect(r!.looping, isFalse);
      expect(
        r.labels.map(
          (TtsCastLabel l) =>
              (l.index, l.speaker, l.emotion, l.confidence, l.evidence),
        ),
        <(int, String, String?, double?, TtsCastEvidence?)>[
          (1, 'スバル', '怒り', 0.9, TtsCastEvidence.explicit),
          (2, kTtsUnknown, null, 0.8, TtsCastEvidence.anaphoric),
          (3, kTtsUnknown, null, 0.1, TtsCastEvidence.implicit),
          (4, 'エミリア', null, 1.0, null),
          (5, kTtsNarrator, null, null, null),
        ],
      );
    });

    test('解析：剥围栏与多余文字、字符串里的括号不打乱配对', () {
      final TtsCastParseResult? r = parseTtsCastReply(
        'Here [see below]:\n```json\n[{"i":2,"s":"レム","e":"\\"笑\\" [小声]"}]\n```\nDone.',
        2,
        speakers: _index,
      );
      expect(r!.labels.single.speaker, 'Rem');
      expect(r.labels.single.index, 2);
      expect(r.labels.single.emotion, '"笑" [小声]');
    });

    test('解析：越界 / 非法 / 重复编号丢弃', () {
      final TtsCastParseResult? r = parseTtsCastReply(
        '[{"i":0,"s":"スバル"},{"i":4,"s":"スバル"},{"i":"2","s":"Rem"},'
        '{"i":2,"s":"エミリア"},{"i":3.0,"s":"スバル"},{"i":1.5,"s":"スバル"},'
        '{"s":"スバル"},"junk",{"i":1,"s":"  "},{"i":1,"s":7}]',
        3,
        speakers: _index,
      );
      expect(r!.rawCount, 10);
      expect(
        r.labels.map((TtsCastLabel l) => '${l.index}${l.speaker}'),
        <String>['2Rem', '3スバル'],
      );
    });

    test('解析：空数组可解析；没有数组 / 坏 JSON / 截断返回 null', () {
      final TtsCastParseResult? empty = parseTtsCastReply(
        '[]',
        5,
        speakers: _index,
      );
      expect(empty!.labels, isEmpty);
      expect(empty.rawCount, 0);
      for (final String bad in <String>[
        '',
        'no dialogue here',
        '[{"i":1,"s":"A"',
        '{"i":1,"s":"A"}',
      ]) {
        expect(
          parseTtsCastReply(bad, 5, speakers: _index),
          isNull,
          reason: bad,
        );
      }
    });

    test('解析：远超行数的数组 / 大量逐字重复判复读', () {
      final String repeated = List<String>.filled(
        40,
        '{"i":1,"s":"スバル"}',
      ).join(',');
      expect(
        parseTtsCastReply('[$repeated]', 30, speakers: _index)!.looping,
        isTrue,
      );
      final String many = <String>[
        for (int i = 1; i <= 30; i++) '{"i":$i,"s":"スバル"}',
      ].join(',');
      expect(
        parseTtsCastReply('[$many]', 9, speakers: _index)!.looping,
        isTrue,
      );
      expect(
        parseTtsCastReply('[$many]', 30, speakers: _index)!.looping,
        isFalse,
      );
    });

    test('行标注：没回的台词行 → 不明 + 零把握，没回的旁白行 → 旁白', () {
      final TtsCastChunk chunk = _chunk(<TtsPlanSentence>[
        _s(3, 0, '「あ」'),
        _s(3, 5, '地の文。'),
        _s(3, 9, '「い」'),
        _s(3, 14, '「う」'),
      ]);
      final Map<String, TtsCastLine> lines =
          ttsCastLinesForChunk(chunk, const <TtsCastLabel>[
            TtsCastLabel(
              index: 1,
              speaker: 'スバル',
              emotion: '驚き',
              confidence: 0.9,
              evidence: TtsCastEvidence.explicit,
            ),
            TtsCastLabel(index: 4, speaker: kTtsNarrator),
          ]);
      expect(lines.keys, <String>['3:0', '3:5', '3:9', '3:14']);
      expect(lines['3:0']!.speaker, 'スバル');
      expect(lines['3:0']!.emotion, '驚き');
      expect(lines['3:0']!.confidence, 0.9);
      expect(lines['3:0']!.evidence, TtsCastEvidence.explicit);
      expect(lines['3:0']!.needsReview, isFalse);
      expect(lines['3:5']!.speaker, kTtsNarrator);
      expect(lines['3:9']!.speaker, kTtsUnknown);
      expect(lines['3:9']!.confidence, 0);
      expect(lines['3:9']!.needsReview, isTrue);
      expect(lines['3:14']!.speaker, kTtsNarrator);
      expect(
        lines.values.every((TtsCastLine l) => l.source == TtsCastSource.llm),
        isTrue,
      );
    });

    test('滚动上下文：上一块最后几句非旁白行，按原顺序', () {
      final List<TtsPlanSentence> sentences = <TtsPlanSentence>[
        for (int i = 0; i < 10; i++) _s(0, i * 10, '「台詞$i」'),
        _s(0, 100, '地の文。'),
      ];
      final TtsCastChunk chunk = _chunk(sentences);
      final Map<String, TtsCastLine> lines = <String, TtsCastLine>{
        for (int i = 0; i < 10; i++)
          ttsLineKey(0, i * 10): TtsCastLine(
            speaker: i == 9 ? kTtsUnknown : (i.isEven ? 'スバル' : 'エミリア'),
            source: TtsCastSource.llm,
          ),
        ttsLineKey(0, 100): const TtsCastLine(
          speaker: kTtsNarrator,
          source: TtsCastSource.llm,
        ),
      };
      final List<TtsCastRecentLine> recent = ttsCastRecentDialogue(
        chunk,
        lines,
      );
      expect(recent.length, kTtsCastRecentDialogue);
      expect(recent.map((TtsCastRecentLine r) => r.text).first, '「台詞4」');
      expect(recent.last, (speaker: kTtsUnknown, text: '「台詞9」'));
      expect(recent[recent.length - 2], (speaker: 'スバル', text: '「台詞8」'));
      expect(recent[recent.length - 3], (speaker: 'エミリア', text: '「台詞7」'));
    });
  });
}
