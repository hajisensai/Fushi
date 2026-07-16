// GENERATED-NOTE: extracted from reader_hibiki_history_page.dart (TODO-587).
part of '../reader_hibiki_history_page.dart';

/// 书架的视频导入入口（video domain，via part-of TODO-587；共享私有作用域）。
///
/// 视频已毕业为「视频」tab（[HomeVideoPage]）独占：书架不再渲染视频卡/分区，故原来
/// 的卡片、封面、长按面板、改名/换封面/删除等展示与管理方法已随书架视频分区一并
/// 删除。这里只保留**导入**入口——书架拖入视频/播放列表/流地址仍经 [_handleShelfDrop]
/// 打开 [VideoImportDialog] 落库（导入后只在视频 tab 可见，书架不再刷新视频列表）。
extension _ReaderHistoryVideo on _ReaderHibikiHistoryPageState {
  /// 编译期调试入口（`kVideoImportEnabled` 默认关，运行时不放出，见页头
  /// [_buildPageHeader]）：打开空白 [VideoImportDialog]。导入后视频只在「视频」tab
  /// 呈现，书架不再刷新视频。
  Future<void> _openVideoImport() async {
    await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(repo: _videoRepo),
    );
  }

  /// 书架拖入视频 → 打开 [VideoImportDialog] 预填视频/字幕路径（自动切到视频导入，
  /// 带上拖入文件，用户无需重选）。导入后视频归「视频」tab，书架不显示视频。
  Future<void> _openVideoImportPrefilled({
    required String videoPath,
    required String? subtitlePath,
  }) async {
    await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(
        repo: _videoRepo,
        initialVideoPath: videoPath,
        initialSubtitlePath: subtitlePath,
      ),
    );
  }

  /// 书架拖入 m3u8/m3u 播放列表 → 打开 [VideoImportDialog] 预填 playlist 路径，
  /// 对话框自动解析多集落库（与视频 tab 同一路径）。
  Future<void> _openPlaylistImportPrefilled({
    required String playlistPath,
  }) async {
    await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(
        repo: _videoRepo,
        initialPlaylistPath: playlistPath,
      ),
    );
  }

  /// 书架拖入网络流 URL（浏览器地址栏/链接）→ 打开 [VideoImportDialog] 预填 URL，对话框
  /// 可播时自动导入（进视频库，TODO-1306）。
  Future<void> _openStreamImportPrefilled({
    required String streamUrl,
  }) async {
    await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(
        repo: _videoRepo,
        initialStreamUrl: streamUrl,
      ),
    );
  }
}
