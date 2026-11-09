import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/remote_dictionary_catalog_service.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
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

  RemoteDictionaryInfo info(String name, {String? revision}) =>
      RemoteDictionaryInfo(
        name: name,
        type: 'term',
        formatKey: 'yomichan',
        revision: revision,
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
      List<FushiClientUrl> urls,
    ) async {
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
  });
}

/// MockClient 里模拟传输层失败（连不上）。
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}
