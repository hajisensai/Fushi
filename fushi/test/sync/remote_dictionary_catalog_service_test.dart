import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/remote_dictionary_catalog_service.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/profile/profile_document.dart'
    show kProfileSettingCategoryRemoteDictionaryMeta;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteDictionaryInfo;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 服务器托管词典目录的对账状态机（新增 / 消失 / 回来 / 目录列更新 / 不可达不动），
/// 以及刷新只问开着「用它查词典」的那台 host。
void main() {
  late FushiDatabase db;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  Future<Map<String, RemoteDictionaryMetaRow>> rows() async =>
      <String, RemoteDictionaryMetaRow>{
        for (final RemoteDictionaryMetaRow r
            in await db.getAllRemoteDictionaryMetadata())
          '${r.hostId}/${r.name}': r,
      };

  RemoteDictionaryInfo info(
    String name, {
    String? revision,
    bool? defaultEnabled,
  }) => RemoteDictionaryInfo(
    name: name,
    type: 'term',
    formatKey: 'yomichan',
    revision: revision,
    defaultEnabled: defaultEnabled,
  );

  group('reconcileHost', () {
    test('新词典默认启用、接在全部已有词典之后（按 host 清单顺序）', () async {
      await db.upsertDictionaryMeta(
        const DictionaryMetadataCompanion(
          name: Value<String>('JMdict'),
          formatKey: Value<String>('yomichan'),
          order: Value<int>(4),
        ),
      );
      final RemoteDictionaryCatalogDiff diff =
          await RemoteDictionaryCatalogService.reconcileHost(
            db,
            hostId: 'h1',
            infos: <RemoteDictionaryInfo>[info('B'), info('A'), info('B')],
            now: 100,
          );
      expect(diff.added, <String>['B', 'A']);
      final Map<String, RemoteDictionaryMetaRow> live = await rows();
      expect(live['h1/B']!.order, 5);
      expect(live['h1/A']!.order, 6);
      expect(live['h1/A']!.hidden, isFalse);
      expect(live['h1/A']!.lastSeenAt, 100);
      expect(live['h1/A']!.missingSince, isNull);
    });

    test('本机已有同名词典（刚推送上去）⇒ 新行沿用本机行的位置与开关，不排到末尾', () async {
      await db.upsertDictionaryMeta(
        const DictionaryMetadataCompanion(
          name: Value<String>('L'),
          formatKey: Value<String>('yomichan'),
          order: Value<int>(3),
          hiddenLanguagesJson: Value<String>('["ja"]'),
        ),
      );
      await db.upsertDictionaryMeta(
        const DictionaryMetadataCompanion(
          name: Value<String>('Z'),
          formatKey: Value<String>('yomichan'),
          order: Value<int>(9),
        ),
      );
      await RemoteDictionaryCatalogService.reconcileHost(
        db,
        hostId: 'h1',
        infos: <RemoteDictionaryInfo>[info('L'), info('N')],
        now: 100,
      );
      final Map<String, RemoteDictionaryMetaRow> live = await rows();
      // 推送上去的 L：沿用本机 order 3 与「已关掉」。
      expect(live['h1/L']!.order, 3);
      expect(live['h1/L']!.hidden, isTrue);
      // 真正的新服务端词典 N：照旧接在全部已有词典之后、默认启用。
      expect(live['h1/N']!.order, 10);
      expect(live['h1/N']!.hidden, isFalse);
    });

    /// 建一个激活配置，快照里放 [entries]（key `<hostId>/<真名>` → {order, hidden}）。
    Future<int> activeProfileWith(Map<String, (int, bool)> entries) async {
      final int profileId = await db.insertProfile(
        ProfilesCompanion.insert(name: 'P', createdAt: 0, updatedAt: 0),
      );
      await db.setPref('active_profile_id', '$profileId');
      for (final MapEntry<String, (int, bool)> e in entries.entries) {
        await db.upsertProfileSetting(
          ProfileSettingsCompanion.insert(
            profileId: profileId,
            category: kProfileSettingCategoryRemoteDictionaryMeta,
            key: e.key,
            value: jsonEncode(<String, Object>{
              'order': e.value.$1,
              'hidden': e.value.$2,
            }),
          ),
        );
      }
      return profileId;
    }

    test('BUG-4276：激活配置快照有这本 ⇒ 新行取快照的顺序与开关（压过本机同名与 host 默认）', () async {
      await db.upsertDictionaryMeta(
        const DictionaryMetadataCompanion(
          name: Value<String>('L'),
          formatKey: Value<String>('yomichan'),
          order: Value<int>(3),
          hiddenLanguagesJson: Value<String>('[]'),
        ),
      );
      final int profileId = await activeProfileWith(<String, (int, bool)>{
        // 本机同名 L 是 order 3、开着；快照说 order 1、关着 ⇒ 快照赢。
        'h1/L': (1, true),
        // host 默认关；快照说开着、排第 0 ⇒ 快照赢。
        'h1/Off': (0, false),
        // host 默认开；快照说关着、排在很后面。
        'h1/On': (20, true),
        // 别的 host 的同名条目不串。
        'h2/N': (0, true),
      });
      // 坏行跳过。
      await db.upsertProfileSetting(
        ProfileSettingsCompanion.insert(
          profileId: profileId,
          category: kProfileSettingCategoryRemoteDictionaryMeta,
          key: 'h1/Bad',
          value: 'not json',
        ),
      );
      await RemoteDictionaryCatalogService.reconcileHost(
        db,
        hostId: 'h1',
        infos: <RemoteDictionaryInfo>[
          info('L'),
          info('Off', defaultEnabled: false),
          info('On', defaultEnabled: true),
          info('N'),
          info('Bad', defaultEnabled: false),
        ],
        now: 1,
      );
      final Map<String, RemoteDictionaryMetaRow> live = await rows();
      expect(live['h1/L']!.order, 1);
      expect(live['h1/L']!.hidden, isTrue);
      expect(live['h1/Off']!.order, 0);
      expect(live['h1/Off']!.hidden, isFalse);
      expect(live['h1/On']!.order, 20);
      expect(live['h1/On']!.hidden, isTrue);
      // 快照里没有（只有 h2 的同名）⇒ 照旧：接在末尾（排在快照给的 20 之后）、默认启用。
      expect(live['h1/N']!.order, 21);
      expect(live['h1/N']!.hidden, isFalse);
      // 坏行当没有：按 host 默认关、接在末尾。
      expect(live['h1/Bad']!.order, 22);
      expect(live['h1/Bad']!.hidden, isTrue);
    });

    test('BUG-4276：快照只播种新行，已有行的配置列不被它改', () async {
      await RemoteDictionaryCatalogService.reconcileHost(
        db,
        hostId: 'h1',
        infos: <RemoteDictionaryInfo>[info('A')],
        now: 1,
      );
      await db.setRemoteDictionaryProfileColumns(
        hostId: 'h1',
        name: 'A',
        order: 7,
        hidden: false,
      );
      await activeProfileWith(<String, (int, bool)>{'h1/A': (0, true)});
      await RemoteDictionaryCatalogService.reconcileHost(
        db,
        hostId: 'h1',
        infos: <RemoteDictionaryInfo>[info('A')],
        now: 2,
      );
      final RemoteDictionaryMetaRow row = (await rows())['h1/A']!;
      expect(row.order, 7);
      expect(row.hidden, isFalse);
    });

    test('刷新保留配置列；目录列（版本）照常更新', () async {
      await RemoteDictionaryCatalogService.reconcileHost(
        db,
        hostId: 'h1',
        infos: <RemoteDictionaryInfo>[info('A', revision: 'r1')],
        now: 1,
      );
      await db.setRemoteDictionaryProfileColumns(
        hostId: 'h1',
        name: 'A',
        order: 42,
        hidden: true,
      );
      final RemoteDictionaryCatalogDiff diff =
          await RemoteDictionaryCatalogService.reconcileHost(
            db,
            hostId: 'h1',
            infos: <RemoteDictionaryInfo>[info('A', revision: 'r2')],
            now: 2,
          );
      expect(diff.isEmpty, isTrue);
      final RemoteDictionaryMetaRow row = (await rows())['h1/A']!;
      expect(row.revision, 'r2');
      expect(row.lastSeenAt, 2);
      expect(row.order, 42);
      expect(row.hidden, isTrue);
    });

    test('新行按 host 默认开关初始化 hidden；已有行的开关从不被它改', () async {
      await RemoteDictionaryCatalogService.reconcileHost(
        db,
        hostId: 'h1',
        infos: <RemoteDictionaryInfo>[
          info('Off', defaultEnabled: false),
          info('On', defaultEnabled: true),
          info('Old'),
        ],
        now: 1,
      );
      Map<String, RemoteDictionaryMetaRow> live = await rows();
      expect(live['h1/Off']!.hidden, isTrue);
      expect(live['h1/On']!.hidden, isFalse);
      expect(live['h1/Old']!.hidden, isFalse, reason: '老 host 不发 = 启用');

      // 本机配置改了开关之后，host 的默认开关再怎么变都不回写已有行。
      await db.setRemoteDictionaryProfileColumns(
        hostId: 'h1',
        name: 'Off',
        order: live['h1/Off']!.order,
        hidden: false,
      );
      await RemoteDictionaryCatalogService.reconcileHost(
        db,
        hostId: 'h1',
        infos: <RemoteDictionaryInfo>[
          info('Off', defaultEnabled: false),
          info('On', defaultEnabled: false),
          info('Old', defaultEnabled: false),
        ],
        now: 2,
      );
      live = await rows();
      expect(live['h1/Off']!.hidden, isFalse);
      expect(live['h1/On']!.hidden, isFalse);
      expect(live['h1/Old']!.hidden, isFalse);
    });

    test('消失记 missingSince（行与设置保留）；回来清掉；别的 host 不受影响', () async {
      await RemoteDictionaryCatalogService.reconcileHost(
        db,
        hostId: 'h1',
        infos: <RemoteDictionaryInfo>[info('A'), info('B')],
        now: 1,
      );
      await RemoteDictionaryCatalogService.reconcileHost(
        db,
        hostId: 'h2',
        infos: <RemoteDictionaryInfo>[info('A')],
        now: 1,
      );
      await db.setRemoteDictionaryProfileColumns(
        hostId: 'h1',
        name: 'B',
        order: 7,
        hidden: true,
      );

      RemoteDictionaryCatalogDiff diff =
          await RemoteDictionaryCatalogService.reconcileHost(
            db,
            hostId: 'h1',
            infos: <RemoteDictionaryInfo>[info('A')],
            now: 10,
          );
      expect(diff.missing, <String>['B']);
      Map<String, RemoteDictionaryMetaRow> live = await rows();
      expect(live['h1/B']!.missingSince, 10);
      expect(live['h1/B']!.hidden, isTrue);
      expect(live['h2/A']!.missingSince, isNull);

      // 再刷新一次仍不在：时刻不刷新。
      diff = await RemoteDictionaryCatalogService.reconcileHost(
        db,
        hostId: 'h1',
        infos: <RemoteDictionaryInfo>[info('A')],
        now: 20,
      );
      expect(diff.isEmpty, isTrue);
      expect((await rows())['h1/B']!.missingSince, 10);

      diff = await RemoteDictionaryCatalogService.reconcileHost(
        db,
        hostId: 'h1',
        infos: <RemoteDictionaryInfo>[info('A'), info('B')],
        now: 30,
      );
      expect(diff.reappeared, <String>['B']);
      live = await rows();
      expect(live['h1/B']!.missingSince, isNull);
      expect(live['h1/B']!.order, 7, reason: '回来的词典沿用原来的顺序 / 开关');
      expect(live['h1/B']!.hidden, isTrue);
    });

    test('清单回包不是数组时不当成「一本都没有」', () {
      expect(
        RemoteDictionaryCatalogService.remoteDictionaryInfosFromJson(
          <String, Object?>{'error': 'x'},
        ),
        isNull,
      );
      expect(
        RemoteDictionaryCatalogService.remoteDictionaryInfosFromJson(<Object?>[
          <String, Object?>{'name': 'A', 'type': 'term'},
          <String, Object?>{'name': '', 'type': 'term'},
          'junk',
        ])!.map((RemoteDictionaryInfo i) => i.name),
        <String>['A'],
      );
    });
  });

  group('refresh', () {
    late List<Uri> requested;
    late Map<String, http.Response Function()> responses;

    Future<RemoteDictionaryCatalogService> service(
      List<FushiClientUrl> urls, {
      RemoteDictionaryReachability? reachability,
    }) async {
      final SyncRepository repo = SyncRepository(db);
      await repo.setFushiClientUrls(urls);
      await repo.setFushiClientToken('tok');
      return RemoteDictionaryCatalogService(
        db: db,
        syncRepository: repo,
        transport: InterconnectPostTransport(
          repo: repo,
          httpClient: MockClient((http.Request request) async {
            requested.add(request.url);
            expect(request.method, 'GET');
            expect(
              request.headers['Authorization'],
              'Basic ${base64Encode(utf8.encode('hibiki:tok'))}',
            );
            final http.Response Function()? respond =
                responses[request.url.host];
            if (respond == null) throw const SocketExceptionLike();
            return respond();
          }),
        ),
        reachability: reachability,
        now: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );
    }

    setUp(() {
      requested = <Uri>[];
      responses = <String, http.Response Function()>{};
    });

    test('只问开着「用它查词典」的 host，按 host 归档', () async {
      responses['h1'] = () => http.Response(
        jsonEncode(<Object?>[
          <String, Object?>{'name': 'Daijirin', 'type': 'term'},
        ]),
        200,
      );
      responses['h2'] = () => http.Response('[]', 200);
      final RemoteDictionaryCatalogService catalog =
          await service(const <FushiClientUrl>[
            FushiClientUrl(url: 'http://h1:8765', hostId: 'host-1'),
            FushiClientUrl(
              url: 'http://h2:8765',
              hostId: 'host-2',
              lookupEnabled: false,
            ),
          ]);
      final Map<String, RemoteDictionaryCatalogDiff> diffs = await catalog
          .refresh();
      expect(requested.map((Uri u) => u.host), <String>['h1']);
      expect(requested.single.path, kRemoteDictionaryCatalogPath);
      expect(diffs.keys, <String>['host-1']);
      expect((await rows()).keys, <String>['host-1/Daijirin']);
    });

    test('不可达 / 老 host（404）不改任何行', () async {
      await RemoteDictionaryCatalogService.reconcileHost(
        db,
        hostId: 'host-1',
        infos: <RemoteDictionaryInfo>[info('A')],
        now: 1,
      );
      final RemoteDictionaryCatalogService catalog = await service(
        const <FushiClientUrl>[
          FushiClientUrl(url: 'http://h1:8765', hostId: 'host-1'),
        ],
      );
      // 不可达。
      expect(await catalog.refresh(), isEmpty);
      expect((await rows())['host-1/A']!.missingSince, isNull);
      // 老 host：没有这个端点。
      responses['h1'] = () => http.Response('not found', 404);
      expect(await catalog.refresh(), isEmpty);
      expect((await rows())['host-1/A']!.missingSince, isNull);
      expect(requested, hasLength(2));
    });

    test('配对列表里新出现的查词 host 立刻拉一次目录', () async {
      responses['h3'] = () => http.Response(
        jsonEncode(<Object?>[
          <String, Object?>{'name': 'Meikyo', 'type': 'term'},
        ]),
        200,
      );
      final RemoteDictionaryCatalogService catalog = await service(
        const <FushiClientUrl>[],
      );
      catalog.start();
      addTearDown(catalog.dispose);
      // start 记下初始（空）集合。
      await catalog.refresh();
      await SyncRepository(db).setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://h3:8765', hostId: 'host-3'),
      ]);
      // 监听回调排在刷新串行链上：再排一次刷新即等到它跑完。
      await catalog.refreshHost('host-3');
      expect(requested.where((Uri u) => u.host == 'h3'), hasLength(2));
      expect((await rows()).keys, <String>['host-3/Meikyo']);
    });

    // ── BUG-4275：目录服务与查词共用一份可达性 ─────────────────────────────
    const List<FushiClientUrl> oneHost = <FushiClientUrl>[
      FushiClientUrl(url: 'http://h1:8765', hostId: 'host-1'),
    ];

    test('可达性按传输层记：连不上 = 判死；老 host 的 404 = 活着（查词照发）', () async {
      final RemoteDictionaryReachability reach = RemoteDictionaryReachability();
      final RemoteDictionaryCatalogService catalog = await service(
        oneHost,
        reachability: reach,
      );
      expect(identical(catalog.reachability, reach), isTrue);
      await catalog.refresh();
      expect(reach.isUnreachable('host-1'), isTrue);
      expect(catalog.hostReachability['host-1']!.failingSince, isNotNull);
      responses['h1'] = () => http.Response('not found', 404);
      await catalog.refresh();
      expect(reach.isUnreachable('host-1'), isFalse);
      expect(reach.shouldSkip('host-1'), isFalse);
    });

    test('判死之后后台按间隔自动再探，host 回来不需要任何人点刷新', () async {
      final RemoteDictionaryReachability reach = RemoteDictionaryReachability(
        reprobeInterval: const Duration(milliseconds: 50),
      );
      final RemoteDictionaryCatalogService catalog = await service(
        oneHost,
        reachability: reach,
      );
      catalog.start();
      addTearDown(catalog.dispose);
      await catalog.refresh();
      expect(reach.isUnreachable('host-1'), isTrue);
      expect(reach.shouldSkip('host-1'), isTrue, reason: '挂着探测：查词一直跳过');
      final int before = requested.length;
      responses['h1'] = () => http.Response(
        jsonEncode(<Object?>[
          <String, Object?>{'name': 'Daijirin', 'type': 'term'},
        ]),
        200,
      );
      final Stopwatch sw = Stopwatch()..start();
      while (reach.isUnreachable('host-1') && sw.elapsed.inSeconds < 5) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(reach.hosts['host-1']!.reachable, isTrue);
      expect(requested.length, greaterThan(before));
      // 探通顺带对账了目录。
      await catalog.refreshHost('host-1');
      expect((await rows()).keys, <String>['host-1/Daijirin']);
    });

    test('回前台：判死的 host 不受 10 分钟节流，立刻再探', () async {
      final RemoteDictionaryReachability reach = RemoteDictionaryReachability(
        reprobeInterval: const Duration(hours: 1),
      );
      final RemoteDictionaryCatalogService catalog = await service(
        oneHost,
        reachability: reach,
      );
      responses['h1'] = () => http.Response('[]', 200);
      await catalog.refresh(); // 成功：记下 lastFetched
      responses.remove('h1');
      await catalog.refresh(); // 掉线
      expect(reach.isUnreachable('host-1'), isTrue);
      responses['h1'] = () => http.Response('[]', 200);
      final int before = requested.length;
      await catalog.refreshOnResume();
      expect(requested.length, before + 1);
      expect(reach.hosts['host-1']!.reachable, isTrue);
      // 可达的 host 照旧受节流。
      await catalog.refreshOnResume();
      expect(requested.length, before + 1);
    });

    test('配对列表变化：已知判死的 host 立刻再探', () async {
      final RemoteDictionaryReachability reach = RemoteDictionaryReachability(
        reprobeInterval: const Duration(hours: 1),
      );
      final RemoteDictionaryCatalogService catalog = await service(
        oneHost,
        reachability: reach,
      );
      catalog.start();
      addTearDown(catalog.dispose);
      await catalog.refresh();
      expect(reach.isUnreachable('host-1'), isTrue);
      // 同一台 host 换了地址（单地址，避开组内选路的真网络探测）。
      responses['h1b'] = () => http.Response('[]', 200);
      await SyncRepository(db).setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://h1b:8765', hostId: 'host-1'),
      ]);
      // 监听回调排在串行链上：再排一个空任务等它跑完。
      await catalog.refreshOnResume();
      expect(requested.map((Uri u) => u.host), contains('h1b'));
      expect(reach.hosts['host-1']!.reachable, isTrue);
    });
  });
}

/// MockClient 里模拟传输层失败（连不上）。
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}
