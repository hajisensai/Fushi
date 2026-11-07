import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_view_model.dart'
    show ankiRepositoryProvider;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_dictionary_routes.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';

import '../helpers/test_platform_services.dart';

const String kToken = 'ctl-mine-remote-lookup-token';
const String kHostDict = 'Fushi Smoke Dict';

/// host 的词典：只有它认识「漢字」。
class _HostLookup implements FushiRemoteLookupService {
  final List<String> terms = <String>[];

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    terms.add(term);
    if (term != '漢字') return null;
    return DictionarySearchResult(
      searchTerm: term,
      bestLength: term.length,
      entries: <DictionaryEntry>[
        DictionaryEntry(
          dictionaryName: kHostDict,
          word: '漢字',
          reading: 'かんじ',
          meaning: 'Chinese character',
        ),
      ],
    );
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
}

/// 记下 `anki mine` 交给制卡链路的字段（真正落卡不在本测试范围）。
class _CapturingAnki implements BaseAnkiRepository {
  final List<Map<String, Object?>> mined = <Map<String, Object?>>[];

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    mined.add((jsonDecode(rawPayloadJson) as Map).cast<String, Object?>());
    return const MineOutcome(MineResult.success, deckName: 'Default');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected ${invocation.memberName}');
}

/// 路由只用 `ref.read`：交给真 [ProviderContainer]。
class _ContainerRef implements WidgetRef {
  _ContainerRef(this.container);

  final ProviderContainer container;

  @override
  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected ${invocation.memberName}');
}

/// BUG-4233：客户端本机没有词典、开着「远端查词」（查词页能显示 host 的词条），`fushi_cli anki mine -w 漢字`
/// 却建出释义为空的卡——控制通道查词用的是**替对端**查词的服务（只查本机词典），不是查词页的远端优先链。
///
/// 真 host（FushiSyncServer 的 `/api/lookup/dictionary`，词典由 [_HostLookup] 提供）+ 真客户端 AppModel
/// （只接了数据库与偏好、本机词典引擎没起 = 瘦客户端）+ 控制通道真路由。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory dataDir;
  late FushiSyncServer server;
  late _HostLookup hostLookup;
  late FushiDatabase db;
  late AppModel app;
  late _CapturingAnki anki;
  late ProviderContainer container;
  late List<CtlRoute> routes;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('fushi_ctl_mine_remote_');
    hostLookup = _HostLookup();
    server = FushiSyncServer(
      syncDataDir: dataDir.path,
      port: 0,
      token: kToken,
      allowLan: false,
      remoteLookupService: hostLookup,
    );
    await server.start();

    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    final SyncRepository repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${server.port}', enabled: true),
    ]);
    await repo.setFushiClientToken(kToken);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    await prefs.setRemoteLookupEnabled(true);
    // 本机词典仓库为空（瘦客户端）：查词必须走远端优先那条链才有结果。
    final DictionaryRepository dictRepo = DictionaryRepository(db);
    await dictRepo.loadFromDb();
    addTearDown(dictRepo.dispose);
    app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db, dictionaryRepository: dictRepo)
      ..wirePreferencesForTesting(prefs);

    anki = _CapturingAnki();
    container = ProviderContainer(
      overrides: <Override>[
        appProvider.overrideWith((_) => app),
        ankiRepositoryProvider.overrideWith((Ref ref) => anki),
      ],
    );
    routes = buildDictionaryCtlRoutes(
      OpContext(ref: _ContainerRef(container), focusMainWindow: () async {}),
    );
  });

  tearDown(() async {
    container.dispose();
    await server.stop();
    await db.close();
    try {
      dataDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  Future<Object?> call(
    String method,
    String path, {
    Map<String, String> query = const <String, String>{},
    Map<String, Object?> body = const <String, Object?>{},
  }) {
    for (final CtlRoute route in routes) {
      if (route.method != method) continue;
      final Map<String, String>? params = route.match(path);
      if (params == null) continue;
      return route.handler(
        CtlCall(
          method: method,
          path: path,
          params: params,
          query: query,
          body: body,
        ),
      );
    }
    throw StateError('没有路由 $method $path');
  }

  test('anki mine：读音 / 释义取自 host 的词典（与查词页同一条远端优先链）', () async {
    final Map<String, Object?> res =
        (await call(
              'POST',
              '/api/admin/anki/mine',
              body: <String, Object?>{'word': '漢字'},
            ))!
            as Map<String, Object?>;
    expect(res['ok'], isTrue);
    expect(hostLookup.terms, contains('漢字'), reason: '查词问到了 host');
    final Map<String, Object?> fields = anki.mined.single;
    expect(fields['expression'], '漢字');
    expect(fields['reading'], 'かんじ');
    expect(fields['glossary'], contains('Chinese character'));
    expect(fields['glossary'], contains(kHostDict));
  });

  test('dict search：同一条链，瘦客户端能查到 host 的词条', () async {
    final Map<String, Object?> res =
        (await call(
              'GET',
              '/api/admin/dictionaries/search',
              query: <String, String>{'term': '漢字'},
            ))!
            as Map<String, Object?>;
    final List<Object?> entries = res['entries']! as List<Object?>;
    expect(entries, hasLength(1));
    final Map<Object?, Object?> entry =
        entries.single! as Map<Object?, Object?>;
    expect(entry['dictionary'], kHostDict);
    expect(entry['reading'], 'かんじ');
  });

  test('替对端查词的服务仍只查本机词典：不把请求再转给 host（防止互为 host 时互相转发）', () async {
    final DictionarySearchResult? viaHostService = await app
        .createRemoteLookupService()
        .searchDictionary(term: '漢字', wildcards: false, maximumTerms: 10);
    expect(viaHostService, isNull);
    expect(hostLookup.terms, isEmpty);
  });
}
