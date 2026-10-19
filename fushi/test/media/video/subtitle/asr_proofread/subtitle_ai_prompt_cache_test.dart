import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_clip_classifier.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_consistency_pass.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_builder.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_proofreader.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import '../../../../helpers/fake_ai_text_completer.dart';

/// 提示缓存：稳定前缀（规则 + 作品名 + 专名表）放 system 且同一作品各批逐字相同，
/// 本批内容放 user；Anthropic 协议给 system 块挂 `cache_control`。
///
/// 为什么要钉：直连 Anthropic 时不挂 `cache_control` 就完全没有提示缓存，基准里
/// 费用大头（148 万缓存写入 + 48 万缓存读取）全变成原价输入；前缀里混进一点本批
/// 内容（行号、时间）也会让 OpenAI 兼容 / DeepSeek 的自动前缀缓存全部落空。
void main() {
  AiProviderConfig provider(AiWireProtocol protocol) => AiProviderConfig(
    id: 'p',
    presetId: kAiCustomPresetId,
    name: 'p',
    baseUrl: Uri.parse('https://example.com/v1'),
    apiKey: 'k',
    model: 'm',
    protocol: protocol,
  );

  group('AiChatClient wire', () {
    late Map<String, Object?> sent;
    AiChatClient client(Object? reply) => AiChatClient(
      client: MockClient((http.Request request) async {
        sent = jsonDecode(request.body) as Map<String, Object?>;
        return http.Response(
          jsonEncode(reply),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    final Map<String, Object?> anthropicReply = <String, Object?>{
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': 'ok'},
      ],
    };

    test('Anthropic：可缓存的 system 变成带 cache_control 的文本块', () async {
      final AiChatClient c = client(anthropicReply);
      addTearDown(c.close);
      await AiChatTextCompleter(
        client: c,
        provider: provider(AiWireProtocol.anthropicMessages),
      ).complete('本批', stablePrefix: '規則と作品名');
      expect(sent['system'], <Object?>[
        <String, Object?>{
          'type': 'text',
          'text': '規則と作品名',
          'cache_control': <String, Object?>{'type': 'ephemeral'},
        },
      ]);
      expect(sent['messages'], <Object?>[
        <String, Object?>{'role': 'user', 'content': '本批'},
      ]);
    });

    test('Anthropic：没有可缓存段时 system 仍是纯字符串（其它调用方 wire 不变）', () async {
      final AiChatClient c = client(anthropicReply);
      addTearDown(c.close);
      await c.complete(
        provider: provider(AiWireProtocol.anthropicMessages),
        messages: const <AiChatMessage>[
          AiChatMessage.system('sys'),
          AiChatMessage.user('u'),
        ],
      );
      expect(sent['system'], 'sys');
    });

    test('Anthropic：多段 system 只在最后一个可缓存块上挂断点，文本口径同纯字符串', () async {
      final AiChatClient c = client(anthropicReply);
      addTearDown(c.close);
      await c.complete(
        provider: provider(AiWireProtocol.anthropicMessages),
        messages: const <AiChatMessage>[
          AiChatMessage.system('a', cacheable: true),
          AiChatMessage.system('b', cacheable: true),
          AiChatMessage.system('c'),
          AiChatMessage.user('u'),
        ],
      );
      final List<Object?> blocks = sent['system']! as List<Object?>;
      expect(
        blocks.map((Object? b) => (b! as Map<String, Object?>)['text']).join(),
        'a\n\nb\n\nc',
      );
      expect(
        <bool>[
          for (final Object? b in blocks)
            (b! as Map<String, Object?>).containsKey('cache_control'),
        ],
        <bool>[false, true, false],
      );
    });

    test('OpenAI 兼容：前缀是第一条 system 消息（自动前缀缓存），本批是 user', () async {
      final AiChatClient c = client(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': 'ok'},
          },
        ],
      });
      addTearDown(c.close);
      await AiChatTextCompleter(
        client: c,
        provider: provider(AiWireProtocol.openAiCompatible),
      ).complete('本批', stablePrefix: '規則');
      expect(sent['messages'], <Object?>[
        <String, Object?>{'role': 'system', 'content': '規則'},
        <String, Object?>{'role': 'user', 'content': '本批'},
      ]);
      expect(jsonEncode(sent), isNot(contains('cache_control')));
    });
  });

  group('各阶段的前缀', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('aipc_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    const SubtitleGlossary glossary = SubtitleGlossary(
      entries: <SubtitleGlossaryEntry>[
        SubtitleGlossaryEntry(
          ja: '唯',
          reading: 'ゆい',
          kind: '人名(平沢唯の名)',
          misrecognitions: <String>['結衣'],
        ),
        SubtitleGlossaryEntry(ja: '律', reading: 'りつ', kind: '人名(田井中律の名)'),
      ],
    );

    List<SubtitleDraftCue> cues(int n) => <SubtitleDraftCue>[
      for (int i = 0; i < n; i++)
        SubtitleDraftCue(
          startMs: i * 2000,
          endMs: i * 2000 + 1500,
          text: i.isEven ? '結衣ちゃんおはよう$i' : 'ユイ先輩$i',
          alternatives: <String>['候補$i'],
        ),
    ];

    test('S3：各批前缀逐字相同、不含本批内容；拼回去与原整段提示词一致', () async {
      final List<SubtitleDraftCue> input = cues(70);
      final FakeAiCompleter ai = FakeAiCompleter(
        (String prompt, int call) => replyForIds(prompt, (int id) => 'x$id'),
      );
      await SubtitleProofreader(completer: ai, concurrency: 1).proofread(
        cues: input,
        title: 'けいおん!',
        glossary: glossary,
        cacheDir: Directory(p.join(tmp.path, 'proofread')),
      );
      expect(ai.calls, 3);
      expect(ai.prefixes.toSet(), hasLength(1));
      final String prefix = ai.prefixes.first;
      expect(prefix, startsWith(kSubtitleProofreadRules));
      expect(prefix, contains('作品名: けいおん!'));
      expect(prefix, contains('唯(ゆい) 人名(平沢唯の名) 誤: 結衣'));
      expect(prefix, isNot(contains('id=')));
      expect(ai.bodies.toSet(), hasLength(3));
      final String glossaryText = formatGlossaryForProofread(glossary);
      for (int b = 0; b < 3; b++) {
        expect(
          ai.prompts[b],
          buildProofreadBatchPrompt(
            cues: input,
            lo: b * 30,
            hi: b == 2 ? 70 : b * 30 + 30,
            title: 'けいおん!',
            glossaryText: glossaryText,
          ),
        );
      }
      // 旧拼法（规则 → 作品名 → 专名表 → 上下文）逐字保持。
      expect(
        ai.prompts.first,
        startsWith(
          '$kSubtitleProofreadRules\n\n作品名: けいおん!\n固有名詞表:\n$glossaryText\n\n'
          '参考(直前の行、修正不要):',
        ),
      );
    });

    test('S4：各批前缀相同（规则 + 作品名 + 专名表），拼回去等于整段模板替换', () async {
      final List<SubtitleDraftCue> input = <SubtitleDraftCue>[
        for (int i = 0; i < 90; i++)
          SubtitleDraftCue(
            startMs: i * 5000,
            endMs: i * 5000 + 1000,
            text: '結衣と話す$i',
            speaker: 'S$i',
          ),
      ];
      final FakeAiCompleter ai = FakeAiCompleter(
        (String prompt, int call) => replyForIds(prompt, (int id) => '唯と話す$id'),
      );
      await SubtitleConsistencyPass(completer: ai).run(
        cues: input,
        title: 'けいおん!',
        glossary: glossary,
        cacheFile: File(p.join(tmp.path, 'consistency.json')),
      );
      expect(ai.calls, 3);
      expect(ai.prefixes.toSet(), hasLength(1));
      const String gl = '唯(ゆい) 人名(平沢唯の名)\n律(りつ) 人名(田井中律の名)';
      expect(
        ai.prefixes.first,
        buildConsistencyStablePrefix(title: 'けいおん!', glossaryText: gl),
      );
      expect(
        ai.prompts.first,
        kSubtitleConsistencyRules
            .replaceAll('{title}', 'けいおん!')
            .replaceAll('{glossary}', gl)
            .replaceAll('{lines}', ai.bodies.first),
      );
    });

    test('歌曲判定：前缀是规则 + 作品名，片段在本批', () async {
      final FakeAiCompleter ai = FakeAiCompleter(
        (String prompt, int call) => '{"a": "song"}',
      );
      await SubtitleClipClassifier(completer: ai).classify(
        clips: <String, List<String>>{
          'a': <String>['ふわふわ'],
        },
        title: 'けいおん!',
        cacheFile: File(p.join(tmp.path, 'clip.json')),
      );
      expect(ai.prefixes.single, buildClipClassifyStablePrefix('けいおん!'));
      expect(ai.prefixes.single, isNot(contains('ふわふわ')));
      expect(
        ai.prompts.single,
        kSubtitleClipPrompt
            .replaceAll('{title}', 'けいおん!')
            .replaceAll('{clips}', 'id=a\nふわふわ'),
      );
    });

    test('S0：首次生成与身份重做共用同一个前缀（规则 + 资料），ASR 抽样只在本批', () async {
      int call = 0;
      final FakeAiCompleter ai = FakeAiCompleter((String prompt, int i) {
        call++;
        // 第一次给一张对不上音频的表（触发身份重做），第二次给对的。
        return call == 1
            ? '[{"ja":"ア","kind":"人名"},{"ja":"イ","kind":"人名"},'
                  '{"ja":"ウ","kind":"人名"},{"ja":"エ","kind":"人名"}]'
            : '[{"ja":"唯","reading":"ゆい","kind":"人名"}]';
      });
      await SubtitleGlossaryBuilder(completer: ai).build(
        // 无刮削身份：只有这条路会做身份重做（有刮削时覆盖率低只警告）。
        context: const SubtitleWorkContext(workKey: 'k', title: 'けいおん!'),
        episodeTexts: <List<String>>[
          <String>['唯ちゃん', 'ユイ'],
        ],
      );
      expect(ai.calls, 2);
      expect(ai.prefixes[0], ai.prefixes[1]);
      expect(ai.prefixes[0], startsWith('日本のアニメ「けいおん!」'));
      expect(ai.prefixes[0], isNot(contains('唯ちゃん')));
      expect(ai.bodies[0], contains('唯ちゃん'));
      expect(ai.bodies[1], contains('前回作った表の人名はほとんど音声に出てこなかった'));
      expect(ai.prompts[0], startsWith('日本のアニメ「けいおん!」'));
      expect(ai.prompts[0], endsWith(']'));
    });
  });

  test('joinAiTextPrompt：空前缀即本批原文', () {
    expect(joinAiTextPrompt('', 'x'), 'x');
    expect(joinAiTextPrompt('a', 'b'), 'a\nb');
  });
}
