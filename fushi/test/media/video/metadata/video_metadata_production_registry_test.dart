import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';

void main() {
  test('production work catalog contains MAL and TMDB', () {
    final VideoMetadataProviderRegistry registry =
        VideoMetadataProviderRegistry.production(
          const VideoSourceScrapeGlobalConfig(),
        );
    addTearDown(registry.close);
    expect(
      registry.providers.map((VideoMetadataProvider p) => p.providerKind),
      <VideoMetadataProviderKind>[
        VideoMetadataProviderKind.mal,
        VideoMetadataProviderKind.tmdb,
      ],
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
      }
    },
  );
}
