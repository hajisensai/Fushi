// BUG-2970：Emby 媒体服务器搜索「少于四个字都搜不到」。
//
// 按字模糊的服务器（UHD Media Server 这类伪装 Emby 的兼容层）对 1~3 字的短查询
// 回几千行只沾一个字的结果，缺省按相关度排、真命中在最前；客户端此前强制
// `SortBy=SortName`，真命中被按字母序打散到 [JellyfinVideoClient.kSearchScanLimit]
// 之外，把关后一条不剩。假服务器照这个行为建模：带 SortBy=SortName 时真命中埋在
// 第 1200 行之后，不带时（相关度序）排第一。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';

http.Response _json(Object body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

/// 按字模糊 + 相关度的假服务器：[hits] 是真含查询词的条目，另配 [noise] 行只沾
/// 一个字的结果。
class _FuzzyServer {
  _FuzzyServer({required this.hits, this.noise = 1500});

  final List<Map<String, Object?>> hits;
  final int noise;
  final List<http.Request> seen = <http.Request>[];

  MockClient get client => MockClient((http.Request req) async {
    seen.add(req);
    final Map<String, String> q = req.url.queryParameters;
    final String type = q['IncludeItemTypes'] ?? '';
    final List<Map<String, Object?>> rows = <Map<String, Object?>>[
      for (int i = 0; i < noise; i++)
        <String, Object?>{'Id': '$type-noise-$i', 'Name': '沾边$i', 'Type': type},
    ];
    final List<Map<String, Object?>> typed = <Map<String, Object?>>[
      for (final Map<String, Object?> h in hits)
        if (h['Type'] == type) h,
    ];
    final List<Map<String, Object?>> ordered = q['SortBy'] == 'SortName'
        // 名称序：真命中落在沾边行中段之后。
        ? <Map<String, Object?>>[
            ...rows.sublist(0, 1200),
            ...typed,
            ...rows.sublist(1200),
          ]
        // 相关度序（服务器缺省）：真命中最前。
        : <Map<String, Object?>>[...typed, ...rows];
    final int start = int.parse(q['StartIndex'] ?? '0');
    final int limit = int.parse(q['Limit'] ?? '100');
    final int end = (start + limit).clamp(0, ordered.length);
    return _json(<String, Object?>{
      'Items': start >= ordered.length
          ? <Object?>[]
          : ordered.sublist(start, end),
      'TotalRecordCount': ordered.length,
    });
  });
}

JellyfinVideoClient _client(http.Client mock) => JellyfinVideoClient(
  api: JellyfinApi(
    serverUrl: 'http://emby:8096',
    accessToken: 'tok',
    client: mock,
  ),
  userId: 'u1',
);

void main() {
  final List<Map<String, Object?>> hits = <Map<String, Object?>>[
    <String, Object?>{'Id': 's-frieren', 'Name': '葬送的芙莉莲', 'Type': 'Series'},
    <String, Object?>{
      'Id': 's-yurucamp',
      'Name': '摇曳露营△',
      'OriginalTitle': 'ゆるキャン△',
      'Type': 'Series',
    },
    <String, Object?>{'Id': 'm-ghibli', 'Name': '千与千寻', 'Type': 'Movie'},
  ];

  for (final (String query, String expected) in <(String, String)>[
    ('芙莉', 's-frieren'),
    ('莲', 's-frieren'),
    ('ゆる', 's-yurucamp'),
    ('キャン', 's-yurucamp'),
    ('千寻', 'm-ghibli'),
  ]) {
    test('短查询「$query」能搜到（BUG-2970）', () async {
      final _FuzzyServer server = _FuzzyServer(hits: hits);
      final MediaServerPage page = await _client(server.client).search(query);
      expect(page.items.map((MediaServerItem i) => i.id), contains(expected));
      expect(page.items.first.id, expected, reason: '真命中排在把关结果最前');
    });
  }

  test('搜索请求不强制名称排序，其余参数照旧', () async {
    final _FuzzyServer server = _FuzzyServer(hits: hits, noise: 10);
    await _client(server.client).search('芙莉');
    expect(server.seen, isNotEmpty);
    for (final http.Request req in server.seen) {
      final Map<String, String> q = req.url.queryParameters;
      expect(req.url.path, '/Users/u1/Items');
      expect(q['SearchTerm'], '芙莉');
      expect(q['Recursive'], 'true');
      expect(<String>['Movie', 'Series'], contains(q['IncludeItemTypes']));
      expect(q.containsKey('SortBy'), isFalse);
      expect(q.containsKey('SortOrder'), isFalse);
      expect(q['Fields'], contains('OriginalTitle'));
    }
  });
}
