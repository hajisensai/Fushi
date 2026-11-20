/// TMDB 电影刮削时随详情多打一次 `/collection/{id}`，把合集成员精简后挂进详情
/// 载荷（随 details 快照落盘，落库时换成系列关系）：只对电影、只在本来就在刮削
/// （fetchWork）时发、走同一个客户端与语言；合集请求失败不影响作品刮削本身。
library;

import 'dart:convert';

import 'package:fushi_engine/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_related_works.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response _json(Object payload) => http.Response(
  jsonEncode(payload),
  200,
  headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
);

void main() {
  const VideoMetadataLookup movie = VideoMetadataLookup(
    provider: VideoMetadataProviderKind.tmdb,
    externalId: '12',
    mediaKind: VideoMetadataMediaKind.movie,
  );
  const VideoMetadataLookup tv = VideoMetadataLookup(
    provider: VideoMetadataProviderKind.tmdb,
    externalId: '12',
    mediaKind: VideoMetadataMediaKind.tv,
  );

  Map<String, Object?> movieDetails({Object? collection}) => <String, Object?>{
    'id': 12,
    'title': 'Part 2',
    'release_date': '2003-01-01',
    'belongs_to_collection': collection,
  };

  test('电影属于合集：多打一次 /collection/{id}（同一语言），成员挂进 rawPayload', () async {
    final List<Uri> requests = <Uri>[];
    final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
      apiKey: 'KEY',
      language: 'ja-JP',
      client: MockClient((http.Request request) async {
        requests.add(request.url);
        if (request.url.path.endsWith('/movie/12')) {
          return _json(
            movieDetails(collection: <String, Object?>{'id': 5, 'name': 'S'}),
          );
        }
        if (request.url.path.endsWith('/collection/5')) {
          return _json(<String, Object?>{
            'id': 5,
            'name': 'Saga',
            'parts': <Object?>[
              <String, Object?>{
                'id': 11,
                'title': 'Part 1',
                'release_date': '2001-01-01',
                'media_type': 'movie',
              },
              <String, Object?>{
                'id': 12,
                'title': 'Part 2',
                'release_date': '2003-01-01',
              },
            ],
          });
        }
        return http.Response('{}', 200);
      }),
    );
    final VideoMetadataWork work = (await provider.fetchWork(movie))!;
    final Uri collectionCall = requests.singleWhere(
      (Uri u) => u.path.endsWith('/collection/5'),
    );
    expect(collectionCall.queryParameters['language'], 'ja-JP');
    expect(work.rawPayload![kTmdbCollectionPartsPayloadKey], <Object?>[
      <String, Object?>{
        'id': 11,
        'title': 'Part 1',
        'release_date': '2001-01-01',
      },
      <String, Object?>{
        'id': 12,
        'title': 'Part 2',
        'release_date': '2003-01-01',
      },
    ]);
    expect(
      relatedWorksFromRawPayload(
        'tmdb',
        work.rawPayload,
      )!.map((VideoRelatedWork r) => '${r.externalId}:${r.relationType}'),
      <String>['11:prequel'],
    );
  });

  test('合集请求失败：作品照常返回，载荷不带成员（关系未知，不清旧行）', () async {
    final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
      apiKey: 'KEY',
      client: MockClient((http.Request request) async {
        if (request.url.path.endsWith('/movie/12')) {
          return _json(
            movieDetails(collection: <String, Object?>{'id': 5, 'name': 'S'}),
          );
        }
        // 不是 JSON 对象 → 客户端抛 VideoMetadataNetworkException。
        if (request.url.path.endsWith('/collection/5')) {
          return _json(<Object?>[]);
        }
        return http.Response('{}', 200);
      }),
    );
    final VideoMetadataWork work = (await provider.fetchWork(movie))!;
    expect(work.title, 'Part 2');
    expect(
      work.rawPayload!.containsKey(kTmdbCollectionPartsPayloadKey),
      isFalse,
    );
    expect(relatedWorksFromRawPayload('tmdb', work.rawPayload), isNull);
  });

  test('不属于合集的电影、剧集：不发 /collection 请求', () async {
    final List<Uri> requests = <Uri>[];
    final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
      apiKey: 'KEY',
      client: MockClient((http.Request request) async {
        requests.add(request.url);
        if (request.url.path.endsWith('/movie/12')) {
          return _json(movieDetails());
        }
        if (request.url.path.endsWith('/tv/12')) {
          return _json(<String, Object?>{
            'id': 12,
            'name': 'Show',
            'first_air_date': '2020-01-01',
          });
        }
        return http.Response('{}', 200);
      }),
    );
    final VideoMetadataWork film = (await provider.fetchWork(movie))!;
    expect(relatedWorksFromRawPayload('tmdb', film.rawPayload), isEmpty);
    await provider.fetchWork(tv);
    expect(requests.where((Uri u) => u.path.contains('/collection/')), isEmpty);
  });
}
