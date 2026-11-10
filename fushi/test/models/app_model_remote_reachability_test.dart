import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/remote_dictionary_catalog_service.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// BUG-4275：查词与服务器词典目录服务共用一份可达性。
///
/// 走真实的 `AppModel.searchDictionary` 与真实的目录服务：服务器是回环地址上的假
/// host，「掉线」时收到请求就直接掐断连接（客户端拿不到任何 HTTP 响应 = 传输层失败）。
/// 本机结果经查词结果缓存命中。
void main() {
  late FushiDatabase db;
  late HttpServer host;
  late AppModel app;
  late DictionaryRepository dictRepo;
  late Directory tmpDir;
  final List<String> requests = <String>[];
  bool hostDown = false;

  const String term = '食べる';
  const int maxTerms = 10;

  FushiLookupResult row(String dict, String side) => FushiLookupResult(
    matched: term,
    deinflected: term,
    trace: const <FushiTransformGroup>[],
    preprocessorSteps: 0,
    term: FushiTermResult(
      expression: term,
      reading: 'たべる',
      rules: '',
      glossaries: <FushiGlossaryEntry>[
        FushiGlossaryEntry(
          dictName: dict,
          glossary: jsonEncode('$side $dict'),
          definitionTags: '',
          termTags: '',
        ),
      ],
      frequencies: const <FushiFrequencyEntry>[],
      pitches: const <FushiPitchEntry>[],
    ),
  );

  DictionarySearchResult resultOf(String dict, String side) {
    final List<FushiLookupResult> rows = <FushiLookupResult>[row(dict, side)];
    final DictionarySearchResult result = buildResultFromLookup(
      searchTerm: term,
      results: rows,
      maximumTerms: maxTerms,
    );
    result.popupJson = buildPopupJsonFromLookup(
      results: rows,
      maximumTerms: maxTerms,
      hiddenDictionaries: const <String>{},
    );
    return result;
  }

  int lookupRequests() =>
      requests.where((String p) => p == '/api/lookup/dictionary').length;

  setUp(() async {
    requests.clear();
    hostDown = false;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final DictionarySearchResult remote = resultOf('大辞林', 'server');
    host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host.listen((HttpRequest request) async {
      await utf8.decodeStream(request);
      requests.add(request.uri.path);
      if (hostDown) {
        final Socket socket = await request.response.detachSocket(
          writeHeaders: false,
        );
        socket.destroy();
        return;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        request.uri.path == kRemoteDictionaryCatalogPath
            ? '[]'
            : jsonEncode(<String, dynamic>{
                'type': 'dictionaryResult',
                'result': jsonDecode(remote.toJson()),
                'popupJson': remote.popupJson,
              }),
      );
      await request.response.close();
    });

    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    await SyncRepository(db).setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(
        url: 'http://127.0.0.1:${host.port}',
        hostId: 'srv',
        token: 'srv-token',
      ),
    ]);
    dictRepo = DictionaryRepository(db);
    await dictRepo.loadFromDb();
    await dictRepo.persistDictionary(
      Dictionary(name: 'JMdict-local', formatKey: 'yomitan', order: 0),
    );
    dictRepo.cacheSearchResult(
      buildSearchCacheKey(term: term, maxTerms: maxTerms, maxResults: maxTerms),
      resultOf('JMdict-local', 'local'),
    );
    tmpDir = Directory.systemTemp.createTempSync('fushi_remote_reachability_');
    app = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefsRepo,
        databaseDirectory: tmpDir,
      )
      ..wireDatabaseForTesting(db, dictionaryRepository: dictRepo);
  });

  tearDown(() async {
    app.remoteDictionaryReachabilityForTesting.dispose();
    await host.close(force: true);
    dictRepo.dispose();
    await db.close();
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<List<String>> searchDictionaries() async {
    final DictionarySearchResult r = await app.searchDictionary(
      searchTerm: term,
      searchWithWildcards: false,
      overrideMaximumTerms: maxTerms,
    );
    return r.entries.map((DictionaryEntry e) => e.dictionaryName).toList();
  }

  RemoteDictionaryCatalogService catalogSharingAppReachability() {
    final SyncRepository repo = SyncRepository(db);
    return RemoteDictionaryCatalogService(
      db: db,
      syncRepository: repo,
      transport: InterconnectPostTransport(repo: repo),
      reachability: app.remoteDictionaryReachabilityForTesting,
    );
  }

  test('掉线：首查付一次并判死，之后的查词零请求、只出本机结果', () async {
    hostDown = true;
    expect(await searchDictionaries(), <String>['JMdict-local']);
    expect(lookupRequests(), 1, reason: '首次发现照常问一次');
    expect(app.isRemoteDictionaryInFailureCooldown, isTrue);

    expect(await searchDictionaries(), <String>['JMdict-local']);
    expect(await searchDictionaries(), <String>['JMdict-local']);
    expect(lookupRequests(), 1, reason: '判死之后查词不再发远端请求');
  });

  test('目录服务先判死 ⇒ 查词一次都不问远端', () async {
    hostDown = true;
    await catalogSharingAppReachability().refresh();
    expect(requests, <String>[kRemoteDictionaryCatalogPath]);
    expect(await searchDictionaries(), <String>['JMdict-local']);
    expect(lookupRequests(), 0);
  });

  test('host 回来：目录刷新成功后的下一次查词立刻合并服务器结果，不等冷却', () async {
    hostDown = true;
    await searchDictionaries();
    expect(app.isRemoteDictionaryInFailureCooldown, isTrue);

    hostDown = false;
    await catalogSharingAppReachability().refresh();
    expect(app.remoteDictionaryHostReachability['srv']!.reachable, isTrue);
    expect(app.isRemoteDictionaryInFailureCooldown, isFalse);

    expect(
      await searchDictionaries(),
      unorderedEquals(<String>['JMdict-local', '大辞林']),
    );
    expect(lookupRequests(), 2);
  });
}
