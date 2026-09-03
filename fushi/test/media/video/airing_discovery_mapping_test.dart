// 放送日历重做（2026-08-21）：日历条目 → 发现条目的纯映射。identity 必须与
// 发现页 AniList 适配器同口径（providerId 'anilist' + mediaId = AniList id），
// 否则详情页的订阅/在库状态匹配与 loadDetails 补全全部失效——那正是旧日历
// 「根本下载不出来」的根源形态。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/airing_discovery_mapping.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataMediaKind;

AniListAiringEpisode _episode({
  int mediaId = 42,
  String? romaji = 'Sousou no Frieren',
  String? english,
  String? native = '葬送のフリーレン',
  String? cover = 'https://x/c.png',
  String? format = 'TV',
  int? seasonYear = 2026,
}) =>
    AniListAiringEpisode(
      mediaId: mediaId,
      episode: 7,
      airingAtSeconds: 1770000000,
      media: AniListMedia(
        id: mediaId,
        romaji: romaji,
        english: english,
        native: native,
        coverUrl: cover,
        seasonYear: seasonYear,
        format: format,
      ),
    );

void main() {
  group('mediaKindFromAniListFormat', () {
    test('只有 MOVIE 归电影，其余（含 null/未知）一律 tv', () {
      expect(mediaKindFromAniListFormat('MOVIE'), VideoMetadataMediaKind.movie);
      expect(mediaKindFromAniListFormat('movie'), VideoMetadataMediaKind.movie);
      for (final String? other in <String?>[
        'TV',
        'TV_SHORT',
        'OVA',
        'ONA',
        'SPECIAL',
        'MUSIC',
        'whatever',
        null,
      ]) {
        expect(mediaKindFromAniListFormat(other), VideoMetadataMediaKind.tv,
            reason: '$other 应按剧集处理');
      }
    });
  });

  group('discoveryItemFromAiringEpisode', () {
    test('identity 与发现页 AniList 适配器同口径', () {
      final VideoDiscoveryItem item =
          discoveryItemFromAiringEpisode(_episode());
      expect(item.reference.providerId, 'anilist');
      expect(item.reference.mediaId, '42');
      expect(item.reference.anilistId, 42);
      expect(item.reference.externalIds['anilist'], '42');
      expect(item.reference.discoveryCategory, VideoDiscoveryCategory.anime);
      expect(item.reference.mediaKind, VideoMetadataMediaKind.tv);
      expect(item.reference.title, 'Sousou no Frieren');
      expect(item.reference.year, 2026);
      expect(item.posterUrl, 'https://x/c.png');
    });

    test('剧场版 format=MOVIE → mediaKind movie', () {
      final VideoDiscoveryItem item =
          discoveryItemFromAiringEpisode(_episode(format: 'MOVIE'));
      expect(item.reference.mediaKind, VideoMetadataMediaKind.movie);
    });

    test('别名收齐三名且不重复主标题', () {
      final VideoDiscoveryItem item = discoveryItemFromAiringEpisode(
        _episode(english: 'Frieren: Beyond Journey\'s End'),
      );
      expect(
          item.reference.aliases, contains('Frieren: Beyond Journey\'s End'));
      expect(item.reference.aliases, contains('葬送のフリーレン'));
      expect(item.reference.aliases, isNot(contains(item.reference.title)),
          reason: '主标题重复进别名只会让资源搜索去重多干活');
    });

    test('缺 romaji 时标题回退英文/日文，identity 不受影响', () {
      final VideoDiscoveryItem item = discoveryItemFromAiringEpisode(
        _episode(romaji: null, english: null),
      );
      expect(item.reference.title, '葬送のフリーレン');
      expect(item.reference.mediaId, '42');
    });
  });
}
