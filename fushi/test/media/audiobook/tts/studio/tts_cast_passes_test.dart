import 'dart:convert';

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
      return (
        text: system.startsWith('You build the cast list')
            ? rosterReply
            : linesReply,
        truncated: false,
      );
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
        ttsRosterSystemPrompt(TtsCastScript.japanese),
        ttsCastLinesSystemPrompt(TtsCastScript.japanese),
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

  group('BUG-5366', () {
    test('中文书两遍都用中文示例的提示词', () async {
      final ({TtsCast cast, int saves, List<String> systems}) r = await _run(
        sentences: <TtsPlanSentence>[
          _s(4, 0, '戰場原黑儀回過頭來。'),
          _s(4, 20, '「阿良良木同學。」'),
        ],
        rosterReply: '[{"op":"add","name":"戰場原黑儀"}',
        linesReply: '[{"i":2,"s":"戰場原黑儀"}',
      );
      expect(r.systems, <String>[
        ttsRosterSystemPrompt(TtsCastScript.chinese),
        ttsCastLinesSystemPrompt(TtsCastScript.chinese),
      ]);
      expect(r.cast.roster.keys, contains('戰場原黑儀'));
      expect(r.cast.lines[ttsLineKey(4, 20)]?.speaker, '戰場原黑儀');
    });

    test('bad_output 带上模型原始回复，进错误日志的文本里有它', () async {
      Object? error;
      try {
        await _run(
          sentences: <TtsPlanSentence>[_s(5, 0, '「行くぞ」')],
          rosterReply: 'I cannot help with that.',
          linesReply: '[]',
        );
      } on TtsCastAnnotateFailure catch (e) {
        error = e;
      }
      final TtsCastAnnotateFailure failure = error! as TtsCastAnnotateFailure;
      expect(failure.code, 'bad_output');
      expect(failure.detail, 'roster, section 5: no JSON array');
      expect(failure.reply, 'I cannot help with that.');
      expect(failure.toString(), contains('I cannot help with that.'));
    });
  });
  group('BUG-5369', () {
    /// 第 9 章 100 句：偶数句旁白、奇数句台词，正文各不相同；一块装得下。
    final List<TtsPlanSentence> book = <TtsPlanSentence>[
      for (int i = 0; i < 100; i++)
        _s(9, i * 20, i.isEven ? '地の文$i。' : '「台詞$i」'),
    ];
    final Map<String, int> indexOf = <String, int>{
      for (int i = 0; i < book.length; i++) book[i].text: i,
    };

    /// 用户提示词里 [header] 下、空行前的各行。
    List<String> section(String user, String header) {
      final List<String> lines = user.split('\n');
      final int at = lines.indexOf(header);
      if (at < 0) return const <String>[];
      return lines.skip(at + 1).takeWhile((String l) => l.isNotEmpty).toList();
    }

    /// 第二遍一块要标的句子（按全书下标）。
    List<int> labelled(String user) => <int>[
      for (final String l in section(user, '[lines to label]'))
        indexOf[l.substring(l.indexOf(': ') + 2)]!,
    ];

    /// 跑两遍：块超过 [maxRoster] / [maxLines] 句就回截断（正文 [cut]），否则第一遍
    /// 登记一个角色、第二遍把所有台词行归给「A」。
    Future<({TtsCast cast, List<List<int>> leaves, List<String> users})> run({
      int maxRoster = 1000,
      int maxLines = 1000,
      String cut = '',
    }) async {
      final TtsCast cast = TtsCast();
      final List<List<int>> leaves = <List<int>>[];
      final List<String> users = <String>[];
      await runTtsCastPasses(
        cast: cast,
        bySection: <int, List<TtsPlanSentence>>{9: book},
        todo: const <int>[9],
        substitutions: const <CastTextSubstitution>[],
        ask: (String system, String user) async {
          if (system.startsWith('You build the cast list')) {
            final int n = section(user, '[passage]').length;
            if (n > maxRoster) return (text: cut, truncated: true);
            return (text: '[{"op":"add","name":"A"}]', truncated: false);
          }
          final List<int> lines = labelled(user);
          if (lines.length > maxLines) return (text: cut, truncated: true);
          leaves.add(lines);
          users.add(user);
          return (
            text: jsonEncode(<Object?>[
              for (int k = 0; k < lines.length; k++)
                if (lines[k].isOdd) <String, Object?>{'i': k + 1, 's': 'A'},
            ]),
            truncated: false,
          );
        },
        save: () async {},
        onProgress: (int done, int total) {},
        isCancelled: () => false,
      );
      return (cast: cast, leaves: leaves, users: users);
    }

    void expectAllLabelled(TtsCast cast) {
      expect(cast.annotatedSections, <int>{9});
      for (int i = 0; i < book.length; i++) {
        expect(
          cast.lines[ttsLineKey(9, i * 20)]?.speaker,
          i.isOdd ? 'A' : kTtsNarrator,
          reason: 'sentence $i',
        );
      }
    }

    test('第二遍 100 句一块回空正文截断：拆半重问到装得下，按序标全，滚动上下文接得上', () async {
      final ({TtsCast cast, List<List<int>> leaves, List<String> users}) r =
          await run(maxLines: 30);
      expectAllLabelled(r.cast);
      // 100 → 50 → 25：叶子块按原顺序首尾相接，覆盖整章。
      expect(r.leaves.length, greaterThan(1));
      expect(r.leaves.every((List<int> l) => l.length <= 30), isTrue);
      expect(r.leaves.expand((List<int> l) => l).toList(), <int>[
        for (int i = 0; i < 100; i++) i,
      ]);
      for (int k = 1; k < r.leaves.length; k++) {
        final int first = r.leaves[k].first;
        // 后一块看得到前一块刚归属的台词，和紧挨着的前文。
        final int lastSpoken = first.isOdd ? first - 2 : first - 1;
        expect(
          section(r.users[k], '[already attributed, just before]'),
          contains('A: ${book[lastSpoken].text}'),
        );
        expect(
          section(r.users[k], '[context before]'),
          contains('context: ${book[first - 1].text}'),
        );
      }
    });

    test('截断的前半截不拿来补救，同样拆块重问', () async {
      final ({TtsCast cast, List<List<int>> leaves, List<String> users}) r =
          await run(maxLines: 30, cut: '[{"i":1,"s":"B"},{"i":2,');
      expectAllLabelled(r.cast);
      expect(r.cast.roster.keys, isNot(contains('B')));
    });

    test('第一遍截断也拆半：后一半看得到前一半刚登记的角色', () async {
      final List<String> rosterUsers = <String>[];
      final TtsCast cast = TtsCast();
      await runTtsCastPasses(
        cast: cast,
        bySection: <int, List<TtsPlanSentence>>{9: book},
        todo: const <int>[9],
        substitutions: const <CastTextSubstitution>[],
        ask: (String system, String user) async {
          if (!system.startsWith('You build the cast list')) {
            return (text: '[]', truncated: false);
          }
          if (section(user, '[passage]').length > 60) {
            return (text: '', truncated: true);
          }
          rosterUsers.add(user);
          return (
            text: '[{"op":"add","name":"R${rosterUsers.length}"}]',
            truncated: false,
          );
        },
        save: () async {},
        onProgress: (int done, int total) {},
        isCancelled: () => false,
      );
      expect(rosterUsers, hasLength(2));
      expect(cast.roster.keys, containsAll(<String>['R1', 'R2']));
      expect(
        section(rosterUsers[0], '[passage]').length +
            section(rosterUsers[1], '[passage]').length,
        100,
      );
      expect(
        section(rosterUsers[1], '[current cast list]').join('\n'),
        contains('R1'),
      );
      expect(cast.annotatedSections, <int>{9});
    });

    test('拆到下限仍截断：报 output_limit，不并入半成品', () async {
      Object? error;
      final TtsCast cast = TtsCast();
      try {
        await runTtsCastPasses(
          cast: cast,
          bySection: <int, List<TtsPlanSentence>>{9: book},
          todo: const <int>[9],
          substitutions: const <CastTextSubstitution>[],
          ask: (String system, String user) async =>
              system.startsWith('You build the cast list')
              ? (text: '[]', truncated: false)
              : (text: '', truncated: true),
          save: () async {},
          onProgress: (int done, int total) {},
          isCancelled: () => false,
        );
      } on TtsCastAnnotateFailure catch (e) {
        error = e;
      }
      final TtsCastAnnotateFailure failure = error! as TtsCastAnnotateFailure;
      expect(failure.code, kTtsCastFailureOutputLimit);
      final RegExpMatch m = RegExp(
        r'^lines, section 9: (\d+) sentences$',
      ).firstMatch(failure.detail!)!;
      expect(
        int.parse(m.group(1)!),
        lessThanOrEqualTo(kTtsCastSplitMinSentences),
      );
      expect(failure.reply, isNull);
      expect(cast.annotatedSections, isEmpty);
    });

    test('第一遍拆到下限仍截断：报 output_limit（roster），带上截断的前半截', () async {
      await expectLater(
        run(maxRoster: 0, cut: '[{"op":'),
        throwsA(
          isA<TtsCastAnnotateFailure>()
              .having(
                (TtsCastAnnotateFailure f) => f.code,
                'code',
                kTtsCastFailureOutputLimit,
              )
              .having(
                (TtsCastAnnotateFailure f) => f.detail,
                'detail',
                startsWith('roster, section 9: '),
              )
              .having(
                (TtsCastAnnotateFailure f) => f.reply,
                'reply',
                '[{"op":',
              ),
        ),
      );
    });
  });

  group('splitTtsCastChunk', () {
    test('按字数对半拆，上下文取自原块前后文与另一半，台词标记跟着走', () {
      final List<TtsPlanSentence> all = <TtsPlanSentence>[
        for (int i = 0; i < 20; i++)
          _s(1, i * 10, i.isOdd ? '「${i + 10}」' : '文${i + 10}。'),
      ];
      final TtsCastChunk chunk = chunkTtsCastSection(
        all.sublist(0, 16),
        maxSentences: 12,
      ).first;
      final (TtsCastChunk head, TtsCastChunk tail) = splitTtsCastChunk(chunk)!;
      expect(<TtsPlanSentence>[
        ...head.sentences,
        ...tail.sentences,
      ], chunk.sentences);
      expect(head.sentences.length, 6);
      expect(head.before, chunk.before);
      expect(head.after, all.sublist(6, 6 + kTtsCastContextSentences));
      expect(tail.before, all.sublist(6 - kTtsCastContextSentences, 6));
      expect(tail.after, chunk.after);
      expect(<bool>[...head.dialogue, ...tail.dialogue], chunk.dialogue);

      final (TtsCastChunk rHead, TtsCastChunk rTail) = splitTtsCastChunk(
        chunk,
        contextSentences: 0,
      )!;
      expect(rHead.before, isEmpty);
      expect(rHead.after, isEmpty);
      expect(rTail.before, isEmpty);
      expect(rTail.after, isEmpty);
      expect(
        splitTtsCastChunk(
          TtsCastChunk(
            sentences: all.sublist(0, 1),
            before: const <TtsPlanSentence>[],
            after: const <TtsPlanSentence>[],
          ),
        ),
        isNull,
      );
    });
  });
}
