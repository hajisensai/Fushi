import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_media_reference_codec.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';

void main() {
  test('全字段往返无损（identity_json 的唯一 wire 形状）', () {
    final VideoMediaReference original = VideoMediaReference(
      providerId: 'anilist',
      mediaId: '547888',
      mediaKind: VideoMetadataMediaKind.tv,
      discoveryCategory: VideoDiscoveryCategory.anime,
      title: 'Re：从零开始的异世界生活 第四季 丧失篇',
      originalTitle: 'Re：ゼロから始める異世界生活',
      aliases: const <String>[
        'Re:Zero kara Hajimeru Isekai Seikatsu 4th Season',
        'Re:ZERO -Starting Life in Another World-',
      ],
      year: 2026,
      season: 4,
      episode: 14,
      tmdbId: 65942,
      imdbId: 'tt5607616',
      tvdbId: 305089,
      anidbId: 11162,
      anilistId: 547888,
      bangumiId: 547888,
      externalIds: const <String, String>{'mal': '54857', 'anidb': '11162'},
    );

    final VideoMediaReference? decoded =
        decodeVideoMediaReference(encodeVideoMediaReference(original));

    expect(decoded, isNotNull);
    expect(decoded!.providerId, original.providerId);
    expect(decoded.mediaId, original.mediaId);
    expect(decoded.mediaKind, original.mediaKind);
    expect(decoded.discoveryCategory, original.discoveryCategory);
    expect(decoded.title, original.title);
    expect(decoded.originalTitle, original.originalTitle);
    expect(decoded.aliases, original.aliases);
    expect(decoded.year, original.year);
    expect(decoded.season, original.season);
    expect(decoded.episode, original.episode);
    expect(decoded.tmdbId, original.tmdbId);
    expect(decoded.imdbId, original.imdbId);
    expect(decoded.tvdbId, original.tvdbId);
    expect(decoded.anidbId, original.anidbId);
    expect(decoded.anilistId, original.anilistId);
    expect(decoded.bangumiId, original.bangumiId);
    expect(decoded.externalIds, original.externalIds);
  });

  test('最小字段往返：可选字段缺省不炸、解码回 null/空集合', () {
    final VideoMediaReference minimal = VideoMediaReference(
      providerId: 'tmdb',
      mediaId: '42',
      mediaKind: VideoMetadataMediaKind.movie,
      discoveryCategory: VideoDiscoveryCategory.movie,
      title: 'A Movie',
    );

    final VideoMediaReference? decoded =
        decodeVideoMediaReference(encodeVideoMediaReference(minimal));

    expect(decoded, isNotNull);
    expect(decoded!.originalTitle, isNull);
    expect(decoded.aliases, isEmpty);
    expect(decoded.anidbId, isNull);
    expect(decoded.externalIds, isEmpty);
  });

  test('损坏输入一律退化为 null，绝不抛', () {
    expect(decodeVideoMediaReference(null), isNull);
    expect(decodeVideoMediaReference(''), isNull);
    expect(decodeVideoMediaReference('not-json'), isNull);
    expect(decodeVideoMediaReference('[]'), isNull);
    expect(decodeVideoMediaReference('{"providerId":"x"}'), isNull,
        reason: '缺必填字段 = 无效快照');
    expect(
      decodeVideoMediaReference(
        '{"providerId":"x","mediaId":"1","title":"t",'
        '"mediaKind":"hologram","discoveryCategory":"anime"}',
      ),
      isNull,
      reason: '未知枚举值 = 无效快照，调用方回退旧路径',
    );
  });
}
