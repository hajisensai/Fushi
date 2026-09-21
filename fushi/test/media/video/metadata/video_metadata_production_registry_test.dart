import 'package:flutter_test/flutter_test.dart';
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
    // 随包 client `fushiplayer` 已登记，AniDB HTTP 链默认可用（不冒用 Shoko 标识）。
    expect(
      registry.provider(VideoMetadataProviderKind.anidb)!.isAvailable,
      isTrue,
    );
    expect(
      registry.provider(VideoMetadataProviderKind.mal)!.isAvailable,
      isTrue,
    );
    expect(
      registry.provider(VideoMetadataProviderKind.tmdb)!.isAvailable,
      isFalse,
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
