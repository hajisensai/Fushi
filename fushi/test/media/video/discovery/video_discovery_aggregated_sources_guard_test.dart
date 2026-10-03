import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_service.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import '../../../helpers/source_guard.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';

/// BUG-1538 守卫：发现页无论走不走代理都用同一份聚合来源（MAL / AniList / TMDB 搜索与推荐），
/// 来源选择不随代理状态分叉降级。
///
/// 两层钉法：
/// 1. 行为层：[VideoDiscoveryService.production] 的签名里没有任何代理输入，
///    组成只由刮削配置决定——断言聚合来源集合恒定。
/// 2. 结构层：源码扫描 discovery 目录，禁止读取代理配置
///    （`update_custom_proxy` / `appUserProxyReader` / `resolveAppProxyDirective`），
///    杜绝将来有人把来源选择接到代理状态上。下载域曾有的独立代理三态
///    （`DownloadNetworkProxy*`）已并入全局代理项，同样列入禁引清单防复活。
void main() {
  test('production discovery service aggregates MAL search + AniList + TMDB', () {
    final VideoDiscoveryService service = VideoDiscoveryService.production(
      const VideoSourceScrapeGlobalConfig(tmdbApiKey: 'test-key'),
      discoveryAvailable: true,
    );
    addTearDown(service.close);
    final Set<String> providerIds = service.providerIdsForTesting.toSet();
    expect(
      providerIds,
      <String>{'mal', 'anilist', 'tmdb'},
    );
    expect(providerIds, isNot(contains('bangumi')));
    // AniDB 自 2026-09-20 起装进生产 registry（默认刮削主源），但它的 search 只是
    // 本地标题目录，不进发现页；发现与刮削是不同域。
    expect(providerIds, isNot(contains('anidb')));
    final VideoMetadataProviderRegistry catalog =
        VideoMetadataProviderRegistry.production(
      const VideoSourceScrapeGlobalConfig(tmdbApiKey: 'test-key'),
    );
    addTearDown(catalog.close);
    expect(
      catalog.providers.map((VideoMetadataProvider p) => p.providerKind),
      contains(VideoMetadataProviderKind.anidb),
      reason: '生产 registry 里确有 AniDB，发现页是主动排除而不是恰好没装',
    );
    // BUG-2750：AniList（发现域来源，不进刮削 registry）也是搜索源——只靠 MAL
    // 时 Jikan 一 504、TMDB 又没配 key，发现页搜索就一条都出不来。
    expect(
      service.searchProviderIdsForTesting,
      <String>{
        ...catalog.providers
            .where((VideoMetadataProvider p) =>
                VideoDiscoveryService.isDiscoverySearchKind(p.providerKind))
            .map((VideoMetadataProvider p) => p.providerKind.name),
        'anilist',
      },
    );
    expect(
      catalog.providers.map((VideoMetadataProvider p) => p.providerKind),
      isNot(contains(VideoMetadataProviderKind.anilist)),
      reason: 'AniList 只作发现搜索源，不得进入刮削 registry',
    );
    expect(service.searchProviderIdsForTesting, isNot(contains('anidb')));
  });

  test('discovery source selection has no dependency on proxy configuration',
      () {
    // 发现服务与适配器 2026-09-30 起下沉到引擎（无头服务端的「AI 下视频」共用），
    // 两个目录都要扫。
    final List<Directory> discoveryDirs = <Directory>[
      Directory('lib/src/media/video/discovery'),
      Directory('../packages/fushi_engine/lib/media/video/discovery'),
    ];
    for (final Directory dir in discoveryDirs) {
      expect(dir.existsSync(), isTrue,
          reason: '守卫必须从 fushi/ 目录运行且 ${dir.path} 存在');
    }
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity in <FileSystemEntity>[
      for (final Directory dir in discoveryDirs) ...dir.listSync(recursive: true),
    ]) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String source = maskComments(entity.readAsStringSync());
      const List<String> forbidden = <String>[
        'DownloadNetworkProxy',
        'download_network_proxy',
        'update_custom_proxy',
        'appUserProxyReader',
        'resolveAppProxyDirective',
      ];
      if (forbidden.any(source.contains)) {
        offenders.add(entity.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '发现页聚合来源不得随代理配置分叉（BUG-1538）：'
          '这些文件读取了代理配置 → $offenders',
    );
  });
}
