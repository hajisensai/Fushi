import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/links/media_link_inference_host.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/links/wikidata_anime_bridge.dart';
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Wikidata id 桥（VNDB → AniDB）。fixture 截自 2026-10-24 经代理对
/// query.wikidata.org 的真实回复（Clannad = VNDB v4 → AniDB 4402 / 5101，Wikidata
/// 对同一动画条目会重复返回绑定行）。全部离线，不联网。
const String _clannadFixture = '''
{"head":{"vars":["vndb","anime","anidb"]},"results":{"bindings":[
{"vndb":{"type":"literal","value":"v4"},"anime":{"type":"uri","value":"http://www.wikidata.org/entity/Q1037699"},"anidb":{"type":"literal","value":"4402"}},
{"vndb":{"type":"literal","value":"v4"},"anime":{"type":"uri","value":"http://www.wikidata.org/entity/Q1095034"},"anidb":{"type":"literal","value":"5101"}},
{"vndb":{"type":"literal","value":"v4"},"anime":{"type":"uri","value":"http://www.wikidata.org/entity/Q1037699"},"anidb":{"type":"literal","value":"4402"}}
]}}
''';

void main() {
  test('属性编号钉死（2026-10-24 wbgetentities 实测）；查询只拼校验过的 VNDB id', () {
    expect(kWikidataVndbIdProperty, 'P3180');
    expect(kWikidataAnidbAnimeIdProperty, 'P5646');
    expect(kWikidataBasedOnProperty, 'P144');
    expect(kWikidataDerivativeWorkProperty, 'P4969');
    expect(normalizeVndbVnId('V4'), 'v4');
    expect(normalizeVndbVnId('17'), 'v17');
    expect(normalizeVndbVnId('v4" } ?x ?y {'), isNull, reason: '杜绝 SPARQL 注入');
    final String q = buildWikidataVndbToAnidbQuery(<String>['v4', 'v17']);
    expect(q, contains('VALUES ?vndb { "v4" "v17" }'));
    expect(q, contains('wdt:P144'));
    expect(q, contains('wdt:P4969'));
  });

  test('解析真实回复：去重、按 VN 分组', () {
    expect(
      parseWikidataVndbToAnidb(jsonDecode(_clannadFixture)),
      <String, Set<String>>{
        'v4': <String>{'4402', '5101'},
      },
    );
    expect(
      () => parseWikidataVndbToAnidb(<String, Object?>{'oops': 1}),
      throwsA(isA<WikidataBridgeException>()),
    );
  });

  test('规范 UA、按 VN 缓存（含空结果）、非 2xx 抛错且不缓存失败', () async {
    final List<http.Request> requests = <http.Request>[];
    int status = 200;
    final WikidataAnimeBridge bridge = WikidataAnimeBridge(
      minInterval: Duration.zero,
      client: MockClient((http.Request r) async {
        requests.add(r);
        return http.Response(
          status == 200 ? _clannadFixture : 'busy',
          status,
          headers: <String, String>{
            'content-type': 'application/sparql-results+json',
          },
        );
      }),
    );
    final Map<String, Set<String>> first = await bridge.anidbIdsForVndb(
      <String>['v4', 'v99'],
    );
    expect(first['v4'], <String>{'4402', '5101'});
    expect(first['v99'], isEmpty, reason: '没有改编的 VN 映射到空集');
    expect(requests, hasLength(1));
    expect(requests.single.headers['User-Agent'], startsWith('fushi/'));
    expect(requests.single.headers['User-Agent'], contains('https://'));

    await bridge.anidbIdsForVndb(<String>['v4', 'v99']);
    expect(requests, hasLength(1), reason: '两部 VN 都在缓存里（空结果也缓存）');

    status = 503;
    await expectLater(
      bridge.anidbIdsForVndb(<String>['v17']),
      throwsA(isA<WikidataBridgeException>()),
    );
    status = 200;
    await bridge.anidbIdsForVndb(<String>['v17']);
    expect(requests, hasLength(3), reason: '失败不缓存，下次重查');
  });

  test(
    '游戏页推断：VNDB → Wikidata → 本地视频 AniDB id，写成 source=wikidata 的建议',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g1',
          name: 'CLANNAD',
          exePath: 'Z:\\vn\\clannad\\clannad.exe',
          workdir: 'Z:\\vn\\clannad',
          addedAt: 1,
        ),
      );
      await db.upsertGalgameSource(
        GalgameSourcesCompanion.insert(
          gameId: 'g1',
          source: 'vndb',
          externalId: const Value<String?>('v4'),
          dataJson: '{}',
          fetchedAt: 1,
        ),
      );
      final int afterStory = await db.createMediaCollection('After Story');
      final int unrelated = await db.createMediaCollection('Other Show');
      for (final (int cid, String aid) in <(int, String)>[
        (afterStory, '5101'),
        (unrelated, '1'),
      ]) {
        final int workId = await db
            .into(db.videoMetadataWorks)
            .insert(
              VideoMetadataWorksCompanion.insert(
                collectionId: Value<int?>(cid),
                mediaType: 'tv',
                title: 'w$cid',
                updatedAt: 1,
              ),
            );
        await db
            .into(db.videoMetadataProviderIdentities)
            .insert(
              VideoMetadataProviderIdentitiesCompanion.insert(
                identityKey: 'work:$workId:anidb',
                workId: Value<int?>(workId),
                provider: 'anidb',
                externalId: aid,
                updatedAt: 1,
              ),
            );
      }
      final List<List<String>> asked = <List<String>>[];
      final int added = await runMediaLinkInference(
        db: db,
        self: (kind: MediaLinkKind.game, key: 'g1'),
        fetchMalSourceMaterial: (String _) async => const <MalSourceMaterial>[],
        lookupWikidataAnime: (Iterable<String> ids) async {
          asked.add(ids.toList());
          return parseWikidataVndbToAnidb(jsonDecode(_clannadFixture));
        },
      );
      expect(asked, <List<String>>[
        <String>['v4'],
      ]);
      expect(added, 1);
      final MediaLinkRow row = (await db.allMediaLinks()).single;
      expect(row.source, MediaLinkSource.wikidata);
      expect(row.relation, 'adaptation');
      expect(row.fromKind, 'game', reason: 'VN 是原作');
      expect(row.toKey, '$afterStory');
      expect(row.isUserConfirmed, isFalse, reason: '强判据也只作建议');
      expect(row.confidence, 0.9);
    },
  );
}
