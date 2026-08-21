import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HomePage injects the real discovery service and action ports', () {
    final String source = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    final String acquisitionSource = File(
      'lib/src/pages/implementations/video_discovery_acquisition_dialogs.dart',
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
    expect(source, contains('onSubscribe: _openVideoDiscoverySubscription'));
    expect(
      source,
      contains(
        'onOpenSubscriptions: _openVideoDiscoverySubscriptionsPanel',
      ),
    );
    expect(source, contains('watchStatus: _watchVideoDiscoveryStatus'));
    expect(source, contains('onPlay: _openLocalVideoDiscoveryWork'));
    expect(source, contains('VideoDiscoveryResourceSearchPage('));
    expect(source, contains('VideoDiscoverySubscriptionPage('));
    expect(source, contains('VideoDiscoverySubtitleSearchPage('));
    expect(
      RegExp(r'provider\.id == kNyaaResourceProviderId').allMatches(source),
      hasLength(2),
      reason: '发现页资源搜索和订阅都必须只使用 Nyaa',
    );
    expect(
      source,
      contains("provider.id == 'jimaku'"),
      reason: '发现页字幕搜索必须只使用 Jimaku',
    );
    final int resourceStart =
        source.indexOf('Future<void> _openVideoDiscoveryResourceSearch(');
    final int subtitleStart =
        source.indexOf('Future<void> _openVideoDiscoverySubtitleSearch(');
    final String acquisitionActions = source.substring(
      resourceStart,
      subtitleStart,
    );
    expect(
      acquisitionActions,
      isNot(contains('if (sources.isEmpty)')),
      reason: '搜索资源和订阅应先打开搜索页，不能被本地落地目录提前拦截',
    );
    expect(
      RegExp(r'currentVideoDownloadBackendIdentity\(\)')
          .allMatches(acquisitionActions),
      hasLength(2),
      reason: '资源下载与订阅都应在用户提交选择后才解析下载后端',
    );
    expect(
      acquisitionActions.indexOf('VideoDiscoveryResourceSearchPage('),
      lessThan(acquisitionActions.indexOf(
        'currentVideoDownloadBackendIdentity()',
      )),
      reason: '搜索页必须先于资源提交阶段的后端解析出现',
    );
    expect(
      acquisitionSource,
      contains('on VideoDownloadBackendUnavailable catch (error)'),
    );
    expect(acquisitionSource, contains('on ArgumentError'));
    expect(
      acquisitionSource,
      contains('on VideoDownloadPipelineActionRequired catch (error)'),
      reason: '提交阶段的后端和流水线错误必须留在搜索页内呈现',
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

    // PR#820 起下载页门头是 FushiSegmentedStrip（与库页同构），首段承载形态
    // 由 `Tab(text: …)` 变为 `ButtonSegment(value: 0, label: Text(…))`；本条守的
    // 行为不变：第一段必须是「资源」，不是第二个 discovery 页。
    expect(source, contains('label: Text(t.download_resources_tab)'));
    expect(source, contains('VideoResourceSearchSurface('));
    expect(source, contains('VideoDownloadJobsPanel.database('));
    expect(source, contains('VideoDownloadSubscriptionsPanel()'));
    expect(source, isNot(contains('download_discover_tab')));
  });
}
