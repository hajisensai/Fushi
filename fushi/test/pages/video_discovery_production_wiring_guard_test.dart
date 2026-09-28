import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HomePage injects the real discovery service and action ports', () {
    final String source = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();

    expect(source, contains('VideoDiscoveryService.production('));
    // 2026-09-27 起视频发现只住在「浏览」模块的「发现」页签：生产发现端口只注入
    // BrowsePage，视频库页（VideoLibraryShell）不再接发现端口。
    expect(
      source,
      contains('videoDiscoveryController: _productionVideoDiscoveryController'),
    );
    expect(
      source,
      contains('videoDiscoveryActions: _productionVideoDiscoveryActions'),
    );
    expect(
      source,
      isNot(contains(' discoveryController: _productionVideoDiscoveryController')),
      reason: '视频库页不再有发现分区，不得再把发现端口接给它',
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
    // 入队 / 订阅落库形状已抽到 video_discovery_submit.dart（发现页与 AI 下载
    // 流程共用）：组合根只负责接线到这两个函数，落库语句钉在抽出的模块上。
    expect(source, contains('enqueueLocalVideoDownload('));
    expect(source, contains('createLocalVideoDownloadSubscription('));
    final String submitSource = File(
      'lib/src/media/video/download/video_discovery_submit.dart',
    ).readAsStringSync();
    expect(
      submitSource,
      contains('VideoDownloadSubscriptionsCompanion.insert('),
    );
    expect(submitSource, contains('pipeline.enqueue('));
    expect(source, contains('_videoDiscoveryService?.close()'));
  });

  test('browse discover tab reuses the four production discovery surfaces', () {
    final String source = File(
      'lib/src/pages/implementations/browse_page.dart',
    ).readAsStringSync();
    final String home = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();

    // 首段的**承载形态**换过三次：`Tab(text: …)` → PR#820 与库页同构的
    // `ButtonSegment(value: 0, label: Text(…))` → 2026-08-24 库页改走 MD3 tabs 后的
    // `LibrarySectionTab(value: 0, label: …)`。2026-09-27 起「下载」改名「浏览」，
    // 原「资源」页签就是「发现」页签（BrowseTab 枚举，不再按下标），本条守的**行为**
    // 没变：这个页签只是四个模块生产发现页的 hub，不是另写的第二个 discovery 页。
    expect(source, contains('BrowseTab.discover => t.library_view_discover,'));
    expect(source, contains('BrowseTab.discover => _buildResourceHub(),'));
    // 承载形态第四次变化：下拉框 → 与库页同构的 FushiSegmentedStrip（#1097）。
    // 判据按**泛型参数**认，与控件形态无关；再显式钉住「只有一个」——reason 里
    // 「唯一」二字原来其实没被测到，contains 有一个就过。
    final Iterable<RegExpMatch> domainSelectors = RegExp(
      r'Fushi\w+<_DownloadsResourceDomain>\(',
    ).allMatches(source);
    expect(
      domainSelectors.length,
      1,
      reason: '资源首页必须先用**唯一**一个类型选择器选择内容域'
          '（形态可换，个数不能变）',
    );
    expect(source, contains('MediaDiscoveryPage('));
    expect(source, contains('MangaDiscoveryPage('));
    expect(source, contains('VideoDiscoveryPage('));
    expect(source, contains('embedded: true'));
    expect(
      home,
      contains('videoDiscoveryController: _productionVideoDiscoveryController'),
      reason: '下载页视频发现不得落到 EmptyVideoDiscoveryController',
    );
    expect(
      home,
      contains('videoDiscoveryActions: _productionVideoDiscoveryActions'),
    );
    expect(source, contains('VideoDownloadJobsPanel.database('));
    expect(source, contains('VideoDownloadSubscriptionsPanel()'));
    expect(source, isNot(contains('download_discover_tab')));
  });
}
