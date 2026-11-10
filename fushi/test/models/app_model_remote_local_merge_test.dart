import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// 用户拍板（2026-11-09）：本机与服务器查词结果**合并**，不再远端优先独占。
/// 走真实的 `AppModel.searchDictionary`：本机那份经查词结果缓存命中，服务器那份由
/// 回环地址上的假 host 应答（真 HTTP、真远端查词客户端）。
void main() {
  late FushiDatabase db;
  late HttpServer host;
  late AppModel app;
  late DictionaryRepository dictRepo;
  late Directory tmpDir;
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];
  Map<String, dynamic>? hostReply;

  const String term = '食べる';
  const int maxTerms = 10;

  FushiLookupResult row(
    String reading,
    List<String> dicts, {
    String side = 'server',
  }) => FushiLookupResult(
    matched: term,
    deinflected: term,
    trace: const <FushiTransformGroup>[],
    preprocessorSteps: 0,
    term: FushiTermResult(
      expression: term,
      reading: reading,
      rules: '',
      glossaries: <FushiGlossaryEntry>[
        for (final String d in dicts)
          FushiGlossaryEntry(
            dictName: d,
            glossary: jsonEncode('$side $d'),
            definitionTags: '',
            termTags: '',
          ),
      ],
      frequencies: const <FushiFrequencyEntry>[],
      pitches: const <FushiPitchEntry>[],
    ),
  );

  DictionarySearchResult resultOf(List<FushiLookupResult> rows) {
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

  setUp(() async {
    requests.clear();
    hostReply = null;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host.listen((HttpRequest request) async {
      final String body = await utf8.decodeStream(request);
      requests.add(<String, dynamic>{
        'path': request.uri.path,
        if (body.isNotEmpty) 'body': jsonDecode(body),
      });
      final Map<String, dynamic>? reply = hostReply;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(reply ?? <String, dynamic>{'type': 'dictionaryResult'}),
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
    // 本机装着并启用了 Jitendex：服务器上同名的那本要被本机这本去重。
    await dictRepo.persistDictionary(
      Dictionary(name: 'Jitendex', formatKey: 'yomitan', order: 0),
    );
    await dictRepo.persistDictionary(
      Dictionary(name: 'JMdict-local', formatKey: 'yomitan', order: 1),
    );
    tmpDir = Directory.systemTemp.createTempSync('fushi_remote_local_merge_');
    app = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefsRepo,
        databaseDirectory: tmpDir,
      )
      ..wireDatabaseForTesting(db, dictionaryRepository: dictRepo);
    // 引擎装载（分桶后登记术语桶成员）在单测里不跑：直接登记两本都已装进引擎。
    dictRepo.noteEngineTermDictionaries(<String>['Jitendex', 'JMdict-local']);
  });

  tearDown(() async {
    await host.close(force: true);
    dictRepo.dispose();
    await db.close();
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  void cacheLocal(DictionarySearchResult result) => dictRepo.cacheSearchResult(
    buildSearchCacheKey(term: term, maxTerms: maxTerms, maxResults: maxTerms),
    result,
  );

  void replyWith(DictionarySearchResult remote) {
    hostReply = <String, dynamic>{
      'type': 'dictionaryResult',
      'result': jsonDecode(remote.toJson()),
      'popupJson': remote.popupJson,
    };
  }

  Future<DictionarySearchResult> search() => app.searchDictionary(
    searchTerm: term,
    searchWithWildcards: false,
    overrideMaximumTerms: maxTerms,
  );

  List<String> popupDictionaries(DictionarySearchResult r) => <String>[
    for (final dynamic group in jsonDecode(r.popupJson!) as List<dynamic>)
      for (final dynamic g in (group as Map<String, dynamic>)['glossaries'])
        (g as Map<String, dynamic>)['dictionary'] as String,
  ];

  test('本机与服务器都有结果 ⇒ 合并成一份，服务器同名词典被本机那本去重', () async {
    // 本机：Jitendex（服务器也有）+ 本机独有的 JMdict-local；服务器：Jitendex + 大辞林。
    // 远端优先独占的旧行为会丢掉 JMdict-local、并用服务器那份 Jitendex。
    final DictionarySearchResult local = resultOf(<FushiLookupResult>[
      row('たべる', <String>['Jitendex', 'JMdict-local'], side: 'local'),
    ]);
    cacheLocal(local);
    replyWith(
      resultOf(<FushiLookupResult>[
        row('たべる', <String>['Jitendex', '大辞林'], side: 'server'),
      ]),
    );

    final DictionarySearchResult merged = await search();

    expect(
      requests.where(
        (Map<String, dynamic> r) => r['path'] == '/api/lookup/dictionary',
      ),
      hasLength(1),
      reason: '服务器确实被问到了',
    );
    expect(
      merged.entries
          .map((DictionaryEntry e) => '${e.dictionaryName}=${e.meaning}')
          .toList(),
      <String>[
        'Jitendex="local Jitendex"',
        'JMdict-local="local JMdict-local"',
        '大辞林="server 大辞林"',
      ],
      reason: '本机词典（混排顺序在前）留本机那份，服务器同名 Jitendex 被去重',
    );
    expect(popupDictionaries(merged), <String>[
      'Jitendex',
      'JMdict-local',
      '大辞林',
    ]);
    expect(merged.headwordCount, 1);

    // 合并结果不进缓存：本机缓存里仍是本机那份。
    final DictionarySearchResult localOnly = await app.searchDictionary(
      searchTerm: term,
      searchWithWildcards: false,
      overrideMaximumTerms: maxTerms,
      allowRemoteLookup: false,
    );
    expect(identical(localOnly, local), isTrue);
  });

  // 审查发现：去重名单以前按「视图里开着」算，可本机引擎只装激活配置开着、目录在且
  // 已物化的词典。工作配置开着而激活配置关着（或目录缺失 / 未物化）的词典本机查不
  // 出来，服务器那份却被当成「本机已有」丢掉——整本从弹窗里消失。
  test('视图开着但本机引擎没装的词典 ⇒ 留服务器那份', () async {
    // Jitendex 元数据上开着，但不在引擎术语桶里（目录未物化 / 激活配置关着）。
    dictRepo.noteEngineTermDictionaries(<String>['JMdict-local']);
    cacheLocal(
      resultOf(<FushiLookupResult>[
        row('たべる', <String>['JMdict-local'], side: 'local'),
      ]),
    );
    replyWith(
      resultOf(<FushiLookupResult>[
        row('たべる', <String>['Jitendex', '大辞林'], side: 'server'),
      ]),
    );

    final DictionarySearchResult merged = await search();

    expect(
      merged.entries
          .map((DictionaryEntry e) => '${e.dictionaryName}=${e.meaning}')
          .toList(),
      <String>[
        'Jitendex="server Jitendex"',
        'JMdict-local="local JMdict-local"',
        '大辞林="server 大辞林"',
      ],
      reason: '本机引擎里没有 Jitendex：服务器那份不被去重',
    );
    expect(popupDictionaries(merged), <String>[
      'Jitendex',
      'JMdict-local',
      '大辞林',
    ]);
  });

  // 用户拍板（2026-11-09）：没有全局「远程查词」开关了，总闸由配对 host 的「用这台
  // 服务器查词典」派生；拨 host 开关（词典管理页卡片的写入口）立刻反映到总闸。
  test('remoteLookupEnabled 由 host 开关派生：关掉唯一一台 ⇒ 关，再打开 ⇒ 开', () async {
    expect(app.remoteLookupEnabled, isTrue, reason: '配对了一台默认开着查词的 host');
    await app.setRemoteDictionaryHostLookupEnabled('srv', false);
    expect(app.remoteLookupEnabled, isFalse);
    expect(
      (await SyncRepository(db).getFushiClientUrls()).single.lookupEnabled,
      isFalse,
    );
    await app.setRemoteDictionaryHostLookupEnabled('srv', true);
    expect(app.remoteLookupEnabled, isTrue);
    // 停用这条地址同样让它退出查词（isDictionaryLookupCandidate = enabled && lookupEnabled）。
    await SyncRepository(db).updateFushiClientUrls(
      (List<FushiClientUrl> urls) => <FushiClientUrl>[
        for (final FushiClientUrl u in urls) u.copyWith(enabled: false),
      ],
    );
    await dictRepo.reloadRemoteDictionaries();
    expect(app.remoteLookupEnabled, isFalse);
  });

  test('服务器没有结果 ⇒ 原样返回本机那份', () async {
    final DictionarySearchResult local = resultOf(<FushiLookupResult>[
      row('たべる', <String>['Jitendex']),
    ]);
    cacheLocal(local);
    final DictionarySearchResult result = await search();
    expect(
      requests.where(
        (Map<String, dynamic> r) => r['path'] == '/api/lookup/dictionary',
      ),
      hasLength(1),
    );
    expect(identical(result, local), isTrue);
  });
  test('本机没有结果（引擎未就绪）⇒ 原样用服务器那份，不去重', () async {
    replyWith(
      resultOf(<FushiLookupResult>[
        row('たべる', <String>['Jitendex', '大辞林']),
      ]),
    );
    final DictionarySearchResult result = await search();
    expect(
      result.entries.map((DictionaryEntry e) => e.dictionaryName).toList(),
      <String>['Jitendex', '大辞林'],
    );
  });
}
