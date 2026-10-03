import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_lookup_context_assistant.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 查词按句意挑词条：候选抽取、提示词、回复校验、重排不改原对象。
/// 场景用群里截图那句：「キゲンの悪いうみな」查「キゲン」，词典把「期限」排第一。
void main() {
  DictionarySearchResult kigen() {
    final DictionarySearchResult result = DictionarySearchResult(
      searchTerm: 'キゲンの悪いうみな',
      bestLength: 3,
      headwordCount: 3,
      entries: <DictionaryEntry>[
        DictionaryEntry(word: '期限', reading: 'きげん', meaning: '前もって決められた時間'),
        DictionaryEntry(word: '起源', reading: 'きげん', meaning: '物事のおこり'),
        DictionaryEntry(word: '機嫌', reading: 'きげん', meaning: '気分のよしあし'),
        DictionaryEntry(word: '機嫌', reading: '', meaning: '<b>表情</b>や態度'),
      ],
    );
    result.popupJson = jsonEncode(<Object?>[
      <String, Object?>{
        'expression': '期限',
        'reading': 'きげん',
        'glossaries': <Object?>[
          <String, Object?>{'dictionary': 'A', 'content': '前もって決められた時間'},
        ],
      },
      <String, Object?>{
        'expression': '起源',
        'reading': 'きげん',
        'glossaries': <Object?>[
          <String, Object?>{
            'dictionary': 'A',
            'content': <String, Object?>{'tag': 'span', 'content': '物事のおこり'},
          },
        ],
      },
      <String, Object?>{
        'expression': '機嫌',
        'reading': 'きげん',
        'glossaries': <Object?>[
          <String, Object?>{'dictionary': 'A', 'content': '<b>気分</b>のよしあし'},
        ],
      },
    ]);
    return result;
  }

  final AiProviderConfig provider = AiProviderConfig(
    id: 'p',
    presetId: kAiCustomPresetId,
    name: 'p',
    baseUrl: Uri.parse('https://example.com/v1'),
    apiKey: 'k',
    model: 'm',
  );

  test('候选按弹窗分组顺序抽取，释义转纯文本（结构化内容 / HTML 都去壳）', () {
    final List<AiLookupCandidate> candidates = aiLookupCandidates(kigen());
    expect(
      <String>[for (final AiLookupCandidate c in candidates) c.expression],
      <String>['期限', '起源', '機嫌'],
    );
    expect(candidates[1].gloss, '物事のおこり');
    expect(candidates[2].gloss, '気分 のよしあし');
    expect(aiLookupMatchedText(kigen()), 'キゲン');
  });

  test('没有 popupJson 时按 entries 的表记 + 读音首次出现分组', () {
    final DictionarySearchResult result = kigen()..popupJson = null;
    expect(
      <String>[
        for (final AiLookupCandidate c in aiLookupCandidates(result))
          '${c.expression}/${c.reading}',
      ],
      <String>['期限/きげん', '起源/きげん', '機嫌/きげん', '機嫌/'],
    );
  });

  test('请求带上句子、被查的词与编号候选；回复编号换成 0 起下标', () async {
    late String sent;
    final AiChatClient client = AiChatClient(
      client: MockClient((http.Request request) async {
        sent = request.body;
        return http.Response(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{'content': '{"choice": 3}'},
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);
    final int? choice = await requestAiLookupChoice(
      client: client,
      provider: provider,
      sentence: 'キゲンの悪いうみな',
      matched: 'キゲン',
      candidates: aiLookupCandidates(kigen()),
    );
    expect(choice, 2);
    final String user =
        ((jsonDecode(sent) as Map<String, Object?>)['messages']!
                as List<Object?>)
            .last
            .toString();
    expect(user, contains('キゲンの悪いうみな'));
    expect(user, contains('Looked-up word: キゲン'));
    expect(user, contains('3. 機嫌【きげん】'));
  });

  test('只有一个候选或没有句子：不发请求', () async {
    int calls = 0;
    final AiChatClient client = AiChatClient(
      client: MockClient((http.Request request) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.close);
    final List<AiLookupCandidate> all = aiLookupCandidates(kigen());
    expect(
      await requestAiLookupChoice(
        client: client,
        provider: provider,
        sentence: 'キゲン',
        matched: 'キゲン',
        candidates: all.sublist(0, 1),
      ),
      isNull,
    );
    expect(
      await requestAiLookupChoice(
        client: client,
        provider: provider,
        sentence: '  ',
        matched: 'キゲン',
        candidates: all,
      ),
      isNull,
    );
    expect(calls, 0);
  });

  test('回复校验：0、越界、不是 JSON 都视作「不换」', () {
    expect(parseAiLookupChoice('{"choice": 2}', count: 3), 1);
    expect(parseAiLookupChoice('答案：{"choice":"3"}', count: 3), 2);
    expect(parseAiLookupChoice('{"choice": 0}', count: 3), isNull);
    expect(parseAiLookupChoice('{"choice": 4}', count: 3), isNull);
    expect(parseAiLookupChoice('機嫌', count: 3), isNull);
  });

  test('重排：被选中的组挪到最前，entries 同步，原对象（查词缓存）不动', () {
    final DictionarySearchResult original = kigen();
    final String originalJson = original.popupJson!;
    final DictionarySearchResult promoted = promoteAiLookupCandidate(
      original,
      2,
    );
    expect(identical(promoted, original), isFalse);
    expect(original.popupJson, originalJson);
    expect(original.entries.first.word, '期限');

    final List<Object?> groups =
        jsonDecode(promoted.popupJson!) as List<Object?>;
    expect(
      <Object?>[for (final Object? g in groups) (g! as Map)['expression']],
      <String>['機嫌', '期限', '起源'],
    );
    expect(
      <String>[for (final DictionaryEntry e in promoted.entries) e.word],
      <String>['機嫌', '機嫌', '期限', '起源'],
    );
    expect(promoted.searchTerm, original.searchTerm);
    expect(promoted.bestLength, original.bestLength);
    expect(promoted.headwordCount, original.headwordCount);
  });

  test('重排下标为 0 或越界：原样返回', () {
    final DictionarySearchResult original = kigen();
    expect(identical(promoteAiLookupCandidate(original, 0), original), isTrue);
    expect(identical(promoteAiLookupCandidate(original, 9), original), isTrue);
  });

  /// 发一次请求，返回系统提示词原文。
  Future<String> systemPromptFor(String? language) async {
    late String sent;
    final AiChatClient client = AiChatClient(
      client: MockClient((http.Request request) async {
        sent = request.body;
        return http.Response(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{'content': '{"choice": 1}'},
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);
    await requestAiLookupChoice(
      client: client,
      provider: provider,
      sentence: 'キゲンの悪いうみな',
      matched: 'キゲン',
      candidates: aiLookupCandidates(kigen()),
      language: language,
    );
    final List<Object?> messages =
        (jsonDecode(sent) as Map<String, Object?>)['messages']!
            as List<Object?>;
    return ((messages.first as Map<String, Object?>)['content'] ?? '')
        .toString();
  }

  test('系统提示词带上真实的查词语言，不再写死日语', () async {
    final String zh = await systemPromptFor('zh');
    expect(zh, contains('BCP 47 tag "zh"'));
    expect(zh, isNot(contains('Japanese')));
    final String ja = await systemPromptFor('ja');
    expect(ja, contains('BCP 47 tag "ja"'));
  });

  test('拿不到语言：中立措辞，不默认成任何一门语言', () async {
    for (final String? language in <String?>[null, '', '  ']) {
      final String prompt = await systemPromptFor(language);
      expect(prompt, contains('a language they are learning'));
      expect(prompt, isNot(contains('Japanese')));
      expect(prompt, isNot(contains('BCP 47 tag')));
    }
  });

  test('词头语言按查到词条的词典投票，取多数；问不出来为 null', () {
    DictionarySearchResult from(List<String> dictionaries) =>
        DictionarySearchResult(
          searchTerm: 'x',
          entries: <DictionaryEntry>[
            for (final String name in dictionaries)
              DictionaryEntry(
                word: 'x',
                reading: '',
                meaning: '',
                dictionaryName: name,
              ),
          ],
        );
    const Map<String, String?> languages = <String, String?>{
      'JMdict': 'ja',
      '大辞林': 'ja',
      'CC-CEDICT': 'zh',
      'Unknown': null,
      'Blank': '  ',
    };
    String? languageOf(String name) => languages[name];

    expect(
      aiLookupHeadwordLanguage(
        from(<String>['CC-CEDICT', 'JMdict', '大辞林']),
        languageOf,
      ),
      'ja',
    );
    // 票数相同：取先出现的。
    expect(
      aiLookupHeadwordLanguage(
        from(<String>['CC-CEDICT', 'JMdict']),
        languageOf,
      ),
      'zh',
    );
    expect(
      aiLookupHeadwordLanguage(
        from(<String>['Unknown', 'Blank', 'Missing']),
        languageOf,
      ),
      isNull,
    );
  });
}
