import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('视频来源页按添加来源 → 全部刮削排列，且动作仅视频可见', () {
    final String source = File(
      'lib/src/pages/implementations/media_sources_page.dart',
    ).readAsStringSync();
    final int add = source.indexOf('tooltip: t.media_source_add');
    final int scrape = source.indexOf('tooltip: t.scrape_all');
    expect(add, greaterThanOrEqualTo(0));
    expect(scrape, greaterThan(add));
    expect(source, contains("widget.mediaKind == 'video' &&"));
    expect(source, contains('widget.onScrapeAll != null'));
  });

  test('视频来源页与 HomePage 提供可重复进入的后台任务面板', () {
    final String page = File(
      'lib/src/pages/implementations/media_sources_page.dart',
    ).readAsStringSync();
    final String home = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    expect(page, contains('widget.onOpenScrapeTasks != null'));
    expect(page, contains('t.video_source_scrape_tasks_open'));
    expect(home, contains('showVideoSourceScrapeTaskPanel'));
    expect(home, contains('video-source-background-task-panel'));
    expect(home, contains('video_source_scrape_background_started'));
    expect(home, isNot(contains('showVideoSourceScrapeDialog')));
  });

  test('视频添加来源走本地/网络选择器（网络仅 WebDAV），扫描收尾通知媒体库变化', () {
    // 网络来源三域开放后，视频不再短路直选文件夹：与书/漫画共用同一个
    // 本地/网络选择对话框，只是 transport 集收窄到仅 WebDAV（原地流播）。
    final String source = File(
      'lib/src/pages/implementations/media_sources_view.dart',
    ).readAsStringSync();
    expect(source, contains('showAppDialog<_AddSourceChoice>'));
    expect(source, contains('await addLocalFolder();'));
    expect(
        source,
        contains(
            "widget.mediaKind == 'video'\n      ? const <String>['webdav']"),
        reason: '视频网络 transport 必须收窄到仅 WebDAV');
    expect(source, contains('onLibraryChanged?.call();'));
  });

  test('视频来源行独占刮削、共享互斥锁并开放受确认保护的策略设置', () {
    final String page = File(
      'lib/src/pages/implementations/media_sources_page.dart',
    ).readAsStringSync();
    final String view = File(
      'lib/src/pages/implementations/media_sources_view.dart',
    ).readAsStringSync();
    for (final String api in <String>[
      'onScrapeSource',
      'onVideoScanCompleted',
      'scrapeTaskController',
    ]) {
      expect(page, contains(api));
      expect(view, contains(api));
    }
    expect(view, contains('tooltip: t.video_source_scrape_action'));
    expect(view, contains('tooltip: t.video_source_scrape_settings'));
    expect(view, contains("widget.mediaKind == 'video'"));
    expect(view, contains('controller.runSourceScan(row.id, scan)'));
    expect(
        view, contains('await onVideoScanCompleted(updated ?? row, summary)'));
    expect(view, contains('nfoPolicy: Value<String>(draft.nfoPolicy)'));
    expect(view, contains('imagePolicy: Value<String>(draft.imagePolicy)'));
    expect(view, contains('allowExternalOverwrite:'));
    expect(view, contains('Value<bool>(draft.allowExternalOverwrite)'));
    expect(view, contains('video_source_scrape_external_overwrite_hint'));
  });

  test('HomePage 用同一刷新信号连接来源页与保活视频库', () {
    final String home = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    expect(home, contains('ValueNotifier<int> _videoLibraryRefreshSignal'));
    expect(home, contains('libraryRefreshSignal: _videoLibraryRefreshSignal'));
    expect(home, contains('onLibraryChanged: _notifyVideoLibraryChanged'));
    expect(home, contains('onScrapeAll: _scrapeAllVideosFromSources'));
    expect(home, contains('_videoLibraryRefreshSignal.value++'));
    expect(home, contains('_videoLibraryRefreshSignal.dispose()'));
  });

  test('HomeVideoPage 监听、换绑并释放刷新信号，UID stream 仍保留', () {
    final String video = File(
      'lib/src/pages/implementations/home_video_page.dart',
    ).readAsStringSync();
    expect(video, contains('libraryRefreshSignal?.addListener'));
    expect(video, contains('libraryRefreshSignal?.removeListener'));
    expect(video, contains('void didUpdateWidget(covariant HomeVideoPage'));
    expect(video, contains('void _onLibraryRefreshRequested()'));
    expect(video, contains('if (mounted) _refresh();'));
    expect(video, contains('watchVideoBookUids()'));
  });
}
