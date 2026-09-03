import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/src/media/manga/discovery/anilist_manga_discovery_provider.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';

/// AniList 漫画发现 provider：combined query 一次请求解析出四条 feed，
/// 字段映射（评分 /10、HTML 剥离、多标题）与 GraphQL 错误转异常都要真解析。
void main() {
  Map<String, Object?> media({
    required int id,
    String? native,
    String? romaji,
    String? english,
    int? score,
    String? description,
  }) =>
      <String, Object?>{
        'id': id,
        'title': <String, Object?>{
          'native': native,
          'romaji': romaji,
          'english': english,
        },
        'synonyms': <Object?>['别名A', null],
        'coverImage': <String, Object?>{
          'extraLarge': 'https://img.example/$id-xl.jpg',
          'large': 'https://img.example/$id.jpg',
        },
        'averageScore': score,
        'description': description,
        'genres': <Object?>['Fantasy', 'Adventure'],
        'status': 'RELEASING',
        'chapters': null,
        'countryOfOrigin': 'JP',
      };

  AniListMangaDiscoveryProvider providerWith(
    Future<http.Response> Function(http.Request request) handler,
  ) =>
      AniListMangaDiscoveryProvider(client: MockClient(handler));

  test('combined query 解析四条 feed，评分除以 10，HTML 剥离', () async {
    late Map<String, Object?> sentBody;
    final AniListMangaDiscoveryProvider provider =
        providerWith((http.Request request) async {
      sentBody = jsonDecode(request.body) as Map<String, Object?>;
      return http.Response(
        jsonEncode(<String, Object?>{
          'data': <String, Object?>{
            'trending': <String, Object?>{
              'media': <Object?>[
                media(
                  id: 10,
                  native: '葬送のフリーレン',
                  romaji: 'Sousou no Frieren',
                  score: 89,
                  description: '<i>魔王</i>を倒した後の物語。<br>勇者一行。',
                ),
                media(id: 10, native: '重复条目同 id 去重'),
              ],
            },
            'popular': <String, Object?>{
              'media': <Object?>[media(id: 20, english: 'One Piece')],
            },
            'topRated': <String, Object?>{'media': <Object?>[]},
            'latestFinished': <String, Object?>{
              'media': <Object?>[media(id: 30, romaji: 'Owari')],
            },
          },
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    final MangaDiscoverySnapshot snapshot = await provider.fetchSnapshot();
    provider.close();

    expect((sentBody['query']! as String), contains('type: MANGA'));
    expect(
      (sentBody['variables']! as Map<String, Object?>)['perPage'],
      20,
    );

    final List<MangaDiscoveryEntry> trending =
        snapshot[MangaDiscoveryFeed.trending];
    expect(trending, hasLength(1), reason: '同 id 条目 feed 内去重');
    final MangaDiscoveryEntry entry = trending.single;
    expect(entry.anilistId, 10);
    expect(entry.preferredTitle, '葬送のフリーレン');
    expect(entry.averageScore, closeTo(8.9, 0.001));
    expect(entry.description, isNot(contains('<')));
    expect(entry.coverUrl, 'https://img.example/10-xl.jpg');
    expect(entry.allTitles, contains('别名A'));
    expect(entry.status, 'RELEASING');

    expect(snapshot[MangaDiscoveryFeed.popular].single.preferredTitle,
        'One Piece');
    expect(snapshot[MangaDiscoveryFeed.topRated], isEmpty);
    expect(snapshot[MangaDiscoveryFeed.latestFinished].single.anilistId, 30);
    expect(snapshot.isEmpty, isFalse);
  });

  test('GraphQL errors 转成网络异常', () async {
    final AniListMangaDiscoveryProvider provider =
        providerWith((http.Request request) async {
      return http.Response(
        jsonEncode(<String, Object?>{
          'errors': <Object?>[
            <String, Object?>{'message': 'rate limited'},
          ],
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    await expectLater(
      provider.fetchSnapshot(),
      throwsA(
        isA<VideoMetadataNetworkException>().having(
          (VideoMetadataNetworkException e) => e.message,
          'message',
          contains('rate limited'),
        ),
      ),
    );
    provider.close();
  });
}
