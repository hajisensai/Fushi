import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HomePage injects the real discovery service and action ports', () {
    final String source = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();

    expect(source, contains('VideoDiscoveryService.production('));
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

    final int resourceSearchStart =
        source.indexOf('Future<void> _openVideoDiscoveryResourceSearch(');
    final int subscriptionStart =
        source.indexOf('Future<void> _openVideoDiscoverySubscription(');
    final int subtitleSearchStart =
        source.indexOf('Future<void> _openVideoDiscoverySubtitleSearch(');
    expect(resourceSearchStart, isNonNegative);
    expect(subscriptionStart, greaterThan(resourceSearchStart));
    expect(subtitleSearchStart, greaterThan(subscriptionStart));

    final String resourceSearch =
        source.substring(resourceSearchStart, subscriptionStart);
    final String subscription =
        source.substring(subscriptionStart, subtitleSearchStart);
    for (final String entryPoint in <String>[resourceSearch, subscription]) {
      final int pageConstruction = entryPoint.indexOf('Page(');
      final int submitCallback = entryPoint.indexOf('onSubmit:');
      final int backendResolution =
          entryPoint.indexOf('currentVideoDownloadBackendTarget()');
      expect(pageConstruction, isNonNegative);
      expect(submitCallback, greaterThan(pageConstruction));
      expect(
        backendResolution,
        greaterThan(submitCallback),
        reason: '浏览资源不依赖下载运行时；后端只应在用户提交时解析',
      );
    }

    final String dialogSource = File(
      'lib/src/pages/implementations/video_discovery_acquisition_dialogs.dart',
    ).readAsStringSync();
    expect(
      RegExp(r'on VideoDownloadBackendUnavailable catch \(error\)')
          .allMatches(dialogSource),
      hasLength(1),
      reason: '提交下载时应在当前资源页展示内置引擎缺失的可操作原因',
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
