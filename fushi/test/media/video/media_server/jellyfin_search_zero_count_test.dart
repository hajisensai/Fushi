// BUG-3289：Emby 4.8.10 / 4.9.1 对不足 4 个字符的 SearchTerm 把 TotalRecordCount
// 报成 0，Items 却照常给出命中。search() 曾在收下这页之前先比 `localStart >=
// roundTotal`（0 >= 0）就 break，整页命中被丢弃，于是「四字以下搜不到」。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';

http.Response _json(Object body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

/// 子串匹配、短查询总数清零的假 Emby。
class _ZeroCountEmby {
  _ZeroCountEmby(this.catalog);

  final List<Map<String, Object?>> catalog;
  final List<Uri> seen = <Uri>[];

  MockClient get client => MockClient((http.Request req) async {
    seen.add(req.url);
    final Map<String, String> q = req.url.queryParameters;
    final String term = q['SearchTerm'] ?? '';
    final List<Map<String, Object?>> rows = <Map<String, Object?>>[
      for (final Map<String, Object?> item in catalog)
        if (item['Type'] == q['IncludeItemTypes'] &&
            (item['Name']! as String).contains(term))
          item,
    ];
    final int start = int.parse(q['StartIndex'] ?? '0');
    final int limit = int.parse(q['Limit'] ?? '100');
    final int end = (start + limit).clamp(0, rows.length);
    return _json(<String, Object?>{
      'Items': start >= rows.length ? <Object?>[] : rows.sublist(start, end),
      // 实测：SearchTerm 不足 4 字符时恒为 0。
      'TotalRecordCount': term.runes.length < 4 ? 0 : rows.length,
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

Map<String, Object?> _movie(String id, String name) => <String, Object?>{
  'Id': id,
  'Name': name,
  'Type': 'Movie',
};

Map<String, Object?> _series(String id, String name) => <String, Object?>{
  'Id': id,
  'Name': name,
  'Type': 'Series',
};

void main() {
  test('短查询总数为 0 时仍收下命中，两轮都扫到', () async {
    final _ZeroCountEmby server = _ZeroCountEmby(<Map<String, Object?>>[
      _movie('m-1', '千与千寻'),
      _series('s-1', '葬送的芙莉莲'),
      _series('s-2', '进击的巨人'),
    ]);
    final MediaServerPage page = await _client(server.client).search('芙莉');
    expect(page.items.map((MediaServerItem i) => i.id), <String>['s-1']);
    expect(page.hasMore, isFalse);

    final MediaServerPage movie = await _client(server.client).search('千寻');
    expect(movie.items.map((MediaServerItem i) => i.id), <String>['m-1']);
  });

  test('四字以上（总数可信）行为不变，不额外计数', () async {
    final _ZeroCountEmby server = _ZeroCountEmby(<Map<String, Object?>>[
      _series('s-1', '葬送的芙莉莲'),
    ]);
    final MediaServerPage page = await _client(server.client).search('葬送的芙莉');
    expect(page.items.single.id, 's-1');
    // 两轮各一发，没有逐页计数请求。
    expect(server.seen, hasLength(2));
  });

  test('总数不可信且命中超过一页：翻页偏移按真实行数换算，不重不漏', () async {
    final _ZeroCountEmby server = _ZeroCountEmby(<Map<String, Object?>>[
      for (int i = 0; i < 130; i++) _movie('m-$i', '猫$i'),
      for (int i = 0; i < 30; i++) _series('s-$i', '猫剧$i'),
    ]);
    final JellyfinVideoClient client = _client(server.client);
    final List<String> ids = <String>[];
    int start = 0;
    for (int guard = 0; guard < 10; guard++) {
      final MediaServerPage page = await client.search(
        '猫',
        startIndex: start,
        limit: 60,
      );
      ids.addAll(page.items.map((MediaServerItem i) => i.id));
      if (!page.hasMore) break;
      expect(page.nextStartIndex, greaterThan(start));
      start = page.nextStartIndex;
    }
    expect(ids.toSet(), hasLength(160));
    expect(ids, hasLength(160), reason: '不重复');
  });

  group('请求数有上界（总数不可信时不反复逐页数）', () {
    test('一轮数过一次后，翻页不再重数', () async {
      final _ZeroCountEmby server = _ZeroCountEmby(<Map<String, Object?>>[
        for (int i = 0; i < 1000; i++) _movie('m-$i', '猫$i'),
        for (int i = 0; i < 5; i++) _series('s-$i', '猫剧$i'),
      ]);
      final JellyfinVideoClient client = _client(server.client);

      final MediaServerPage first = await client.search('猫', limit: 50);
      // 电影轮首页 1 发 + 逐页数 1000 行（10 满页 + 1 空页）11 发 + 剧集轮只问
      // 1 行判 hasMore 1 发。
      expect(server.seen, hasLength(13));
      expect(first.hasMore, isTrue);

      int start = first.nextStartIndex;
      for (int page = 0; page < 5; page++) {
        server.seen.clear();
        final MediaServerPage next = await client.search(
          '猫',
          startIndex: start,
          limit: 50,
        );
        // 电影轮当前页 1 发 + 剧集轮 1 发；电影轮总数复用已数过的，不再计数。
        expect(
          server.seen,
          hasLength(lessThanOrEqualTo(2)),
          reason: '第 $page 页',
        );
        expect(next.nextStartIndex, greaterThan(start));
        start = next.nextStartIndex;
      }
    });

    test('已凑够时只问 1 行的剧集轮不触发全量计数', () async {
      final _ZeroCountEmby server = _ZeroCountEmby(<Map<String, Object?>>[
        for (int i = 0; i < 150; i++) _movie('m-$i', '猫$i'),
        for (int i = 0; i < 300; i++) _series('s-$i', '猫剧$i'),
      ]);
      final MediaServerPage page = await _client(
        server.client,
      ).search('猫', limit: 50);
      // 电影轮首页 1 发 + 逐页数 150 行 2 发；剧集轮只有 Limit=1 那 1 发。
      expect(server.seen, hasLength(4));
      final Iterable<Uri> seriesRequests = server.seen.where(
        (Uri u) => u.queryParameters['IncludeItemTypes'] == 'Series',
      );
      expect(seriesRequests, hasLength(1));
      expect(seriesRequests.single.queryParameters['Limit'], '1');
      expect(page.hasMore, isTrue);
    });

    test('新搜索（startIndex 0）不复用上一次数出的总数', () async {
      final _ZeroCountEmby server = _ZeroCountEmby(<Map<String, Object?>>[
        for (int i = 0; i < 250; i++) _movie('m-$i', '猫$i'),
      ]);
      final JellyfinVideoClient client = _client(server.client);
      await client.search('猫', limit: 50);
      final int firstCount = server.seen.length;
      server.seen.clear();
      await client.search('猫', limit: 50);
      expect(server.seen, hasLength(firstCount), reason: '重新逐页数，拿服务器最新数据');
    });
  });

  group('searchRoundTotal', () {
    JellyfinItemsPage page(int rows, int total) => JellyfinItemsPage(
      items: List<JellyfinItem>.generate(
        rows,
        (int i) => JellyfinApi.parseItem(<String, Object?>{
          'Id': 'x$i',
          'Name': 'x$i',
          'Type': 'Movie',
        }),
      ),
      totalCount: total,
    );

    Future<int> never() async => fail('不该逐页计数');

    test('总数与数据一致：用服务器的', () async {
      expect(
        await JellyfinVideoClient.searchRoundTotal(
          page: page(100, 500),
          startIndex: 0,
          requested: 100,
          measure: never,
        ),
        500,
      );
    });

    test('总数被清零、这页没要满：本轮到此为止', () async {
      expect(
        await JellyfinVideoClient.searchRoundTotal(
          page: page(50, 0),
          startIndex: 0,
          requested: 100,
          measure: never,
        ),
        50,
      );
    });

    test('总数被清零、这页满了：逐页数', () async {
      expect(
        await JellyfinVideoClient.searchRoundTotal(
          page: page(1, 0),
          startIndex: 0,
          requested: 1,
          measure: () async => 37,
        ),
        37,
      );
    });

    test('只判 hasMore（exact: false）、这页满了：取下界，不逐页数', () async {
      expect(
        await JellyfinVideoClient.searchRoundTotal(
          page: page(1, 0),
          startIndex: 0,
          requested: 1,
          exact: false,
          measure: never,
        ),
        1,
      );
    });

    test('拼接分页问前一轮总数（偏移越过末尾的空页）：非零总数照用', () async {
      expect(
        await JellyfinVideoClient.searchRoundTotal(
          page: page(0, 2),
          startIndex: 4,
          requested: 100,
          measure: never,
        ),
        2,
      );
    });

    test('偏移越过末尾的空页、总数报 0：逐页数', () async {
      expect(
        await JellyfinVideoClient.searchRoundTotal(
          page: page(0, 0),
          startIndex: 130,
          requested: 100,
          measure: () async => 130,
        ),
        130,
      );
    });
  });
}
