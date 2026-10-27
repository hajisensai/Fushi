import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/game_stream_library_host.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart';
import 'package:fushi_engine/models/content_language.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 远程查词带上**请求方**的查词语言（wire 字段 `language`，可选）：host 按它决定是否开
/// 简体 → 繁體回落，而不是按 host 自己当前正在读的内容的语言。
///
/// 兼容契约：请求不带语言 / service 不认识语言（旧实现、测试替身）时一律走旧方法，行为
/// 与此前逐字相同；分派只在 `searchRemoteDictionary*ForRequest` 一处，互联 host、浏览器
/// 扩展 server 与控制通道（fushi_cli）三路共用。

/// 只实现旧接口的 service（旧 host 实现 / 测试替身）。
class _LegacyLookup implements FushiRemoteLookupService {
  final List<String> calls = <String>[];

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    calls.add('full');
    return DictionarySearchResult(searchTerm: term, bestLength: 1);
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
}

/// 旧接口 + popup 快路径，但不认识语言。
class _LegacyPopupLookup extends _LegacyLookup
    implements FushiRemotePopupLookupService {
  @override
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopup({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    calls.add('popup');
    return const RemoteDictionaryPopupLookup(popupJson: '[]', bestLength: 1);
  }
}

/// 认识语言的 service：记下每次分派到了哪条路、带了什么语言。
class _LanguageLookup extends _LegacyPopupLookup
    implements FushiRemoteLanguageLookupService {
  final List<String?> languages = <String?>[];
  RemoteDictionaryPopupTiming? lastTiming;

  @override
  Future<DictionarySearchResult?> searchDictionaryInLanguage({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required String language,
  }) async {
    calls.add('full-lang');
    languages.add(language);
    return DictionarySearchResult(searchTerm: term, bestLength: 2);
  }

  @override
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopupInLanguage({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required String language,
    RemoteDictionaryPopupTiming? timing,
  }) async {
    calls.add('popup-lang');
    languages.add(language);
    lastTiming = timing;
    return const RemoteDictionaryPopupLookup(popupJson: '[]', bestLength: 2);
  }
}

void main() {
  group('remoteLookupLanguageOf', () {
    test('取裁掉空白后的非空字符串', () {
      expect(
        remoteLookupLanguageOf(<String, dynamic>{'language': ' zh-TW '}),
        'zh-TW',
      );
    });
    test('缺省 / 空串 / 纯空白 / 非字符串一律当没给', () {
      expect(remoteLookupLanguageOf(<String, dynamic>{}), isNull);
      expect(remoteLookupLanguageOf(<String, dynamic>{'language': ''}), isNull);
      expect(
        remoteLookupLanguageOf(<String, dynamic>{'language': '  '}),
        isNull,
      );
      expect(remoteLookupLanguageOf(<String, dynamic>{'language': 3}), isNull);
    });
  });

  group('buildRemoteDictionaryLookupResponse 按请求语言分派', () {
    test('带语言 + service 认识语言 ⇒ 完整查词走 InLanguage 并带上该语言', () async {
      final _LanguageLookup lookup = _LanguageLookup();
      final Map<String, dynamic> r = await buildRemoteDictionaryLookupResponse(
        <String, dynamic>{'term': '头发', 'language': 'zh-CN'},
        lookup: lookup,
      );
      expect(lookup.calls, <String>['full-lang']);
      expect(lookup.languages, <String?>['zh-CN']);
      expect((r['result'] as Map<String, dynamic>)['bestLength'], 2);
    });

    test('不带语言 ⇒ 走旧方法（旧请求行为不变）', () async {
      final _LanguageLookup lookup = _LanguageLookup();
      await buildRemoteDictionaryLookupResponse(<String, dynamic>{
        'term': '头发',
      }, lookup: lookup);
      await buildRemoteDictionaryLookupResponse(<String, dynamic>{
        'term': '头发',
        'language': ' ',
      }, lookup: lookup);
      expect(lookup.calls, <String>['full', 'full']);
      expect(lookup.languages, isEmpty);
    });

    test('带语言但 service 不认识语言 ⇒ 回落旧方法', () async {
      final _LegacyLookup lookup = _LegacyLookup();
      await buildRemoteDictionaryLookupResponse(<String, dynamic>{
        'term': '头发',
        'language': 'zh',
      }, lookup: lookup);
      expect(lookup.calls, <String>['full']);
    });

    test('popupOnly + 带语言 ⇒ popup 快路径的 InLanguage，计时器照传', () async {
      final _LanguageLookup lookup = _LanguageLookup();
      final RemoteDictionaryPopupTiming timing = RemoteDictionaryPopupTiming();
      final Map<String, dynamic> r = await buildRemoteDictionaryLookupResponse(
        <String, dynamic>{'term': '头发', 'popupOnly': true, 'language': 'zh'},
        lookup: lookup,
        popupTiming: timing,
      );
      expect(lookup.calls, <String>['popup-lang']);
      expect(lookup.languages, <String?>['zh']);
      expect(identical(lookup.lastTiming, timing), isTrue);
      expect(r['popupJson'], '[]');
    });

    test('popupOnly + 带语言 + 只有旧 popup 快路径 ⇒ 旧 popup 快路径', () async {
      final _LegacyPopupLookup lookup = _LegacyPopupLookup();
      await buildRemoteDictionaryLookupResponse(<String, dynamic>{
        'term': '头发',
        'popupOnly': true,
        'language': 'zh',
      }, lookup: lookup);
      expect(lookup.calls, <String>['popup']);
    });

    test('popupOnly + 没有任何 popup 快路径 ⇒ 回落完整查词', () async {
      final _LegacyLookup lookup = _LegacyLookup();
      await buildRemoteDictionaryLookupResponse(<String, dynamic>{
        'term': '头发',
        'popupOnly': true,
        'language': 'zh',
      }, lookup: lookup);
      expect(lookup.calls, <String>['full']);
    });

    test('record=true 时 popupOnly 也走完整查词（历史需要完整结果），语言照带', () async {
      final _LanguageLookup lookup = _LanguageLookup();
      await buildRemoteDictionaryLookupResponse(<String, dynamic>{
        'term': '头发',
        'popupOnly': true,
        'record': true,
        'language': 'zh-Hant',
      }, lookup: lookup);
      expect(lookup.calls, <String>['full-lang']);
      expect(lookup.languages, <String?>['zh-Hant']);
    });
  });

  group('FushiRemoteLookupClient.searchDictionary 发出请求方语言', () {
    const FushiClientUrl host = FushiClientUrl(
      url: 'http://desk:8765',
      hostId: 'desk',
      token: 'desk-token',
    );
    late FushiDatabase db;
    late SyncRepository repo;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      repo = SyncRepository(db);
      await repo.setFushiClientUrls(<FushiClientUrl>[host]);
    });
    tearDown(() async => db.close());

    Future<Map<String, dynamic>> sentBody(String? language) async {
      Map<String, dynamic>? body;
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        onlyCandidate: host,
        httpClient: MockClient((http.Request request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, dynamic>{
                'type': 'dictionaryResult',
                'result': null,
              }),
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      );
      await client.searchDictionary(
        term: '头发',
        wildcards: false,
        maximumTerms: 5,
        language: language,
      );
      return body!;
    }

    test('有语言 ⇒ body 带 language（裁掉空白）', () async {
      final Map<String, dynamic> body = await sentBody(' zh-CN ');
      expect(body[kRemoteLookupLanguageField], 'zh-CN');
      expect(body['term'], '头发');
    });

    test('null / 空白 ⇒ 不发该字段（与旧客户端的请求体逐字相同）', () async {
      expect(
        (await sentBody(null)).containsKey(kRemoteLookupLanguageField),
        isFalse,
      );
      expect(
        (await sentBody('  ')).containsKey(kRemoteLookupLanguageField),
        isFalse,
      );
    });

    // 遥控 / 串流：被查的内容在 host 上播放，查词语言归 host，请求方无权声明。
    test('游戏串流查词：请求体从不带接收端语言（语言归 host）', () async {
      Map<String, dynamic>? body;
      final InterconnectGameStreamDictionaryLookup lookup =
          InterconnectGameStreamDictionaryLookup(
            repo: repo,
            peer: host,
            httpClient: MockClient((http.Request request) async {
              body = jsonDecode(request.body) as Map<String, dynamic>;
              // 回包带指纹，免得客户端再去问样式端点。
              return http.Response.bytes(
                utf8.encode(
                  jsonEncode(<String, dynamic>{
                    'type': 'dictionaryResult',
                    'result': null,
                    'dictionaryStylesRevision': 'r',
                    'dictionaryStyles': <String, String>{},
                  }),
                ),
                200,
                headers: const <String, String>{
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }),
          );
      await lookup.searchDictionary(
        term: '头发',
        wildcards: false,
        maximumTerms: 20,
      );
      expect(body!['term'], '头发');
      expect(body!.containsKey(kRemoteLookupLanguageField), isFalse);
    });

    test('遥控 / 串流接收端源码不再读本机查词语言发给 host', () {
      // 回归钉：4a1d9b57ab 曾把接收端本机（常是上次读书留下的残留）语言发给电脑，
      // 电脑据此关掉简体 → 繁體回落。这些文件里出现本机查词语言即视为回退。
      const List<String> files = <String>[
        'lib/src/pages/implementations/video_remote_page.dart',
        'lib/src/pages/implementations/game_stream_join_page.dart',
        'lib/src/pages/implementations/game_stream_library_page.dart',
        'lib/src/pages/implementations/game_stream_session_opener.dart',
        'lib/src/sync/game_stream_client.dart',
        'lib/src/sync/sync_settings_schema.dart',
      ];
      for (final String path in files) {
        final String source = File(path).readAsStringSync();
        expect(
          source.contains('effectiveLookupLanguage') ||
              source.contains('currentLookupLanguage') ||
              source.contains('readLookupLanguage') ||
              RegExp(r'\blanguage:\s*_lookupLanguage').hasMatch(source),
          isFalse,
          reason: '$path 不得把接收端本机查词语言发给 host',
        );
      }
    });

    test('本机启动游戏的两条入口都按游戏卡登记查词语言', () {
      // 游戏首页的启动曾漏了这一步，查词沿用上一个媒体页留下的残留语言。
      const List<String> files = <String>[
        'lib/src/pages/implementations/games_library_page.dart',
        'lib/src/pages/implementations/galgame_home_page.dart',
      ];
      for (final String path in files) {
        final String source = File(path).readAsStringSync();
        expect(
          source.contains('enterGameLookupLanguage(game.language)'),
          isTrue,
          reason: '$path 启动游戏时必须登记该游戏的查词语言',
        );
      }
    });
  });

  group('host 按串流会话的游戏条目判查词语言', () {
    late FushiRemoteGameStreamService service;
    late ValueNotifier<GalHookSessionState> hook;

    setUp(() {
      service = FushiRemoteGameStreamService(sessionIdGenerator: () => 'sid');
      hook = ValueNotifier<GalHookSessionState>(const GalHookSessionState());
    });
    tearDown(() {
      service.dispose();
      hook.dispose();
    });

    GalgameEntry game(String id, {String? language}) => GalgameEntry(
      id: id,
      name: 'Game $id',
      exePath: 'C:/games/$id/$id.exe',
      workdir: 'C:/games/$id',
      language: language,
      addedAt: DateTime(2026),
    );

    FushiGameStreamLibraryHost library(List<GalgameEntry> games) =>
        FushiGameStreamLibraryHost(
          loadGames: () async => games,
          isLaunchEnabled: () => true,
          service: () => service,
          startStream:
              ({
                required int hwnd,
                required GameStreamVideoSettings settings,
                required String gameId,
                required String gameTitle,
                required String launchId,
              }) async => service.createSession(
                windowId: 'hwnd:$hwnd',
                gameId: gameId,
                launchId: launchId,
              ),
          readHookState: () => hook.value,
          hookChanges: hook,
        );

    final List<GalgameEntry> games = <GalgameEntry>[
      game('ja', language: 'ja'),
      game('zh', language: 'zh-CN'),
      game('none'),
    ];

    test('远程启动：按会话 gameId 取该游戏卡的语言', () async {
      final FushiGameStreamLibraryHost host = library(games);
      expect(await host.streamGameLanguage(gameId: 'zh'), 'zh-CN');
      expect(await host.streamGameLanguage(gameId: 'ja'), 'ja');
      expect(await host.streamGameLanguage(gameId: 'none'), isNull);
      expect(await host.streamGameLanguage(gameId: 'missing'), isNull);
    });

    test('本机对运行中的游戏开串流：按 Hook 会话的 exe 取游戏卡语言', () async {
      final FushiGameStreamLibraryHost host = library(games);
      expect(await host.streamGameLanguage(), isNull);
      hook.value = GalHookSessionState(
        phase: GalHookSessionPhase.running,
        launchExe: games[1].exePath,
        boundWindow: const ExternalWindowInfo(hwnd: 7, title: 'ZH'),
      );
      expect(await host.streamGameLanguage(), 'zh-CN');
    });

    test('中文游戏 ⇒ host 判中文（开简体 → 繁體回落），与接收端语言无关', () async {
      final String? zh = await library(games).streamGameLanguage(gameId: 'zh');
      expect(
        isChineseLanguageTag(resolveContentLanguage(explicit: zh)),
        isTrue,
      );
      final String? ja = await library(games).streamGameLanguage(gameId: 'ja');
      expect(
        isChineseLanguageTag(resolveContentLanguage(explicit: ja)),
        isFalse,
      );
    });
  });
}
