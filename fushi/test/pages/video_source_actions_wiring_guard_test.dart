import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('视频导入视图把整库刮削、后台任务与清理记录登记进浮动顶栏（IM18）', () {
    final String source = File(
      'lib/src/pages/implementations/video_import_page.dart',
    ).readAsStringSync();
    // Material：平铺「整库刮削」「后台任务」，「清空刮削记录」进 ⋯；Apple 三项都进 ⋯。
    final int scrape = source.indexOf('tooltip: t.scrape_all');
    final int tasks = source.indexOf(
      'tooltip: t.video_source_scrape_tasks_open',
    );
    expect(scrape, greaterThanOrEqualTo(0));
    expect(tasks, greaterThan(scrape));
    expect(source, contains('label: t.video_source_scrape_clear_all'));
    expect(source, contains('FushiHeaderMoreButton('));
    expect(source, contains('widget.onScrapeAll'));
    expect(source, contains('widget.onClearAllScrapeRecords != null'));
    // 两套设计系统都建页头（此前 Cupertino 不建，iOS 看不到这三项）。
    expect(
      source,
      isNot(contains('if (!isCupertinoPlatform(context)) _buildHeader')),
    );
  });

  test('视频来源页与 HomePage 提供可重复进入的后台任务面板', () {
    final String page = File(
      'lib/src/pages/implementations/video_import_page.dart',
    ).readAsStringSync();
    final String home = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    expect(page, contains('widget.onOpenScrapeTasks'));
    expect(page, contains('t.video_source_scrape_tasks_open'));
    expect(home, contains('showVideoSourceScrapeTaskPanel'));
    expect(home, contains('video-source-background-task-panel'));
    expect(home, contains('video_source_scrape_background_started'));
    expect(home, isNot(contains('showVideoSourceScrapeDialog')));
  });

  test('导入页与设置页复用同一清理动作，成功后重读保活来源页', () {
    final String page = File(
      'lib/src/pages/implementations/video_import_page.dart',
    ).readAsStringSync();
    final String view = File(
      'lib/src/pages/implementations/media_sources_view.dart',
    ).readAsStringSync();
    final String settings = File(
      'lib/src/settings/settings_schema_video.dart',
    ).readAsStringSync();
    final String action = File(
      'lib/src/media/video/metadata/video_scrape_cleanup_action.dart',
    ).readAsStringSync();

    expect(page, contains('onSelected: _clearAllScrapeRecords'));
    expect(settings, contains('showClearAllVideoScrapeRecordsAction'));
    expect(action, contains('VideoScrapeCleanupService('));
    // Feedback 7NBVwW-6Qc：确认框必须给出「只清记录 / 连同生成文件」两种方式，
    // 勾选态真正传到清理服务，CLI 也能选。
    expect(
      action,
      contains('checkboxLabel: t.video_source_scrape_clear_all_delete_files'),
    );
    expect(
      action,
      contains(
        'videoScrapeCleanupModeFor(deleteGeneratedFiles: confirmed.checked)',
      ),
    );
    expect(action, contains('.clearAll(mode: mode)'));
    expect(settings, contains("deleteGeneratedFiles: files == 'delete'"));
    expect(action, contains('videoScrapeCleanupRevision.value += 1'));
    expect(
      view,
      contains(
        'videoScrapeCleanupRevision.addListener(_onVideoScrapeCleanupChanged)',
      ),
    );
    expect(view, contains('if (mounted) unawaited(_load());'));
  });

  test('视频添加来源走本地/网络选择器（网络仅可原地流播的 transport），扫描收尾通知媒体库变化', () {
    // 网络来源三域开放后，视频不再短路直选文件夹：与书/漫画共用同一个
    // 本地/网络选择对话框，只是 transport 集收窄到能原地流播的那几种
    // （WebDAV；PR #1557 起加 AList 签名直链；SFTP 经回环中继按偏移读），
    // ftp 读不了区间、不进视频域。
    final String source = File(
      'lib/src/pages/implementations/media_sources_view.dart',
    ).readAsStringSync();
    expect(source, contains('showImportChoiceDialog<_AddSourceChoice>'));
    expect(source, contains('await addLocalFolder();'));
    // 传输集只在 import_surface_spec.dart 定义一次（BUG-4858 / IM10），来源视图委托它。
    final String spec = File(
      'lib/src/media/import/import_surface_spec.dart',
    ).readAsStringSync();
    expect(source, contains('importNetworkTransports(widget.mediaKind)'));
    expect(
      spec,
      // 音乐网络来源与视频同一套可流播 transport（逐曲远程播放同样要按偏移读）。
      contains(
        "'video' || 'music' => const <String>['sftp', 'webdav', 'alist']",
      ),
      reason: '视频 / 音乐网络 transport 必须收窄到可原地流播的 sftp + webdav + alist',
    );
    expect(
      spec,
      isNot(contains(RegExp(r"'video'[^=\n]*=> const <String>\[[^\]]*'ftp'"))),
      reason: 'ftp 不能按偏移读、拖不了进度条，不得进视频域',
    );
    expect(source, contains('onLibraryChanged?.call();'));
  });

  test('视频来源行独占刮削、共享互斥锁并开放受确认保护的策略设置', () {
    final String page = File(
      'lib/src/pages/implementations/video_import_page.dart',
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
    expect(view, contains('t.video_source_scrape_action'));
    expect(
      view,
      contains("enabled: !busy && row.videoGroupingMode != 'folder'"),
    );
    expect(view, contains('tooltip: t.video_source_scrape_settings'));
    expect(view, contains("widget.mediaKind == 'video'"));
    expect(view, contains('controller.runSourceScan(row.id, scan)'));
    expect(
      view,
      contains('await onVideoScanCompleted(updated ?? row, summary)'),
    );
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
    expect(
      home,
      contains('onClearAllScrapeRecords: _clearAllVideoScrapeRecords'),
    );
    expect(home, contains('showClearAllVideoScrapeRecordsAction'));
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
