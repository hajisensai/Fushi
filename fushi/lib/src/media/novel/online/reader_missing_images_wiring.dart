import 'dart:async';

import 'package:fushi/src/media/novel/online/online_novel_chapter_loader.dart';
import 'package:fushi/src/media/novel/online/online_novel_missing_images.dart';

/// 开书时给这本书挑缺图补取器：
///
/// - 有取章加载器（LNReader 在线书 / 网页小说书）且它能补图：用加载器本身；
/// - 没有取章加载器（LNReader 下载成的 EPUB、普通 EPUB）：问 [downloadedBookImages]
///   （下载书按章节里的缺图占位补取；合规门关着时它给 null）；
/// - 有加载器但不能补图：不建。
OnlineNovelMissingImagesRetrier? readerMissingImagesRetrierFor({
  required OnlineNovelChapterLoader? chapterLoader,
  required OnlineNovelMissingImagesRetrier? Function() downloadedBookImages,
}) => switch (chapterLoader) {
  final OnlineNovelMissingImagesRetrier retrier => retrier,
  null => downloadedBookImages(),
  _ => null,
};

/// 阅读器拦截层下发一个 `/epub/` 资源之前：有取章加载器的书交给
/// [ensureOnlineChapter]（它把占位页换成正文后自己报给缺图接线）；没有加载器的书
/// （LNReader 下载成的 EPUB）正文本来就在盘上，直接把这一章报给 [missingImages]。
Future<void> prepareReaderChapterFile({
  required String filePath,
  required OnlineNovelChapterLoader? chapterLoader,
  required ReaderMissingImagesWiring? missingImages,
  required Future<void> Function(OnlineNovelChapterLoader loader)
  ensureOnlineChapter,
}) async {
  if (chapterLoader != null) {
    await ensureOnlineChapter(chapterLoader);
  } else {
    missingImages?.chapterFileServed(filePath);
  }
}

/// 阅读器与缺图状态机（[OnlineNovelMissingImagesController]）之间的接线：章节下发时
/// 交给状态机查缺图 / 自动补取，本次导航的目标章让顶部提示跟上；补到图后丢这一章
/// 的缓存，正在读这一章就原地重载。页面状态经回调读，不在这里存镜像。
class ReaderMissingImagesWiring {
  ReaderMissingImagesWiring({
    required OnlineNovelMissingImagesRetrier retrier,
    required bool Function() isActive,
    required int Function() currentChapter,
    required bool Function() restoreInFlight,
    required bool Function(int index, bool Function(String filePath) inChapter)
    discardChapterCaches,
    required Future<void> Function() reloadCurrentChapter,
    void Function(OnlineNovelMissingImagesRetry result)? onManualRetryFinished,
    void Function(Object error)? onError,
  }) : _isActive = isActive,
       _currentChapter = currentChapter,
       _restoreInFlight = restoreInFlight,
       _discardChapterCaches = discardChapterCaches,
       _reloadCurrentChapter = reloadCurrentChapter {
    controller = OnlineNovelMissingImagesController(
      retrier: retrier,
      onRecovered: _onRecovered,
      onManualRetryFinished: onManualRetryFinished,
      onError: onError,
    );
  }

  final bool Function() _isActive;
  final int Function() _currentChapter;
  final bool Function() _restoreInFlight;

  /// 丢掉第 index 章的下发缓存（`inChapter` 判文件属不属于这一章）与正文缓存；
  /// 书还没就绪 / 章号越界时什么都不做并返回 false。
  final bool Function(int index, bool Function(String filePath) inChapter)
  _discardChapterCaches;
  final Future<void> Function() _reloadCurrentChapter;

  /// 顶部提示条（`OnlineNovelMissingImagesNoticeBar`）绑定的状态机。
  late final OnlineNovelMissingImagesController controller;

  OnlineNovelMissingImagesRetrier get retrier => controller.retrier;

  /// 第 [index] 章成了当前章（导航落定 / 连续模式无缝换章）。
  void show(int index) => controller.show(index);

  /// 拦截层要下发正文文件 [filePath]（正文已在盘上）。
  void chapterFileServed(String filePath) =>
      chapterServed(retrier.chapterIndexForFile(filePath));

  /// 第 [index] 章正文即将下发：交给状态机查缺图、按需自动补取；是本次导航的
  /// 目标章就让提示跟到这一章。不是本书正文（[index] 为 null）时不管。
  void chapterServed(int? index) {
    if (index == null) return;
    unawaited(controller.chapterRequested(index));
    if (_restoreInFlight() && index == _currentChapter()) {
      controller.show(index);
    }
  }

  void _onRecovered(int index) {
    if (!_isActive()) return;
    final bool discarded = _discardChapterCaches(
      index,
      (String filePath) => retrier.chapterIndexForFile(filePath) == index,
    );
    if (!discarded) return;
    if (index == _currentChapter() && !_restoreInFlight()) {
      unawaited(_reloadCurrentChapter());
    }
  }

  void dispose() => controller.dispose();
}
