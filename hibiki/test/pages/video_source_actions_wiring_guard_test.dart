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

  test('视频添加来源直选文件夹，扫描收尾通知媒体库变化', () {
    final String source = File(
      'lib/src/pages/implementations/media_sources_view.dart',
    ).readAsStringSync();
    final int direct = source.indexOf("if (widget.mediaKind == 'video')");
    final int chooser = source.indexOf('showAppDialog<_AddSourceChoice>');
    expect(direct, greaterThanOrEqualTo(0));
    expect(direct, lessThan(chooser));
    expect(source, contains('await _addLocalFolder();'));
    expect(source, contains('onLibraryChanged?.call();'));
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
