// GENERATED-NOTE: extracted from reader_fushi_history_page.dart (TODO-587).
part of '../reader_fushi_history_page.dart';

/// 书架的视频导入入口（video domain，via part-of TODO-587；共享私有作用域）。
///
/// 视频已毕业为「视频」tab（[HomeVideoPage]）独占：书架不再渲染视频卡/分区，故原来
/// 的卡片、封面、长按面板、改名/换封面/删除等展示与管理方法已随书架视频分区一并
/// 删除。这里只保留调试用的空白导入入口；书架拖入视频/播放列表/流地址的预填导入
/// 在 `routeReaderShelfDrop`（导入后只在视频 tab 可见，书架不再刷新视频列表）。
extension _ReaderHistoryVideo on _ReaderFushiHistoryPageState {
  /// 编译期调试入口（`kVideoImportEnabled` 默认关，运行时不放出，见页头
  /// [_buildPageHeader]）：打开空白 [VideoImportDialog]。导入后视频只在「视频」tab
  /// 呈现，书架不再刷新视频。
  Future<void> _openVideoImport() async {
    await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(repo: _videoRepo),
    );
  }
}
