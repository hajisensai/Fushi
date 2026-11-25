import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_client.dart';
import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_models.dart';
import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_rate_gates.dart';
import 'package:fushi_engine/media/tracking/tracking_rate_gate.dart';
import 'package:fushi_engine/utils/net/app_user_agent.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

String _fixture(String name) =>
    File('test/fixtures/mangabaka/$name').readAsStringSync();

http.Response _json(String body, {int status = 200}) => http.Response.bytes(
  utf8.encode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

String _imagesPage(int page, {String? next, int count = 3}) =>
    jsonEncode(<String, Object?>{
      'status': 200,
      'pagination': <String, Object?>{'count': count, 'next': next},
      'data': <Object?>[
        <String, Object?>{
          'id': page,
          'index': '$page',
          'index_numeric': page,
          'type': 'volume',
          'language': 'ja',
          'image': <String, Object?>{
            'raw': <String, Object?>{
              'url': 'https://images.mangabaka.dev/$page',
              'width': 100,
              'height': 150,
            },
          },
        },
      ],
    });

/// 不真睡的闸：记录各自被预约了几次。
MangaBakaRateGates _countingGates(List<String> log) => MangaBakaRateGates(
  search: TrackingRateGate(
    maxRequests: 1000,
    now: () {
      log.add('search');
      return DateTime(2026);
    },
  ),
  other: TrackingRateGate(
    maxRequests: 1000,
    now: () {
      log.add('other');
      return DateTime(2026);
    },
  ),
);

void main() {
  test('搜索：host / UA / 参数 / 走搜索闸', () async {
    final List<http.Request> seen = <http.Request>[];
    final List<String> gates = <String>[];
    final MangaBakaClient client = MangaBakaClient(
      client: MockClient((http.Request r) async {
        seen.add(r);
        return _json(_fixture('mb_search_jujutsu.json'));
      }),
      userAgent: fushiUserAgent('book-scraper'),
      gates: _countingGates(gates),
    );
    final List<MangaBakaSeries> found = await client.searchSeries('呪術廻戦');
    expect(found.map((MangaBakaSeries s) => s.id), contains(6199));
    final http.Request r = seen.single;
    expect(r.url.host, 'api.mangabaka.org');
    expect(r.url.path, '/v1/series/search');
    expect(r.url.queryParameters['q'], '呪術廻戦');
    expect(r.url.queryParameters['limit'], '10');
    expect(r.headers['User-Agent'], 'fushi/book-scraper (https://fushi.moe)');
    expect(gates, <String>['search']);
  });

  test('图片：type / language / limit=50，沿 next 翻页到 null，走其他闸', () async {
    final List<Uri> seen = <Uri>[];
    final List<String> gates = <String>[];
    final MangaBakaClient client = MangaBakaClient(
      client: MockClient((http.Request r) async {
        seen.add(r.url);
        final String page = r.url.queryParameters['page'] ?? '1';
        return switch (page) {
          '1' => _json(
            _imagesPage(
              1,
              next:
                  'https://api.mangabaka.org/v1/series/377/images?language=ja&limit=50&type=volume&page=2',
            ),
          ),
          '2' => _json(
            _imagesPage(
              2,
              next:
                  'https://api.mangabaka.org/v1/series/377/images?language=ja&limit=50&type=volume&page=3',
            ),
          ),
          _ => _json(_imagesPage(3)),
        };
      }),
      userAgent: fushiUserAgent('book-scraper'),
      gates: _countingGates(gates),
    );
    final List<MangaBakaImage> images = await client.fetchSeriesImages(
      377,
      type: 'volume',
      language: 'ja',
    );
    expect(images.map((MangaBakaImage i) => i.index), <String>['1', '2', '3']);
    expect(seen.first.path, '/v1/series/377/images');
    expect(seen.first.queryParameters, <String, String>{
      'type': 'volume',
      'language': 'ja',
      'limit': '50',
    });
    expect(seen, hasLength(3));
    expect(gates, <String>['other', 'other', 'other']);
  });

  test('翻页有上限，且只跟随同一 API host 的 next', () async {
    int calls = 0;
    final MangaBakaClient endless = MangaBakaClient(
      client: MockClient((http.Request r) async {
        calls++;
        return _json(
          _imagesPage(
            calls,
            next:
                'https://api.mangabaka.org/v1/series/1/images?page=${calls + 1}',
          ),
        );
      }),
      userAgent: 'ua',
      gates: _countingGates(<String>[]),
    );
    await endless.fetchSeriesImages(1, type: 'volume');
    expect(calls, kMangaBakaMaxImagePages);

    int foreign = 0;
    final MangaBakaClient offHost = MangaBakaClient(
      client: MockClient((http.Request r) async {
        foreign++;
        return _json(
          _imagesPage(1, next: 'https://evil.example/v1/series/1/images'),
        );
      }),
      userAgent: 'ua',
      gates: _countingGates(<String>[]),
    );
    await offHost.fetchSeriesImages(1, type: 'banner');
    expect(foreign, 1);
  });

  test('429 带 Retry-After 等一次再发；再 429 停用本客户端', () async {
    final List<Duration> waits = <Duration>[];
    int calls = 0;
    final MangaBakaClient client = MangaBakaClient(
      client: MockClient((http.Request r) async {
        calls++;
        return http.Response(
          '',
          429,
          headers: <String, String>{'retry-after': '2'},
        );
      }),
      userAgent: 'ua',
      gates: _countingGates(<String>[]),
      wait: (Duration d) async => waits.add(d),
    );
    await expectLater(
      client.searchSeries('x'),
      throwsA(isA<MangaBakaRateLimitedException>()),
    );
    expect(waits, <Duration>[const Duration(seconds: 2)]);
    expect(calls, 2);
    expect(client.isRateLimited, isTrue);
    await expectLater(
      client.fetchSeries(1),
      throwsA(isA<MangaBakaRateLimitedException>()),
    );
    expect(calls, 2, reason: '停用后不再发请求');
  });

  test('429 首次成功重试后照常返回', () async {
    int calls = 0;
    final MangaBakaClient client = MangaBakaClient(
      client: MockClient((http.Request r) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            '',
            429,
            headers: <String, String>{'retry-after': '1'},
          );
        }
        return _json(_fixture('mb_series_8940.json'));
      }),
      userAgent: 'ua',
      gates: _countingGates(<String>[]),
      wait: (Duration d) async {},
    );
    expect((await client.fetchSeries(8940))!.id, 8940);
    expect(client.isRateLimited, isFalse);
  });

  test('Retry-After 超过上限不等，直接停用', () async {
    final List<Duration> waits = <Duration>[];
    final MangaBakaClient client = MangaBakaClient(
      client: MockClient(
        (http.Request r) async => http.Response(
          '',
          429,
          headers: <String, String>{'retry-after': '600'},
        ),
      ),
      userAgent: 'ua',
      gates: _countingGates(<String>[]),
      wait: (Duration d) async => waits.add(d),
    );
    await expectLater(
      client.searchSeries('x'),
      throwsA(isA<MangaBakaRateLimitedException>()),
    );
    expect(waits, isEmpty);
  });

  test('按 id 取：404 → null；5xx 抛 MangaBakaException', () async {
    final MangaBakaClient notFound = MangaBakaClient(
      client: MockClient((http.Request r) async => http.Response('', 404)),
      userAgent: 'ua',
      gates: _countingGates(<String>[]),
    );
    expect(await notFound.fetchSeries(1), isNull);
    final MangaBakaClient broken = MangaBakaClient(
      client: MockClient((http.Request r) async => http.Response('', 503)),
      userAgent: 'ua',
      gates: _countingGates(<String>[]),
    );
    await expectLater(
      broken.fetchSeries(1),
      throwsA(
        isA<MangaBakaException>().having(
          (MangaBakaException e) => e.statusCode,
          'statusCode',
          503,
        ),
      ),
    );
  });

  test('共享闸：搜索 30 / 其他 150，进程内同一实例', () {
    expect(
      identical(MangaBakaRateGates.shared, MangaBakaRateGates.shared),
      isTrue,
    );
    expect(MangaBakaRateGates.shared.search.maxRequests, 30);
    expect(MangaBakaRateGates.shared.other.maxRequests, 150);
  });
}
