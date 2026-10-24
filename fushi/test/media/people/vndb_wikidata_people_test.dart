import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/people/person_identity.dart';
import 'package:fushi_engine/media/people/vndb_voice_cast.dart';
import 'package:fushi_engine/media/people/wikidata_person_bridge.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// VNDB 配音表解析 + Wikidata 人物 id 桥（作品图谱 L5）。夹具取自 2026-10-24 实测
/// 回复（`v17` 的 `va` 节选、Q1155136 / Q3273278 的 SPARQL 结果）。
void main() {
  final Map<String, Object?> vn = <String, Object?>{
    'id': 'v17',
    'va': <Object?>[
      <String, Object?>{
        'note': null,
        'character': <String, Object?>{
          'id': 'c32',
          'name': 'Akanegasaki Sora',
          'original': '茜ヶ崎 空',
          'image': <String, Object?>{
            'url': 'https://t.vndb.org/ch/88/119988.jpg',
            'sexual': 0,
          },
        },
        'staff': <String, Object?>{
          'id': 's566',
          'name': 'Kasahara Hiroko',
          'original': '笠原 弘子',
          'extlinks': <Object?>[
            <String, Object?>{'id': 'Hiroko Kasahara', 'name': 'enwiki'},
            <String, Object?>{'id': '1155136', 'name': 'wikidata'},
            <String, Object?>{'id': '167', 'name': 'anidb'},
            <String, Object?>{
              'id': '0e14ded6-0fae-474d-869d-5446345f345e',
              'name': 'musicbrainz_artist',
            },
          ],
        },
      },
      <String, Object?>{
        'note': '幼少期',
        'character': <String, Object?>{
          'id': 'c99',
          'name': 'X',
          'image': <String, Object?>{
            'url': 'https://t/explicit.jpg',
            'sexual': 1.8,
          },
        },
        'staff': <String, Object?>{'id': 's71', 'name': 'Shitaya Noriko'},
      },
      // 同一 (角色, 声优) 重复条目只留一条；缺声优的跳过。
      <String, Object?>{
        'character': <String, Object?>{'id': 'c32', 'name': 'Akanegasaki Sora'},
        'staff': <String, Object?>{'id': 's566', 'name': 'Kasahara Hiroko'},
      },
      <String, Object?>{
        'character': <String, Object?>{'id': 'c1', 'name': 'Y'},
      },
    ],
  };

  test('parseVndbVoiceCast：extlinks 成外部 id、露骨角色图被丢、去重', () {
    final List<GameVoiceCredit> cast = parseVndbVoiceCast(vn);
    expect(cast, hasLength(2));
    expect(cast[0].staffIdNodes, <String>{
      'id:vndb:s566',
      'id:wikidata:Q1155136',
      'id:anidb:167',
      'id:musicbrainz:0e14ded6-0fae-474d-869d-5446345f345e',
    });
    expect(cast[0].characterImageUrl, 'https://t.vndb.org/ch/88/119988.jpg');
    expect(cast[1].characterImageUrl, isNull, reason: 'sexual 1.8 不展示');
    expect(cast[1].note, '幼少期');

    final List<GameVoiceCredit> back = decodeGameVoiceCast(
      encodeGameVoiceCast(cast),
    );
    expect(
      back.map((GameVoiceCredit c) => c.toJson()),
      cast.map((c) => c.toJson()),
    );
    expect(decodeGameVoiceCast('not json'), isEmpty);
  });

  test('VndbVoiceCastClient：请求体带 va 字段；空结果 = 不存在', () async {
    final List<Map<String, Object?>> bodies = <Map<String, Object?>>[];
    int calls = 0;
    final VndbVoiceCastClient client = VndbVoiceCastClient(
      minInterval: Duration.zero,
      client: MockClient((http.Request r) async {
        calls++;
        bodies.add(jsonDecode(r.body) as Map<String, Object?>);
        final Object results = calls == 1 ? <Object?>[vn] : <Object?>[];
        return http.Response(
          jsonEncode(<String, Object?>{'results': results}),
          200,
        );
      }),
    );
    expect((await client.fetch('V17'))!, hasLength(2));
    expect(bodies.single['fields'], kVndbVoiceCastFields);
    expect(bodies.single['filters'], <Object?>['id', '=', 'v17']);
    expect(await client.fetch('v18'), isNull);
    expect(await client.fetch('not-an-id'), isNull);
    expect(calls, 2, reason: '不合法 id 不发请求');
  });

  group('Wikidata 人物桥', () {
    test('查询只收合法 id，按属性分支', () {
      final String q = buildWikidataPersonQuery(<String>[
        'id:anidb:167',
        'id:musicbrainz:0e14ded6-0fae-474d-869d-5446345f345e',
        'id:wikidata:Q3273278',
        'id:anidb:1"}',
        'ref:video:x',
      ])!;
      expect(q, contains('?item wdt:P5649 ?k'));
      expect(q, contains('"167"'));
      expect(q, contains('?item wdt:P434 ?k'));
      expect(q, contains('VALUES ?item { wd:Q3273278 }'));
      expect(q, isNot(contains('1"}')));
      expect(buildWikidataPersonQuery(<String>['ref:video:x']), isNull);
    });

    test('解析绑定并翻成等价集合', () {
      Map<String, Object?> cell(String v) => <String, Object?>{'value': v};
      final Map<String, Set<String>> items = parseWikidataPersonBindings(
        <String, Object?>{
          'results': <String, Object?>{
            'bindings': <Object?>[
              <String, Object?>{
                'item': cell('http://www.wikidata.org/entity/Q1155136'),
                'mal': cell('690'),
                'tmdb': cell('554512'),
                'musicbrainz': cell('0e14ded6-0fae-474d-869d-5446345f345e'),
                'vndb': cell('s566'),
              },
              <String, Object?>{
                'item': cell('http://www.wikidata.org/entity/Q1155136'),
                'vndb': cell('v4'),
              },
            ],
          },
        },
      );
      expect(items['id:wikidata:Q1155136'], <String>{
        'id:wikidata:Q1155136',
        'id:mal:690',
        'id:tmdb:554512',
        'id:musicbrainz:0e14ded6-0fae-474d-869d-5446345f345e',
        'id:vndb:s566',
      }, reason: 'P3180 上的 VN id v4 不算人物 id');
      final Map<String, Set<String>> eq = wikidataPersonEquivalents(<String>[
        'id:mal:690',
        'id:anidb:1',
      ], items);
      expect(eq['id:mal:690'], contains('id:vndb:s566'));
      expect(eq['id:mal:690'], isNot(contains('id:mal:690')));
      expect(eq['id:anidb:1'], isEmpty, reason: '查无结果映射到空集（落「查过」标记）');
    });

    test('非 2xx 抛异常', () async {
      final WikidataPersonBridge bridge = WikidataPersonBridge(
        minInterval: Duration.zero,
        client: MockClient((_) async => http.Response('busy', 429)),
      );
      await expectLater(
        bridge.equivalentsOf(<String>[personIdNode('anidb', '1')!]),
        throwsA(isA<WikidataPersonBridgeException>()),
      );
    });
  });
}
