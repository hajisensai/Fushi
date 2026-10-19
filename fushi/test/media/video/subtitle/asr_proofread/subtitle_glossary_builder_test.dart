import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_builder.dart';

import '../../../../helpers/fake_ai_text_completer.dart';

/// S0 专名表：身份校验（错作品 2/40 → 重做；对的 14/21 通过）、矛盾校验、userEdited
/// 保留、资料没变不重生成、刮削角色日文名作为权威写进提示词。
void main() {
  const SubtitleWorkContext bare = SubtitleWorkContext(
    workKey: 'title:x',
    title: 'sin 七つの大罪',
  );

  String table(List<Map<String, Object?>> rows) => jsonEncode(rows);

  List<Map<String, Object?>> people(String prefix, int n) =>
      <Map<String, Object?>>[
        for (int i = 0; i < n; i++)
          <String, Object?>{'ja': '$prefix$i号', 'kind': '人名'},
      ];

  // 本季 ASR：正解0号..正解13号 被说出；别作品表里只有 别人0号 / 别人1号 偶然出现。
  final List<List<String>> spoken = <List<String>>[
    <String>[
      for (int i = 0; i < 14; i++) '正解$i号がリリスと話す',
      '別人0号と別人1号',
      'ルシファーとリリスとリリス',
    ],
  ];
  final String wrongTable = table(people('別人', 40));
  final String rightTable = table(people('正解', 21));

  test('覆盖率：错作品 2/40 不过，对的 14/21 通过（阈值 35%）', () {
    final String text = spoken.expand((List<String> e) => e).join('\n');
    final ({List<String> hit, List<String> miss}) wrong =
        subtitleGlossaryCoverage(parseSubtitleGlossaryReply(wrongTable)!, text);
    expect(wrong.hit.length, 2);
    expect(wrong.miss.length, 38);
    expect(subtitleGlossaryCoveragePasses(wrong), isFalse);
    final ({List<String> hit, List<String> miss}) right =
        subtitleGlossaryCoverage(parseSubtitleGlossaryReply(rightTable)!, text);
    expect(right.hit.length, 14);
    expect(right.miss.length, 7);
    expect(subtitleGlossaryCoveragePasses(right), isTrue);
  });

  test('身份校验不过：带「没听到的名字 + 实际听到的片假名」重做一次即通过', () async {
    final FakeAiCompleter ai = FakeAiCompleter(
      (String prompt, int call) => call == 0 ? wrongTable : rightTable,
    );
    final SubtitleGlossaryBuildResult r = await SubtitleGlossaryBuilder(
      completer: ai,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1234),
    ).build(context: bare, episodeTexts: spoken);
    expect(ai.calls, 2);
    final String redo = ai.prompts[1];
    expect(redo, contains('別作品の表だった可能性が高い'));
    expect(redo, contains('別人2号、別人3号'));
    expect(redo, contains('音声に実際に多く出てくるカタカナ語: リリス、ルシファー'));
    expect(r.regenerated, isTrue);
    expect(r.heardNames.length, 14);
    expect(r.glossary.entries.length, 21);
    expect(r.glossary.generatedAt, 1234);
    expect(r.glossary.sourceFingerprint, subtitleGlossaryFingerprint(bare));
    // 首次提示词：ASR 抽样只作身份确认。
    expect(ai.prompts[0], contains('作品の特定用の資料(表記の根拠にはしない)'));
    expect(ai.prompts[0], contains('正解0号がリリスと話す'));
  });

  test('两次重做后仍是别的作品：抛 wrongWork，带候选表与明细', () async {
    final FakeAiCompleter ai = FakeAiCompleter(
      (String prompt, int call) => wrongTable,
    );
    await expectLater(
      SubtitleGlossaryBuilder(
        completer: ai,
      ).build(context: bare, episodeTexts: spoken),
      throwsA(
        isA<SubtitleGlossaryValidationFailure>()
            .having(
              (SubtitleGlossaryValidationFailure f) => f.problem,
              'problem',
              SubtitleGlossaryProblem.wrongWork,
            )
            .having(
              (SubtitleGlossaryValidationFailure f) => f.heardNames.length,
              'heard',
              2,
            )
            .having(
              (SubtitleGlossaryValidationFailure f) => f.candidate.length,
              'candidate',
              40,
            ),
      ),
    );
    expect(ai.calls, 3);
  });

  test('矛盾校验：互列为误写 → 带问题清单重做；重做后干净即通过', () async {
    final String conflicting = table(<Map<String, Object?>>[
      <String, Object?>{
        'ja': 'レヴィ',
        'kind': '人名',
        'misrecognitions': <String>['レビィ'],
      },
      <String, Object?>{
        'ja': 'レビィ',
        'kind': '人名',
        'misrecognitions': <String>['レヴィ'],
      },
    ]);
    final String clean = table(<Map<String, Object?>>[
      <String, Object?>{
        'ja': 'レヴィ',
        'kind': '人名',
        'misrecognitions': <String>['レビィ'],
      },
    ]);
    final FakeAiCompleter ai = FakeAiCompleter(
      (String prompt, int call) => call == 0 ? conflicting : clean,
    );
    final SubtitleGlossaryBuildResult r = await SubtitleGlossaryBuilder(
      completer: ai,
    ).build(context: bare, episodeTexts: const <List<String>>[]);
    expect(ai.calls, 2);
    expect(ai.prompts[1], startsWith('アニメ「sin 七つの大罪」の固有名詞表に矛盾があります。'));
    expect(ai.prompts[1], contains('「レビィ」は正式表記の項目でもあるが、「レヴィ」の誤表記にも入っている'));
    expect(r.glossary.entries.single.ja, 'レヴィ');
  });

  test('矛盾一直不消（「要確認」注记）：抛 conflicts', () async {
    final FakeAiCompleter ai = FakeAiCompleter(
      (String prompt, int call) => table(<Map<String, Object?>>[
        <String, Object?>{'ja': 'レヴィー', 'kind': '人名(要確認)'},
      ]),
    );
    await expectLater(
      SubtitleGlossaryBuilder(
        completer: ai,
      ).build(context: bare, episodeTexts: const <List<String>>[]),
      throwsA(
        isA<SubtitleGlossaryValidationFailure>().having(
          (SubtitleGlossaryValidationFailure f) => f.problem,
          'problem',
          SubtitleGlossaryProblem.conflicts,
        ),
      ),
    );
    expect(ai.calls, 3);
  });

  test('回复不是 JSON 数组：重试 3 次后抛 reply_incomplete', () async {
    final FakeAiCompleter ai = FakeAiCompleter(
      (String prompt, int call) => '調べられませんでした',
    );
    await expectLater(
      SubtitleGlossaryBuilder(
        completer: ai,
      ).build(context: bare, episodeTexts: const <List<String>>[]),
      throwsA(
        isA<SubtitleAiRequestFailure>().having(
          (SubtitleAiRequestFailure f) => f.reason,
          'reason',
          kSubtitleAiReplyIncomplete,
        ),
      ),
    );
    expect(ai.calls, 3);
  });

  test('userEdited 条目原样保留、生成的同名条目丢弃；未编辑的旧条目被替换', () async {
    final SubtitleGlossary existing = SubtitleGlossary(
      entries: const <SubtitleGlossaryEntry>[
        SubtitleGlossaryEntry(
          ja: '唯',
          reading: 'ゆい',
          kind: '人名',
          note: '用户写的',
          userEdited: true,
        ),
        SubtitleGlossaryEntry(ja: '律', kind: '人名'),
      ],
      sourceFingerprint: 'old',
      userEditedAt: 99,
    );
    final FakeAiCompleter ai = FakeAiCompleter(
      (String prompt, int call) => table(<Map<String, Object?>>[
        <String, Object?>{'ja': '唯', 'reading': 'ゆいい', 'kind': '人名'},
        <String, Object?>{'ja': '澪', 'reading': 'みお', 'kind': '人名'},
      ]),
    );
    final SubtitleGlossaryBuildResult r =
        await SubtitleGlossaryBuilder(completer: ai).build(
          context: bare,
          episodeTexts: const <List<String>>[],
          existing: existing,
        );
    expect(r.regenerated, isTrue);
    expect(r.glossary.entries.map((SubtitleGlossaryEntry e) => e.ja), <String>[
      '唯',
      '澪',
    ]);
    expect(r.glossary.entries.first.reading, 'ゆい');
    expect(r.glossary.entries.first.note, '用户写的');
    expect(r.glossary.entries.first.userEdited, isTrue);
    expect(r.glossary.userEditedAt, 99);
  });

  test('资料指纹没变且已有表：不调 AI；资料变了才重生成', () async {
    final SubtitleGlossary existing = SubtitleGlossary(
      entries: const <SubtitleGlossaryEntry>[SubtitleGlossaryEntry(ja: '唯')],
      sourceFingerprint: subtitleGlossaryFingerprint(bare),
    );
    final ExplodingAiCompleter none = ExplodingAiCompleter();
    final SubtitleGlossaryBuildResult same = await SubtitleGlossaryBuilder(
      completer: none,
    ).build(context: bare, episodeTexts: spoken, existing: existing);
    expect(none.calls, 0);
    expect(same.regenerated, isFalse);
    expect(identical(same.glossary, existing), isTrue);

    const SubtitleWorkContext scraped = SubtitleWorkContext(
      workKey: 'title:x',
      title: 'sin 七つの大罪',
      characters: <SubtitleWorkCharacter>[
        SubtitleWorkCharacter(name: 'Lucifer', originalName: 'ルシファー'),
      ],
    );
    expect(
      subtitleGlossaryFingerprint(scraped),
      isNot(subtitleGlossaryFingerprint(bare)),
    );
    await expectLater(
      SubtitleGlossaryBuilder(
        completer: none,
      ).build(context: scraped, episodeTexts: spoken, existing: existing),
      throwsA(isA<SubtitleAiRequestFailure>()),
    );
    expect(none.calls, 1);
  });

  test('刮削的日文原名 / 角色日文名作为权威资料写进提示词', () async {
    const SubtitleWorkContext context = SubtitleWorkContext(
      workKey: 'collection:1',
      title: 'K-ON!!',
      originalTitle: 'けいおん!!',
      characters: <SubtitleWorkCharacter>[
        SubtitleWorkCharacter(
          name: 'Yui Hirasawa',
          originalName: '平沢唯',
          voiceActor: '豊崎愛生',
        ),
        SubtitleWorkCharacter(name: 'Sawako Yamanaka'),
      ],
    );
    final FakeAiCompleter ai = FakeAiCompleter(
      (String prompt, int call) => table(<Map<String, Object?>>[
        <String, Object?>{'ja': '平沢唯', 'kind': '人名'},
      ]),
    );
    await SubtitleGlossaryBuilder(
      completer: ai,
    ).build(context: context, episodeTexts: const <List<String>>[]);
    final String prompt = ai.prompts.single;
    expect(prompt, startsWith('日本のアニメ「けいおん!!」(全シーズン・劇場版を含む)'));
    expect(prompt, contains('- 日本語タイトル: けいおん!!'));
    expect(
      prompt,
      contains(
        '- 登場人物(公式の日本語表記。表の人名はこの表記に合わせること):\n'
        '  平沢唯 (Yui Hirasawa / CV: 豊崎愛生)',
      ),
    );
    expect(prompt, contains('  Sawako Yamanaka'));
    // 没给 ASR 文本时不带身份确认段。
    expect(prompt, isNot(contains('作品の特定用の資料')));
    expect(prompt, endsWith('"misrecognitions": ["結衣", "悠依"]}, ...]'));
  });

  test('百科页正文进资料段', () {
    final String sources =
        buildSubtitleGlossarySources(bare, <WebKnowledgePage>[
          WebKnowledgePage(
            site: kBuiltinWebKnowledgeSites.first,
            title: 'sin 七つの大罪',
            url: Uri.parse('https://ja.wikipedia.org/wiki/x'),
            text: '登場人物 ルシファー 声 - 大西沙織',
          ),
        ]);
    expect(sources, contains('参考資料(百科事典等の抜粋):'));
    expect(sources, contains('登場人物 ルシファー 声 - 大西沙織'));
  });

  test('文件存储：按 workKey 存取', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('gloss_store_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final SubtitleGlossaryFileStore store = SubtitleGlossaryFileStore(tmp);
    expect(await store.load('k'), isNull);
    await store.save(
      'k',
      const SubtitleGlossary(
        entries: <SubtitleGlossaryEntry>[
          SubtitleGlossaryEntry(ja: '唯', userEdited: true),
        ],
        sourceFingerprint: 'fp',
      ),
    );
    final SubtitleGlossary? back = await store.load('k');
    expect(back!.entries.single.userEdited, isTrue);
    expect(back.sourceFingerprint, 'fp');
  });
}
