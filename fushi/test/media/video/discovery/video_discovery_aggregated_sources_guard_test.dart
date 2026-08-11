import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/discovery/video_discovery_service.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';

/// BUG-1538 守卫：发现页在「下载代理 direct / proxy」两种模式下都用同一份
/// 聚合来源（AniList + TMDB + Bangumi），来源选择不随代理开关分叉降级。
///
/// 两层钉法：
/// 1. 行为层：[VideoDiscoveryService.production] 的签名里没有任何代理输入，
///    组成只由刮削配置决定——断言聚合来源集合恒定。
/// 2. 结构层：源码扫描 discovery 目录，禁止引入下载代理符号
///    （`DownloadNetworkProxy*` / `download_network_proxy.dart`），
///    杜绝将来有人把来源选择接到代理模式上。
void main() {
  test('production discovery service aggregates AniList + TMDB + Bangumi', () {
    final VideoDiscoveryService service = VideoDiscoveryService.production(
      const VideoSourceScrapeGlobalConfig(
        tmdbApiKey: 'test-key',
        bangumiToken: 'test-token',
      ),
    );
    addTearDown(service.close);
    expect(
      service.providerIdsForTesting.toSet(),
      <String>{'anilist', 'tmdb', 'bangumi'},
    );
  });

  test('discovery source selection has no dependency on download proxy mode',
      () {
    final Directory discoveryDir = Directory('lib/src/media/video/discovery');
    expect(discoveryDir.existsSync(), isTrue,
        reason: '守卫必须从 fushi/ 目录运行且 discovery 目录存在');
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity
        in discoveryDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String source = entity.readAsStringSync();
      if (source.contains('DownloadNetworkProxy') ||
          source.contains('download_network_proxy.dart')) {
        offenders.add(entity.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '发现页聚合来源不得随下载代理模式分叉（BUG-1538）：'
          '这些文件引用了下载代理符号 → $offenders',
    );
  });
}
