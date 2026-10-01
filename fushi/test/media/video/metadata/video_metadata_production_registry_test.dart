import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/anidb_app_client.dart';
import 'package:fushi_engine/media/video/metadata/anidb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';

void main() {
  test('production work catalog contains AniDB, MAL and TMDB', () {
    // 2026-09-20 用户拍板对齐 Shoko：AniDB HTTP 资料链装配进生产 registry 且为
    // 默认主源，TMDB 补充；MAL 保留可选。顺序即 kSelectableVideoMetadataProviders。
    final VideoMetadataProviderRegistry registry =
        VideoMetadataProviderRegistry.production(
          const VideoSourceScrapeGlobalConfig(),
        );
    addTearDown(registry.close);
    expect(
      registry.providers.map((VideoMetadataProvider p) => p.providerKind),
      kSelectableVideoMetadataProviders,
    );
    expect(
      registry.providers.map((VideoMetadataProvider p) => p.providerKind),
      <VideoMetadataProviderKind>[
        VideoMetadataProviderKind.anidb,
        VideoMetadataProviderKind.mal,
        VideoMetadataProviderKind.tmdb,
      ],
    );
    // AniDB provider 恒可用（离线标题目录兜底搜索），但 HTTP anime XML 链**默认
    // 不可用**：此前这里断言「随包 `fushiplayer` 已登记、HTTP 链默认可用」，那条
    // 前提就是 BUG-2623——fushiplayer 只登记了 UDP，拿去请求 httpapi 恒回 302。
    // 随包 HTTP 身份为空，provider 发请求前就判不可用。
    final AniDbVideoMetadataProvider anidb =
        registry.provider(VideoMetadataProviderKind.anidb)!
            as AniDbVideoMetadataProvider;
    expect(anidb.isAvailable, isTrue);
    expect(anidb.isHttpApiAvailable, isFalse);
    expect(
      registry.provider(VideoMetadataProviderKind.mal)!.isAvailable,
      isTrue,
    );
    expect(
      registry.provider(VideoMetadataProviderKind.tmdb)!.isAvailable,
      isFalse,
    );
  });

  test('production AniDB HTTP chain uses the HTTP identity, not the UDP one', () {
    // UDP 身份齐全（随包 fushiplayer/1）而 HTTP 身份为空：HTTP 链必须不可用。
    final VideoMetadataProviderRegistry bundled =
        VideoMetadataProviderRegistry.production(
          VideoSourceScrapeGlobalConfig(
            anidbClientName: kBundledAniDbClient.name,
            anidbClientVersion: kBundledAniDbClient.version,
          ),
        );
    addTearDown(bundled.close);
    expect(
      (bundled.provider(VideoMetadataProviderKind.anidb)!
              as AniDbVideoMetadataProvider)
          .isHttpApiAvailable,
      isFalse,
    );
    // 配了 HTTP 身份（用户自定义客户端）才可用。
    final VideoMetadataProviderRegistry custom =
        VideoMetadataProviderRegistry.production(
          const VideoSourceScrapeGlobalConfig(
            anidbClientName: 'customapp',
            anidbClientVersion: 2,
            anidbHttpClientName: 'customapp',
            anidbHttpClientVersion: 2,
          ),
        );
    addTearDown(custom.close);
    expect(
      (custom.provider(VideoMetadataProviderKind.anidb)!
              as AniDbVideoMetadataProvider)
          .isHttpApiAvailable,
      isTrue,
    );
  });

  test(
    'production TMDB receives API configuration and selected metadata locale',
    () {
      for (final String? locale in <String?>[null, 'ja']) {
        final VideoMetadataProviderRegistry registry =
            VideoMetadataProviderRegistry.production(
              const VideoSourceScrapeGlobalConfig(
                tmdbApiKey: 'test-key',
                locale: 'zh-CN',
              ),
              locale: locale,
            );
        addTearDown(registry.close);
        final TmdbVideoMetadataProvider tmdb =
            registry.provider(VideoMetadataProviderKind.tmdb)!
                as TmdbVideoMetadataProvider;
        expect(tmdb.isAvailable, isTrue);
        expect(tmdb.language, locale ?? 'zh-CN');
        // MAL 与 TMDB 必须拿同一个资料语言，否则标题与简介/海报不同语言。
        final MalVideoMetadataProvider mal =
            registry.provider(VideoMetadataProviderKind.mal)!
                as MalVideoMetadataProvider;
        expect(mal.language, tmdb.language);
      }
    },
  );
}
