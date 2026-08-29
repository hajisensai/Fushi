import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/discovery/video_discovery_service.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';

import '../../../helpers/source_guard.dart';

/// BUG-1538 守卫：发现页无论走不走代理都用同一份聚合来源（AniList + TMDB），
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
  test('production discovery service aggregates only AniList + TMDB', () {
    final VideoDiscoveryService service = VideoDiscoveryService.production(
      const VideoSourceScrapeGlobalConfig(tmdbApiKey: 'test-key'),
    );
    addTearDown(service.close);
    final Set<String> providerIds = service.providerIdsForTesting.toSet();
    expect(
      providerIds,
      <String>{'anilist', 'tmdb'},
    );
    expect(providerIds, isNot(contains('bangumi')));
  });

  test('discovery source selection has no dependency on proxy configuration',
      () {
    final Directory discoveryDir = Directory('lib/src/media/video/discovery');
    expect(discoveryDir.existsSync(), isTrue,
        reason: '守卫必须从 fushi/ 目录运行且 discovery 目录存在');
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity
        in discoveryDir.listSync(recursive: true)) {
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
