import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/src/media/manga/discovery/mal_manga_discovery_provider.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_models.dart';
import 'package:fushi/src/media/video/metadata/mal_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';

void main() {
  Map<String, Object?> manga({int id = 10, String status = 'Publishing'}) =>
      <String, Object?>{
        'mal_id': id,
        'title_japanese': '葬送のフリーレン',
        'title': 'Sousou no Frieren',
        'title_english': 'Frieren: Beyond Journey\'s End',
        'title_synonyms': <Object?>['别名A', null, ''],
        'titles': <Object?>[
          <String, Object?>{'type': 'Default', 'title': 'Sousou no Frieren'},
          <String, Object?>{'type': 'Synonym', 'title': '别名B'},
          <String, Object?>{'type': 'Synonym', 'title': '别名A'},
        ],
        'images': <String, Object?>{
          'jpg': <String, Object?>{
            'large_image_url': 'https://img.example/$id-large.jpg',
            'image_url': 'https://img.example/$id.jpg',
          },
        },
        'score': 8.9,
        'synopsis': '<i>魔王</i>を倒した後の物語。<br>勇者一行。',
        'genres': <Object?>[
          <String, Object?>{'name': 'Fantasy'},
          <String, Object?>{'name': 'Adventure'},
        ],
        'status': status,
        'chapters': 123,
      };

  http.Response response(List<Object?> entries) => http.Response(
        jsonEncode(<String, Object?>{'data': entries}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );

  MalMangaDiscoveryProvider providerWith(
    Future<http.Response> Function(http.Request request) handler,
  ) =>
      MalMangaDiscoveryProvider(
        client: MockClient(handler),
        requestGate: MalVideoMetadataRequestGate(interval: Duration.zero),
      );

  test('四条 MAL 内容行使用安全筛选和各自排序，映射身份与标题', () async {
    final List<http.Request> requests = <http.Request>[];
    final MalMangaDiscoveryProvider provider = providerWith((
      http.Request request,
    ) async {
      requests.add(request);
      return response(<Object?>[manga(), manga(), manga(id: 0), null]);
    });
    addTearDown(provider.close);
    final MangaDiscoverySnapshot snapshot = await provider.fetchSnapshot();
    expect(requests, hasLength(4));
    for (final http.Request request in requests) {
      expect(request.method, 'GET');
      expect(request.url.host, 'api.jikan.moe');
      expect(request.url.path, '/v4/manga');
      expect(request.url.queryParameters, containsPair('sfw', 'true'));
      expect(request.url.queryParameters, containsPair('type', 'manga'));
      expect(request.url.queryParameters, containsPair('sort', 'desc'));
      expect(request.url.queryParameters, containsPair('limit', '20'));
    }
    expect(
      requests[0].url.queryParameters,
      containsPair('status', 'publishing'),
    );
    expect(
      requests[0].url.queryParameters,
      containsPair('order_by', 'members'),
    );
    expect(
      requests[1].url.queryParameters,
      containsPair('order_by', 'members'),
    );
    expect(requests[1].url.queryParameters, isNot(contains('status')));
    expect(requests[2].url.queryParameters, containsPair('order_by', 'score'));
    expect(
      requests[3].url.queryParameters,
      containsPair('order_by', 'end_date'),
    );
    expect(requests[3].url.queryParameters, containsPair('status', 'complete'));
    expect(requests[3].url.queryParameters, containsPair('min_score', '7'));

    for (final MangaDiscoveryFeed feed in MangaDiscoveryFeed.values) {
      expect(snapshot[feed], hasLength(1));
    }
    final MangaDiscoveryEntry entry =
        snapshot[MangaDiscoveryFeed.publishing].single;
    expect(entry.malId, 10);
    expect(entry.preferredTitle, '葬送のフリーレン');
    expect(entry.averageScore, 8.9);
    expect(entry.description, isNot(contains('<')));
    expect(entry.coverUrl, 'https://img.example/10-large.jpg');
    expect(entry.allTitles, containsAll(<String>['别名A', '别名B']));
    expect(
      entry.synonyms.where((String title) => title == '别名A'),
      hasLength(1),
    );
    expect(entry.status, 'RELEASING');
    expect(entry.chapters, 123);
    expect(entry.genres, <String>['Fantasy', 'Adventure']);
    expect(entry.countryOfOrigin, isNull);
  });

  test('Jikan 状态转换与未知状态，空评分不会变成零分', () async {
    final MalMangaDiscoveryProvider provider = providerWith(
      (http.Request request) async => response(<Object?>[
        manga(id: 1, status: 'Finished'),
        manga(id: 2, status: 'On Hiatus'),
        manga(id: 3, status: 'Discontinued'),
        manga(id: 4, status: 'Not yet published'),
        <String, Object?>{'mal_id': 5, 'status': 'Unknown', 'score': 0},
        <String, Object?>{'mal_id': 6, 'score': null},
      ]),
    );
    addTearDown(provider.close);
    final List<MangaDiscoveryEntry> entries =
        (await provider.fetchSnapshot())[MangaDiscoveryFeed.popular];
    expect(entries.map((MangaDiscoveryEntry entry) => entry.status), <String?>[
      'FINISHED',
      'HIATUS',
      'CANCELLED',
      'NOT_YET_RELEASED',
      null,
      null,
    ]);
    expect(entries[4].averageScore, isNull);
    expect(entries[5].averageScore, isNull);
    expect(entries[5].preferredTitle, '#6');
  });

  for (final (int requested, String expected) in <(int, String)>[
    (0, '1'),
    (50, '25'),
  ]) {
    test('页大小 $requested 遵守 Jikan 上下限', () async {
      final MalMangaDiscoveryProvider provider = providerWith((
        http.Request request,
      ) async {
        expect(request.url.queryParameters['limit'], expected);
        return response(<Object?>[]);
      });
      addTearDown(provider.close);
      expect(
        (await provider.fetchSnapshot(perPage: requested)).isEmpty,
        isTrue,
      );
    });
  }

  test('并发刷新共享 gate，缓存复用且请求依次执行', () async {
    final List<Duration> waits = <Duration>[];
    DateTime now = DateTime(2026);
    int requests = 0;
    final MalMangaDiscoveryProvider provider = MalMangaDiscoveryProvider(
      client: MockClient((http.Request request) async {
        requests++;
        return response(<Object?>[manga()]);
      }),
      requestGate: MalVideoMetadataRequestGate(
        now: () => now,
        sleep: (Duration duration) async {
          waits.add(duration);
          now = now.add(duration);
        },
      ),
    );
    addTearDown(provider.close);
    await Future.wait(<Future<MangaDiscoverySnapshot>>[
      provider.fetchSnapshot(),
      provider.fetchSnapshot(),
    ]);
    await provider.fetchSnapshot();
    expect(requests, 4);
    expect(waits, List<Duration>.filled(3, const Duration(seconds: 1)));
  });

  for (final int status in <int>[403, 429, 503]) {
    test('HTTP $status 明确失败且不绕过 gate 自动重试', () async {
      int requests = 0;
      final MalMangaDiscoveryProvider provider = providerWith((
        http.Request request,
      ) async {
        requests++;
        return http.Response('{"message":"upstream unavailable"}', status);
      });
      addTearDown(provider.close);
      await expectLater(
        provider.fetchSnapshot(),
        throwsA(
          isA<VideoMetadataNetworkException>().having(
            (VideoMetadataNetworkException error) => error.statusCode,
            'statusCode',
            status,
          ),
        ),
      );
      expect(requests, 1);
    });
  }

  test('错误 JSON 不能伪装成空发现页', () async {
    final MalMangaDiscoveryProvider provider = providerWith(
      (http.Request request) async =>
          http.Response('{"message":"temporarily unavailable"}', 200),
    );
    addTearDown(provider.close);
    await expectLater(
      provider.fetchSnapshot(),
      throwsA(
        isA<VideoMetadataNetworkException>().having(
          (VideoMetadataNetworkException error) => error.message,
          'message',
          contains('temporarily unavailable'),
        ),
      ),
    );
  });
}
