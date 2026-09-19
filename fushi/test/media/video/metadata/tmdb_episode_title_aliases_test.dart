import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Shoko 集级匹配比的是 en-US + 剧原语集名；本仓 TMDB 常规 hydrate 只拉资料语言，
/// `fetchEpisodeTitleAliases` 按季补另外两种（与资料语言同主子标签的跳过）。
void main() {
  http.Response json(Object body) => http.Response(jsonEncode(body), 200,
      headers: <String, String>{'content-type': 'application/json'});

  MockClient client(List<String> languages) =>
      MockClient((http.Request request) async {
        final String path = request.url.path;
        final String language = request.url.queryParameters['language']!;
        if (path.endsWith('/tv/100')) {
          return json(<String, Object?>{
            'id': 100,
            'name': '作品',
            'original_language': 'ja',
            'seasons': <Object?>[
              <String, Object?>{
                'id': 500,
                'season_number': 2,
                'name': 'S2',
                'episode_count': 2,
              },
            ],
          });
        }
        if (path.endsWith('/tv/100/season/2')) {
          languages.add(language);
          return json(<String, Object?>{
            'season_number': 2,
            'episodes': <Object?>[
              <String, Object?>{
                'episode_number': 41,
                'name': language == 'en-US' ? 'The Calamity' : '禍進譚',
              },
              <String, Object?>{'episode_number': 42, 'name': ''},
            ],
          });
        }
        return json(<String, Object?>{'results': <Object?>[]});
      });

  const VideoMetadataLookup lookup = VideoMetadataLookup(
    provider: VideoMetadataProviderKind.tmdb,
    externalId: '100',
    mediaKind: VideoMetadataMediaKind.tv,
  );

  test('zh-CN metadata language pulls en-US and the original language (ja)',
      () async {
    final List<String> languages = <String>[];
    final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
        apiKey: 'KEY', client: client(languages), language: 'zh-CN');
    final Map<int, List<String>> aliases =
        await provider.fetchEpisodeTitleAliases(lookup, seasonNumber: 2);
    expect(languages, <String>['en-US', 'ja']);
    expect(aliases[41], <String>['The Calamity', '禍進譚']);
    expect(aliases.containsKey(42), isFalse, reason: '空集名不算别名');
    // 再取一次走缓存，不再打请求。
    await provider.fetchEpisodeTitleAliases(lookup, seasonNumber: 2);
    expect(languages.length, 2);
    provider.close();
  });

  test('en-US metadata language skips en and only pulls the original language',
      () async {
    final List<String> languages = <String>[];
    final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
        apiKey: 'KEY', client: client(languages), language: 'en-US');
    final Map<int, List<String>> aliases =
        await provider.fetchEpisodeTitleAliases(lookup, seasonNumber: 2);
    expect(languages, <String>['ja']);
    expect(aliases[41], <String>['禍進譚']);
    provider.close();
  });

  test('episode groups and movies have no episode aliases', () async {
    final List<String> languages = <String>[];
    final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
        apiKey: 'KEY', client: client(languages), language: 'zh-CN');
    expect(
      await provider.fetchEpisodeTitleAliases(
          const VideoMetadataLookup(
              provider: VideoMetadataProviderKind.tmdb,
              externalId: '100',
              mediaKind: VideoMetadataMediaKind.tv,
              episodeGroupId: 'g1'),
          seasonNumber: 2),
      isEmpty,
    );
    expect(languages, isEmpty);
    provider.close();
  });
}
