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
  @override
  FavoriteLookupContext? get favoriteLookupContext =>
      const FavoriteLookupContext(sentence: 'キゲンの悪いうみな');

  Future<void> search() => searchDictionaryResult(
    searchTerm: 'キゲンの悪い',
    selectionRect: const Rect.fromLTWH(40, 40, 8, 8),
  );

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
}
