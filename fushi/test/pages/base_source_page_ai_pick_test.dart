import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/media/favorites/favorite_lookup_context.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/test_platform_services.dart';

/// 阅读器 / 漫画弹窗（BaseSourcePage）的「按句意挑词条」接线：手动 ✨ 与自动判断
/// 都把 AI 选中的词头换到最前，且换的是**新**结果对象（查词缓存里那份不动）；
/// 没指派提供商时一个请求都不发。
DictionarySearchResult _kigen() {
  final DictionarySearchResult result = DictionarySearchResult(
    searchTerm: 'キゲンの悪い',
    bestLength: 3,
    headwordCount: 2,
    entries: <DictionaryEntry>[
      DictionaryEntry(word: '期限', reading: 'きげん', meaning: '期日'),
      DictionaryEntry(word: '機嫌', reading: 'きげん', meaning: '気分'),
    ],
  );
  result.popupJson = jsonEncode(<Object?>[
    <String, Object?>{
      'expression': '期限',
      'reading': 'きげん',
      'glossaries': <Object?>[],
    },
    <String, Object?>{
      'expression': '機嫌',
      'reading': 'きげん',
      'glossaries': <Object?>[],
    },
  ]);
  return result;
}

class _AiPickAppModel extends AppModel {
  _AiPickAppModel({this.auto = false}) : super(testPlatformServices());

  final bool auto;
  final DictionarySearchResult cached = _kigen();

  @override
  bool get lookupAiContextAuto => auto;
  @override
  int get maximumTerms => 10;
  @override
  double get popupMaxWidth => 360;
  @override
  double get popupMaxHeight => 360;
  @override
  bool get popupBottomDocked => false;
  @override
  double get appUiScale => 1.0;
  @override
  List<String> get enabledAudioSources => const <String>[];
  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];
  @override
  bool get lowMemoryMode => false;
  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async => cached;
}

class _Host extends BaseSourcePage {
  const _Host({super.key}) : super(item: null);

  @override
  BaseSourcePageState<_Host> createState() => _HostState();
}

class _HostState extends BaseSourcePageState<_Host> {
  /// 页面「当前句」——阅读器在选词时写入；每次查词各自记下自己那一刻的值。
  String sentence = 'キゲンの悪いうみな';

  @override
  FavoriteLookupContext? get favoriteLookupContext =>
      FavoriteLookupContext(sentence: sentence);

  /// 与阅读器 / 漫画同一收尾：先裁栈（保留热槽），再在热槽上查新词。
  Future<void> search({LookupOrigin origin = LookupOrigin.explicit}) {
    prunePopupStack(0);
    return searchDictionaryResult(
      searchTerm: 'キゲンの悪い',
      selectionRect: const Rect.fromLTWH(40, 40, 8, 8),
      origin: origin,
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

AiProviderConfig _provider() => AiProviderConfig(
  id: 'p',
  presetId: kAiCustomPresetId,
  name: 'p',
  baseUrl: Uri.parse('https://example.com/v1'),
  apiKey: 'k',
  model: 'm',
);

AiChatClient Function() _clientChoosing(int choice, List<int> calls) =>
    () => AiChatClient(
      client: MockClient((http.Request request) async {
        calls.add(1);
        return http.Response(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{'content': '{"choice": $choice}'},
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );

/// 记录 close 的 AI 客户端：被新查词作废的自动请求，宿主必须当场 close 它。
/// （注入的 http 客户端不归 [AiChatClient] 所有，它的 close 不会传下去，所以在这层记。）
class _RecordingAiChatClient extends AiChatClient {
  _RecordingAiChatClient(_GatedHttpClient http)
    : gate = http,
      super(client: http);

  final _GatedHttpClient gate;
  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}

/// 回复由测试手动放行的 HTTP 客户端（模拟「回复已在路上、close 拦不住」的请求）。
class _GatedHttpClient extends http.BaseClient {
  final Completer<int> _choice = Completer<int>();
  String body = '';

  void reply(int choice) => _choice.complete(choice);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) body = request.body;
    final int choice = await _choice.future;
    final List<int> bytes = utf8.encode(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': '{"choice": $choice}'},
          },
        ],
      }),
    );
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
}

Future<_HostState> _pumpHost(WidgetTester tester, AppModel appModel) async {
  final GlobalKey<_HostState> key = GlobalKey<_HostState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appProvider.overrideWith((ref) => appModel)],
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(body: _Host(key: key)),
        ),
      ),
    ),
  );
  await tester.pump();
  return key.currentState!;
}

String _firstWord(_HostState host) =>
    host.debugPopupEntries.last.result!.entries.first.word;

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('手动 ✨：AI 选第 2 个词头，弹窗换成新结果、缓存那份不动', (WidgetTester tester) async {
    final _AiPickAppModel appModel = _AiPickAppModel();
    final _HostState host = await _pumpHost(tester, appModel);
    final List<int> calls = <int>[];
    host
      ..debugLookupAiProvider = _provider
      ..debugLookupAiClientFactory = _clientChoosing(2, calls);
    await host.search();
    expect(_firstWord(host), '期限');

    final DictionaryPopupEntry entry = host.debugPopupEntries.last;
    await host.aiPickLookupEntry(entry);
    expect(calls, hasLength(1));
    expect(_firstWord(host), '機嫌');
    expect(identical(entry.result, appModel.cached), isFalse);
    expect(appModel.cached.entries.first.word, '期限');

    // 同句同词再点：命中会话内结论，不再付费。
    await host.aiPickLookupEntry(entry);
    expect(calls, hasLength(1));
  });

  testWidgets('自动判断开着：查词后 AI 回来即换到最前', (WidgetTester tester) async {
    final _HostState host = await _pumpHost(
      tester,
      _AiPickAppModel(auto: true),
    );
    final List<int> calls = <int>[];
    host
      ..debugLookupAiProvider = _provider
      ..debugLookupAiClientFactory = _clientChoosing(2, calls);
    await host.search();
    for (int i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(calls, hasLength(1));
    expect(_firstWord(host), '機嫌');
  });

  testWidgets('AI 认为第一个就对（choice 1）：保持原结果', (WidgetTester tester) async {
    final _AiPickAppModel appModel = _AiPickAppModel();
    final _HostState host = await _pumpHost(tester, appModel);
    host
      ..debugLookupAiProvider = _provider
      ..debugLookupAiClientFactory = _clientChoosing(1, <int>[]);
    await host.search();
    final DictionaryPopupEntry entry = host.debugPopupEntries.last;
    await host.aiPickLookupEntry(entry);
    expect(identical(entry.result, appModel.cached), isTrue);
  });

  testWidgets('没指派提供商：自动开着也不发请求', (WidgetTester tester) async {
    final _HostState host = await _pumpHost(
      tester,
      _AiPickAppModel(auto: true),
    );
    final List<int> calls = <int>[];
    host
      ..debugLookupAiProvider = (() => null)
      ..debugLookupAiClientFactory = _clientChoosing(2, calls);
    await host.search();
    for (int i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(calls, isEmpty);
    expect(_firstWord(host), '期限');
  });

  testWidgets('连续两次查词：旧的自动请求当场 close，只有最后一次的结论落地', (WidgetTester tester) async {
    final _HostState host = await _pumpHost(
      tester,
      _AiPickAppModel(auto: true),
    );
    final List<_RecordingAiChatClient> clients = <_RecordingAiChatClient>[];
    host
      ..debugLookupAiProvider = _provider
      ..debugLookupAiClientFactory = () {
        final _RecordingAiChatClient client = _RecordingAiChatClient(
          _GatedHttpClient(),
        );
        clients.add(client);
        return client;
      };

    host.sentence = '期限が切れた';
    await host.search();
    await tester.pump();
    expect(clients, hasLength(1));
    expect(clients[0].closed, isFalse);

    host.sentence = 'キゲンの悪いうみな';
    await host.search();
    await tester.pump();
    expect(clients, hasLength(2), reason: '每次明确查词各发一次');
    expect(clients[0].closed, isTrue, reason: '代次一变，上一次的自动请求当场 close');
    expect(clients[1].closed, isFalse);
    expect(clients[0].gate.body, contains('期限が切れた'));
    expect(clients[1].gate.body, contains('キゲンの悪いうみな'));

    // 最新那次认为第一个就对；之后旧请求的回复才到（选第 2 个）——必须丢弃。
    clients[1].gate.reply(1);
    for (int i = 0; i < 5; i++) {
      await tester.pump();
    }
    clients[0].gate.reply(2);
    for (int i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(host.debugPopupEntries, hasLength(1), reason: '两次查词复用同一个热槽层');
    expect(_firstWord(host), '期限', reason: '过期查词的 AI 结论不得落到新弹窗上');
    expect(clients[1].closed, isTrue, reason: '请求结束后自己也 close');
  });

  testWidgets('悬停查词：自动开着也不发请求，但这一层仍记下原句（手动 ✨ 可用）', (WidgetTester tester) async {
    final _HostState host = await _pumpHost(
      tester,
      _AiPickAppModel(auto: true),
    );
    final List<int> calls = <int>[];
    host
      ..debugLookupAiProvider = _provider
      ..debugLookupAiClientFactory = _clientChoosing(2, calls);
    await host.search(origin: LookupOrigin.hover);
    for (int i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(calls, isEmpty, reason: '悬停扫一行会连查十几个词，不得逐个付费');
    final DictionaryPopupEntry entry = host.debugPopupEntries.last;
    expect(entry.lookupSentence, 'キゲンの悪いうみな');
    expect(host.debugShowsAiPick(entry), isTrue);
  });

  testWidgets('嵌套层：没有可信原句，不画 ✨，自动 / 手动都不发请求', (WidgetTester tester) async {
    final _HostState host = await _pumpHost(
      tester,
      _AiPickAppModel(auto: true),
    );
    final List<int> calls = <int>[];
    host
      ..debugLookupAiProvider = _provider
      ..debugLookupAiClientFactory = _clientChoosing(2, calls);
    await host.search(origin: LookupOrigin.nested);
    for (int i = 0; i < 3; i++) {
      await tester.pump();
    }
    final DictionaryPopupEntry entry = host.debugPopupEntries.last;
    expect(entry.lookupSentence, isNull, reason: '外层阅读器的句子与释义里点的词无关');
    expect(host.debugShowsAiPick(entry), isFalse);
    await host.aiPickLookupEntry(entry);
    expect(calls, isEmpty);
    expect(_firstWord(host), '期限');
  });

  testWidgets('✨ 用的是这一层查词那一刻的句子，不是页面后来的「当前句」', (WidgetTester tester) async {
    final _HostState host = await _pumpHost(tester, _AiPickAppModel());
    final List<_RecordingAiChatClient> clients = <_RecordingAiChatClient>[];
    host
      ..debugLookupAiProvider = _provider
      ..debugLookupAiClientFactory = () {
        final _RecordingAiChatClient client = _RecordingAiChatClient(
          _GatedHttpClient(),
        );
        clients.add(client);
        return client;
      };
    await host.search();
    host.sentence = '全然別の文';
    final DictionaryPopupEntry entry = host.debugPopupEntries.last;
    final Future<void> pick = host.aiPickLookupEntry(entry);
    await tester.pump();
    expect(clients.single.gate.body, contains('キゲンの悪いうみな'));
    expect(clients.single.gate.body, isNot(contains('全然別の文')));
    clients.single.gate.reply(2);
    for (int i = 0; i < 5; i++) {
      await tester.pump();
    }
    await pick;
    expect(_firstWord(host), '機嫌');
  });
}
