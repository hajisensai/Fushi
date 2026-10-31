// 放送日历重做（2026-08-21）：日历条目 → 发现条目的纯映射。identity 必须与
// 发现页 AniList 适配器同口径（providerId 'anilist' + mediaId = AniList id），
// 否则详情页的订阅/在库状态匹配与 loadDetails 补全全部失效——那正是旧日历
// 「根本下载不出来」的根源形态。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/airing_discovery_mapping.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi_core/fushi_core.dart' show VideoDownloadSubscriptionRow;
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataMediaKind;

AniListAiringEpisode _episode({
  int mediaId = 42,
  String? romaji = 'Sousou no Frieren',
  String? english,
  String? native = '葬送のフリーレン',
  String? cover = 'https://x/c.png',
  String? format = 'TV',
  int? seasonYear = 2026,
}) => AniListAiringEpisode(
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

VideoDownloadSubscriptionRow _subscription({
  String? metadataProvider,
  String? externalId,
  String? identityJson,
}) => VideoDownloadSubscriptionRow(
  subscriptionId: 'sub',
  resourceProvider: 'nyaa:nyaa.si',
  metadataProvider: metadataProvider,
  externalId: externalId,
  mediaKind: 'tv',
  title: 't',
  identityJson: identityJson,
  searchQuery: 'q',
  filterJson: '{}',
  mode: 'ongoing',
  backendKind: 'embedded',
  fingerprint: 'f',
  organizationPolicy: 'library',
  subtitlePolicy: 'bestEffort',
  enabled: true,
  retryCount: 0,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  group('AniListMedia.nativeFirstTitle', () {
    test('日文原名 → 罗马字 → 英文 → id；displayTitle 仍罗马字优先（搜索用）', () {
      const AniListMedia all = AniListMedia(
        id: 1,
        romaji: 'R',
        english: 'E',
        native: 'N',
      );
      expect(all.nativeFirstTitle, 'N');
      expect(all.displayTitle, 'R');
      expect(
        const AniListMedia(id: 1, romaji: 'R', english: 'E').nativeFirstTitle,
        'R',
      );
      expect(const AniListMedia(id: 1, english: 'E').nativeFirstTitle, 'E');
      expect(
        const AniListMedia(id: 1, native: '').nativeFirstTitle,
        'AniList #1',
      );
    });
  });

  group('anilistIdOfVideoDownloadSubscription', () {
    test('identity_json 里的 anilistId 优先（任何元数据源都可能带）', () {
      expect(
        anilistIdOfVideoDownloadSubscription(
          _subscription(
            metadataProvider: 'tmdb',
            externalId: '999',
            identityJson:
                '{"providerId":"tmdb","mediaId":"999",'
                '"mediaKind":"tv","discoveryCategory":"anime",'
                '"title":"x","anilistId":188035}',
          ),
        ),
        188035,
      );
    });

    test('无 identity 时只有 anilist 元数据源的 external_id 才算', () {
      expect(
        anilistIdOfVideoDownloadSubscription(
          _subscription(metadataProvider: 'anilist', externalId: ' 42 '),
        ),
        42,
      );
      expect(
        anilistIdOfVideoDownloadSubscription(
          _subscription(metadataProvider: 'bangumi', externalId: '547888'),
        ),
        isNull,
        reason: 'Bangumi id 不是 AniList id，拿去 mediaId_in 只会查到别的番',
      );
      expect(anilistIdOfVideoDownloadSubscription(_subscription()), isNull);
    });
  });

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
        expect(
          mediaKindFromAniListFormat(other),
          VideoMetadataMediaKind.tv,
          reason: '$other 应按剧集处理',
        );
      }
    });
  });

  group('discoveryItemFromAiringEpisode', () {
    test('identity 与发现页 AniList 适配器同口径', () {
      final VideoDiscoveryItem item = discoveryItemFromAiringEpisode(
        _episode(),
      );
      expect(item.reference.providerId, 'anilist');
      expect(item.reference.mediaId, '42');
      expect(item.reference.anilistId, 42);
      expect(item.reference.externalIds['anilist'], '42');
      expect(item.reference.discoveryCategory, VideoDiscoveryCategory.anime);
      expect(item.reference.mediaKind, VideoMetadataMediaKind.tv);
      // 日文原名作标题（与发现页 AniList 适配器 native ?? romaji ?? english
      // 同口径），罗马字留在 aliases 给资源 / 字幕搜索命中。
      expect(item.reference.title, '葬送のフリーレン');
      expect(item.reference.aliases, contains('Sousou no Frieren'));
      expect(item.reference.year, 2026);
      expect(item.posterUrl, 'https://x/c.png');
    });

    test('剧场版 format=MOVIE → mediaKind movie', () {
      final VideoDiscoveryItem item = discoveryItemFromAiringEpisode(
        _episode(format: 'MOVIE'),
      );
      expect(item.reference.mediaKind, VideoMetadataMediaKind.movie);
    });

    test('别名收齐三名且不重复主标题', () {
      final VideoDiscoveryItem item = discoveryItemFromAiringEpisode(
        _episode(english: 'Frieren: Beyond Journey\'s End'),
      );
      expect(
        item.reference.aliases,
        contains('Frieren: Beyond Journey\'s End'),
      );
      expect(item.reference.aliases, contains('Sousou no Frieren'));
      expect(
        item.reference.aliases,
        isNot(contains(item.reference.title)),
        reason: '主标题重复进别名只会让资源搜索去重多干活',
      );
    });

    test('缺日文原名时标题回退罗马字，identity 不受影响', () {
      final VideoDiscoveryItem item = discoveryItemFromAiringEpisode(
        _episode(native: null),
      );
      expect(item.reference.title, 'Sousou no Frieren');
      expect(item.reference.mediaId, '42');
    });
  });
}
