import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_consistency_pass.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:path/path.dart' as p;

import '../../../../helpers/fake_ai_text_completer.dart';

/// S4 写法统一：可疑写法的抽取（含子串误报防护与原阈值）、疑似唱段、只送被标出
/// 的行、全 id 覆盖与缓存。
void main() {
  const SubtitleGlossaryEntry lucifer = SubtitleGlossaryEntry(
    ja: 'ルシファー',
    reading: 'るしふぁー',
    kind: '人名',
  );
  const SubtitleGlossaryEntry yui = SubtitleGlossaryEntry(
    ja: '唯',
    reading: 'ゆい',
    kind: '人名(平沢唯の名)',
    misrecognitions: <String>['結衣'],
  );

  group('levenshteinDistance', () {
    test('按码点计', () {
      expect(levenshteinDistance('', ''), 0);
      expect(levenshteinDistance('abc', ''), 3);
      expect(levenshteinDistance('kitten', 'sitting'), 3);
      expect(levenshteinDistance('ルシファ', 'ルシファー'), 1);
      expect(levenshteinDistance('レヴィ', 'レビィ'), 1);
      expect(levenshteinDistance('𠮷野', '吉野'), 1);
    });
  });

  group('subtitleConsistencySuspects', () {
    test('正式写法先抹掉：「ルシファー」里的「ルシファ」不报', () {
      expect(
        subtitleConsistencySuspects('ルシファーが来た', <SubtitleGlossaryEntry>[
          lucifer,
        ]),
        isEmpty,
      );
    });

    test('片假名名字只差 1 字：报', () {
      expect(
        subtitleConsistencySuspects('ルシファが来た', <SubtitleGlossaryEntry>[
          lucifer,
        ]),
        <String>['ルシファ→ルシファー?'],
      );
      expect(
        subtitleConsistencySuspects('ルシフォーだ', <SubtitleGlossaryEntry>[lucifer]),
        <String>['ルシフォー→ルシファー?'],
      );
    });

    test('读音同形（平假名 / 片假名）与已知误写：报', () {
      expect(
        subtitleConsistencySuspects('ゆいちゃん', <SubtitleGlossaryEntry>[yui]),
        <String>['ゆい→唯?'],
      );
      expect(
        subtitleConsistencySuspects('ユイ先輩', <SubtitleGlossaryEntry>[yui]),
        <String>['ユイ→唯?'],
      );
      expect(
        subtitleConsistencySuspects('結衣がね', <SubtitleGlossaryEntry>[yui]),
        <String>['結衣→唯?'],
      );
      expect(
        subtitleConsistencySuspects('唯がね', <SubtitleGlossaryEntry>[yui]),
        isEmpty,
      );
    });

    test('阈值：读音 / 误写 <2 字不用；片假名正式写法 <3 字不做编辑距离', () {
      const SubtitleGlossaryEntry shortReading = SubtitleGlossaryEntry(
        ja: '戸',
        reading: 'と',
        kind: '人名',
        misrecognitions: <String>['ト'],
      );
      expect(
        subtitleConsistencySuspects('とトと', <SubtitleGlossaryEntry>[
          shortReading,
        ]),
        isEmpty,
      );
      const SubtitleGlossaryEntry mugi = SubtitleGlossaryEntry(
        ja: 'ムギ',
        kind: '人名',
      );
      expect(
        subtitleConsistencySuspects('ムダだ', <SubtitleGlossaryEntry>[mugi]),
        isEmpty,
      );
    });

    test('一个正式写法不是另一个的变体', () {
      const SubtitleGlossaryEntry levi = SubtitleGlossaryEntry(
        ja: 'レヴィ',
        kind: '人名',
        misrecognitions: <String>['レビィ'],
      );
      const SubtitleGlossaryEntry levia = SubtitleGlossaryEntry(
        ja: 'レヴィア',
        kind: '人名',
      );
      // 「レヴィア」是表里的正式写法：不因与「レヴィ」差 1 字被报。
      expect(
        subtitleConsistencySuspects('レヴィアとレヴィ', <SubtitleGlossaryEntry>[
          levi,
          levia,
        ]),
        isEmpty,
      );
    });
  });

  group('subtitleLyricLike', () {
    List<SubtitleDraftCue> run({
      int gapMs = 300,
      String text = '夢の中へ',
      List<String?>? speakers,
    }) => <SubtitleDraftCue>[
      for (int i = 0; i < 7; i++)
        SubtitleDraftCue(
          startMs: i * (1500 + gapMs),
          endMs: i * (1500 + gapMs) + 1500,
          text: text,
          speaker: speakers?[i],
        ),
    ];

    test('7 行窗口内 ≥6 条 ≤14 字、说话人 ≤1、间隔 <0.8 s', () {
      expect(subtitleLyricLike(run(), 3), isTrue);
      expect(subtitleLyricLike(run(gapMs: 800), 3), isFalse);
      expect(
        subtitleLyricLike(run(text: 'これはとても長い台詞なので歌詞ではないと思う'), 3),
        isFalse,
      );
      expect(
        subtitleLyricLike(
          run(speakers: <String?>['A', 'A', 'A', 'B', 'A', 'A', 'A']),
          3,
        ),
        isFalse,
      );
      // 窗口不足 6 行（只有 5 行）。
      expect(subtitleLyricLike(run().sublist(0, 5), 2), isFalse);
    });
  });

  group('SubtitleConsistencyPass', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('s4_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    final List<SubtitleDraftCue> cues = <SubtitleDraftCue>[
      for (int i = 0; i < 10; i++)
        SubtitleDraftCue(
          startMs: i * 5000,
          endMs: i * 5000 + 2000,
          text: i == 4 ? '結衣が来た' : 'これはごく普通の台詞の行です$i',
        ),
    ];
    const SubtitleGlossary glossary = SubtitleGlossary(
      entries: <SubtitleGlossaryEntry>[yui],
    );

    test('只送被标出的行 + 前后 2 行；结果统一写法并缓存，续跑不再请求', () async {
      final FakeAiCompleter ai = FakeAiCompleter(
        (String prompt, int call) => replyForIds(prompt, (int id) => '唯が来た!'),
      );
      final File cache = File(p.join(tmp.path, 'consistency.json'));
      final SubtitleConsistencyResult r = await SubtitleConsistencyPass(
        completer: ai,
      ).run(cues: cues, title: 'けいおん!!', glossary: glossary, cacheFile: cache);
      expect(ai.calls, 1);
      expect(targetIdsOf(ai.prompts.single), <int>[4]);
      expect(
        ai.prompts.single,
        contains(
          'id=4 前: これはごく普通の台詞の行です2 / これはごく普通の台詞の行です3\n'
          '  対象: 結衣が来た\n'
          '  後: これはごく普通の台詞の行です5 / これはごく普通の台詞の行です6\n'
          '  疑い: 結衣→唯?',
        ),
      );
      expect(ai.prompts.single, contains('唯(ゆい) 人名(平沢唯の名)'));
      expect(r.flaggedCount, 1);
      expect(r.changedCount, 1);
      expect(r.cues[4].text, '唯が来た！');
      expect(cache.existsSync(), isTrue);

      final ExplodingAiCompleter again = ExplodingAiCompleter();
      final SubtitleConsistencyResult r2 = await SubtitleConsistencyPass(
        completer: again,
      ).run(cues: cues, title: 'けいおん!!', glossary: glossary, cacheFile: cache);
      expect(again.calls, 0);
      expect(r2.cues[4].text, '唯が来た！');
    });

    test('回复缺 id：重试 3 次后报错，不写缓存', () async {
      final FakeAiCompleter ai = FakeAiCompleter(
        (String prompt, int call) => '{"99": "x"}',
      );
      final File cache = File(p.join(tmp.path, 'consistency.json'));
      await expectLater(
        SubtitleConsistencyPass(
          completer: ai,
        ).run(cues: cues, title: 't', glossary: glossary, cacheFile: cache),
        throwsA(isA<SubtitleAiRequestFailure>()),
      );
      expect(ai.calls, 3);
      expect(cache.existsSync(), isFalse);
    });

    test('没有被标出的行：不请求，写一份空缓存标记完成', () async {
      final ExplodingAiCompleter ai = ExplodingAiCompleter();
      final File cache = File(p.join(tmp.path, 'consistency.json'));
      final SubtitleConsistencyResult r =
          await SubtitleConsistencyPass(completer: ai).run(
            cues: cues
                .where((SubtitleDraftCue c) => !c.text.contains('結衣'))
                .toList(),
            title: 't',
            glossary: glossary,
            cacheFile: cache,
          );
      expect(ai.calls, 0);
      expect(r.flaggedCount, 0);
      expect(cache.existsSync(), isTrue);
    });

    test('疑似唱段被标出，AI 加 ♪', () async {
      final List<SubtitleDraftCue> song = <SubtitleDraftCue>[
        for (int i = 0; i < 7; i++)
          SubtitleDraftCue(
            startMs: i * 1800,
            endMs: i * 1800 + 1500,
            text: '夢の中へ$i',
          ),
      ];
      final FakeAiCompleter ai = FakeAiCompleter(
        (String prompt, int call) =>
            replyForIds(prompt, (int id) => '♪${song[id].text}'),
      );
      final SubtitleConsistencyResult r =
          await SubtitleConsistencyPass(completer: ai).run(
            cues: song,
            title: 't',
            glossary: SubtitleGlossary.empty,
            cacheFile: File(p.join(tmp.path, 'c.json')),
          );
      expect(ai.prompts.single, contains('疑い: 歌詞?'));
      // 首尾两行的 7 行窗口被截短到 <6 行，不算（同基准的弱信号口径）。
      expect(targetIdsOf(ai.prompts.single), <int>[2, 3, 4]);
      expect(
        <String>[for (final SubtitleDraftCue c in r.cues) c.text],
        <String>[
          '夢の中へ0',
          '夢の中へ1',
          '♪夢の中へ2',
          '♪夢の中へ3',
          '♪夢の中へ4',
          '夢の中へ5',
          '夢の中へ6',
        ],
      );
    });
  });
}
