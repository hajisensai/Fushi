import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HomePage injects the real discovery service and action ports', () {
    final String source = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();

    expect(source, contains('VideoDiscoveryService.production(config)'));
    expect(
      source,
      contains('discoveryController: _productionVideoDiscoveryController'),
    );
    expect(
      source,
      contains('discoveryActions: _productionVideoDiscoveryActions'),
    );
    expect(source, contains('loadDetails: _loadVideoDiscoveryDetails'));
    expect(
      source,
      contains('onSearchResource: _openVideoDiscoveryResourceSearch'),
    );
    expect(
      source,
      contains('onSearchSubtitle: _openVideoDiscoverySubtitleSearch'),
    );
    expect(source, contains('watchStatus: _watchVideoDiscoveryStatus'));
    expect(source, contains('onPlay: _openLocalVideoDiscoveryWork'));
    expect(source, contains('VideoDiscoveryResourceSearchPage('));
    expect(source, contains('VideoDiscoverySubscriptionPage('));
    expect(source, contains('VideoDiscoverySubtitleSearchPage('));
    expect(
      RegExp(r'on VideoDownloadBackendUnavailable catch \(error\)')
          .allMatches(source),
      hasLength(2),
      reason: '资源搜索和订阅入口都应向用户展示内置引擎缺失的可操作原因',
    );
    expect(source, contains('Navigator.of(context).push<void>('));
    expect(source, contains('Navigator.of(context).push<String>('));
    expect(source, contains('pipeline.attachSubtitleSelection('));
    expect(source, contains('VideoDownloadSubscriptionsCompanion.insert('));
    expect(source, contains('_videoDiscoveryService?.close()'));
  });

  test('downloads first tab is resources rather than a second discovery page',
      () {
    final String source = File(
      'lib/src/pages/implementations/downloads_page.dart',
    ).readAsStringSync();

    // 首段的**承载形态**换过三次：`Tab(text: …)` → PR#820 与库页同构的
    // `ButtonSegment(value: 0, label: Text(…))` → 2026-08-24 库页改走 MD3 tabs 后的
    // `LibrarySectionTab(value: 0, label: …)`。本条守的**行为**三次都没变：第一段
    // 必须是「资源」，不是第二个 discovery 页。
    expect(source, contains('value: 0, label: t.download_resources_tab'));
    expect(source, contains('VideoResourceSearchSurface('));
    expect(source, contains('VideoDownloadJobsPanel.database('));
    expect(source, contains('VideoDownloadSubscriptionsPanel()'));
    expect(source, isNot(contains('download_discover_tab')));
  });
}
