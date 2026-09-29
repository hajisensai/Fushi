import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_json.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_merge.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_wire.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 详情页罗马音 / 英文名：TMDB 的挑选规则、模型 wire / 合并不丢字段、
/// 发现详情把它们前置进别名后资源搜索默认词优先罗马音。
void main() {
  group('TMDB romaji / english titles', () {
    test('movie: JP romaji-typed alternative + en-US translation', () async {
      final TmdbVideoMetadataProvider provider = _provider(<String, Object?>{
        'id': 1598785,
        'title': '银河特急 Milky☆Subway 各站停车前往剧场',
        'original_title': '銀河特急 ミルキー☆サブウェイ 各駅停車劇場行き',
        'original_language': 'ja',
        'release_date': '2026-04-17',
        'alternative_titles': <String, Object?>{
          'titles': <Object?>[
            <String, Object?>{
              'iso_3166_1': 'BR',
              'title': 'Expresso Galático Metrô Via-Láctea - O Filme',
              'type': '',
            },
            <String, Object?>{
              'iso_3166_1': 'JP',
              'title': 'Ginga Tokkyuu Milky☆Subway: Kakueki Teisha Gekijou Iki',
              'type': '',
            },
            <String, Object?>{
              'iso_3166_1': 'JP',
              'title': 'Ginga Tokkyū Milky☆Subway: Kakueki Teisha Gekijō Iki',
              'type': 'romaji',
            },
            <String, Object?>{
              'iso_3166_1': 'US',
              'title': 'Milky Subway: The Galactic Limited Express - The Movie',
              'type': '',
            },
          ],
        },
        'translations': <String, Object?>{
          'translations': <Object?>[
            <String, Object?>{
              'iso_639_1': 'fr',
              'iso_3166_1': 'FR',
              'data': <String, Object?>{'title': 'Milky Subway : le film'},
            },
            <String, Object?>{
              'iso_639_1': 'en',
              'iso_3166_1': 'GB',
              'data': <String, Object?>{'title': ''},
            },
            <String, Object?>{
              'iso_639_1': 'en',
              'iso_3166_1': 'US',
              'data': <String, Object?>{
                'title':
                    'Milky☆Subway: The Galactic Limited Express - the Movie',
              },
            },
          ],
        },
      });

      final VideoMetadataWork work = (await provider.fetchWork(
        const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.tmdb,
          externalId: '1598785',
          mediaKind: VideoMetadataMediaKind.movie,
        ),
      ))!;

      expect(
        work.romajiTitle,
        'Ginga Tokkyū Milky☆Subway: Kakueki Teisha Gekijō Iki',
      );
      expect(
        work.englishTitle,
        'Milky☆Subway: The Galactic Limited Express - the Movie',
      );
    });

    test('tv: untyped JP latin alias and US alias as fallbacks', () async {
      final TmdbVideoMetadataProvider provider = _provider(<String, Object?>{
        'id': 294766,
        'name': '银河特急 Milky☆Subway',
        'original_name': '銀河特急 ミルキー☆サブウェイ',
        'original_language': 'ja',
        'first_air_date': '2025-07-03',
        'alternative_titles': <String, Object?>{
          'results': <Object?>[
            <String, Object?>{
              'iso_3166_1': 'JP',
              'title': '銀河特急ミルキーサブウェイ',
              'type': '',
            },
            <String, Object?>{
              'iso_3166_1': 'JP',
              'title': 'Ginga Tokkyuu Milky Subway',
              'type': '',
            },
            <String, Object?>{
              'iso_3166_1': 'US',
              'title': 'Milky Subway: The Galactic Limited Express',
              'type': '',
            },
          ],
        },
      });

      final VideoMetadataWork work = (await provider.fetchWork(
        const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.tmdb,
          externalId: '294766',
          mediaKind: VideoMetadataMediaKind.tv,
        ),
      ))!;

      expect(work.romajiTitle, 'Ginga Tokkyuu Milky Subway');
      expect(work.englishTitle, 'Milky Subway: The Galactic Limited Express');
    });

    test('no latin data leaves both null', () async {
      final TmdbVideoMetadataProvider provider = _provider(<String, Object?>{
        'id': 1,
        'name': '某剧',
        'original_name': '某ドラマ',
        'original_language': 'ja',
      });
      final VideoMetadataWork work = (await provider.fetchWork(
        const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.tmdb,
          externalId: '1',
          mediaKind: VideoMetadataMediaKind.tv,
        ),
      ))!;
      expect(work.romajiTitle, isNull);
      expect(work.englishTitle, isNull);
    });
  });

  test('isLatinScriptTitle', () {
    expect(isLatinScriptTitle('Ginga Tokkyū Milky☆Subway'), isTrue);
    expect(isLatinScriptTitle('銀河特急 Milky☆Subway'), isFalse);
    expect(isLatinScriptTitle('은하특급 Milky'), isFalse);
    expect(isLatinScriptTitle('Млечный Subway'), isFalse);
    expect(isLatinScriptTitle('☆ 2026'), isFalse);
  });

  test('wire round trip and merge keep romaji / english', () {
    final VideoMetadataWork primary = VideoMetadataWork(
      provider: VideoMetadataProviderKind.tmdb,
      kind: VideoMetadataMediaKind.tv,
      title: '标题',
      englishTitle: 'English',
    );
    final VideoMetadataWork decoded =
        decodeVideoMetadataWork(encodeVideoMetadataWork(
      primary.copyWith(romajiTitle: 'Romaji'),
    ));
    expect(decoded.romajiTitle, 'Romaji');
    expect(decoded.englishTitle, 'English');

    final VideoMetadataWork merged = supplementVideoMetadata(
      primary,
      VideoMetadataWork(
        provider: VideoMetadataProviderKind.mal,
        kind: VideoMetadataMediaKind.tv,
        title: 'Title',
        romajiTitle: 'Supplement Romaji',
        englishTitle: 'Supplement English',
      ),
    );
    expect(merged.romajiTitle, 'Supplement Romaji');
    expect(merged.englishTitle, 'English');
  });

  test('leading aliases make resource search prefer romaji', () {
    final VideoMediaReference listReference = VideoMediaReference(
      providerId: 'tmdb',
      mediaId: '1598785',
      mediaKind: VideoMetadataMediaKind.movie,
      discoveryCategory: VideoDiscoveryCategory.anime,
      title: '银河特急 Milky☆Subway 各站停车前往剧场',
      originalTitle: '銀河特急 ミルキー☆サブウェイ 各駅停車劇場行き',
      aliases: const <String>['銀河特急 ミルキー☆サブウェイ 各駅停車劇場行き'],
    );
    // 列表条目只带原名：默认词只能是日文（用户截图里的状态）。
    expect(
      preferredNyaaSearchQueries(
        VideoResourceSearchRequest(media: listReference),
      ),
      <String>['銀河特急 ミルキー☆サブウェイ 各駅停車劇場行き'],
    );

    final VideoMediaReference detailed = listReference.withLeadingAliases(
      <String?>[
        'Ginga Tokkyū Milky☆Subway: Kakueki Teisha Gekijō Iki',
        null,
        'Milky☆Subway: The Galactic Limited Express - the Movie',
        '银河特急 Milky☆Subway 各站停车前往剧场',
      ],
    );
    expect(detailed.aliases, <String>[
      'Ginga Tokkyū Milky☆Subway: Kakueki Teisha Gekijō Iki',
      'Milky☆Subway: The Galactic Limited Express - the Movie',
      '銀河特急 ミルキー☆サブウェイ 各駅停車劇場行き',
    ]);
    expect(detailed.canonicalIdentityKey, listReference.canonicalIdentityKey);
    expect(
      preferredNyaaSearchQueries(VideoResourceSearchRequest(media: detailed)),
      <String>[
        'Ginga Tokkyū Milky☆Subway: Kakueki Teisha Gekijō Iki',
        '銀河特急 ミルキー☆サブウェイ 各駅停車劇場行き',
      ],
    );
  });

  test('videoDiscoveryLatinTitles skips duplicates of title / original', () {
    VideoDiscoveryItem item({String? romaji, String? english}) =>
        VideoDiscoveryItem(
          reference: VideoMediaReference(
            providerId: 'anilist',
            mediaId: '1',
            mediaKind: VideoMetadataMediaKind.tv,
            discoveryCategory: VideoDiscoveryCategory.anime,
            title: 'Frieren',
            originalTitle: '葬送のフリーレン',
          ),
          metadataWork: VideoMetadataWork(
            provider: VideoMetadataProviderKind.anilist,
            kind: VideoMetadataMediaKind.tv,
            title: 'Frieren',
            romajiTitle: romaji,
            englishTitle: english,
          ),
        );

    expect(
      videoDiscoveryLatinTitles(
        item(romaji: 'Sousou no Frieren', english: 'frieren'),
      ),
      <String>['Sousou no Frieren'],
    );
    expect(
      videoDiscoveryLatinTitles(
        item(romaji: ' Sousou no Frieren ', english: 'Frieren: Beyond'),
      ),
      <String>['Sousou no Frieren', 'Frieren: Beyond'],
    );
    expect(videoDiscoveryLatinTitles(item()), isEmpty);
  });
}

TmdbVideoMetadataProvider _provider(Map<String, Object?> detail) =>
    TmdbVideoMetadataProvider(
      apiKey: 'KEY',
      language: 'zh-CN',
      client: MockClient((http.Request request) async {
        final String path = request.url.path;
        if (path.endsWith('/images')) return _json(<String, Object?>{});
        if (path.endsWith('/${detail['id']}')) return _json(detail);
        return _json(<String, Object?>{});
      }),
    );

http.Response _json(Object? value) => http.Response.bytes(
      utf8.encode(jsonEncode(value)),
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    );
