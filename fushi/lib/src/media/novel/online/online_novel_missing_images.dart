import 'package:flutter/foundation.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一章里没取到的插图（[OnlineNovelMissingImagesRetrier.missingImages] 的结果）。
@immutable
class OnlineNovelMissingImages {
  const OnlineNovelMissingImages({
    required this.index,
    required this.count,
    required this.autoRetryAvailable,
  });

  /// 章号（0 基）。
  final int index;

  /// 还缺几张。
  final int count;

  /// 还有没有图能自动补取（每张图的自动补取次数有上限，用尽后只能手动）。
  final bool autoRetryAvailable;
}

/// 补取一轮的结果。
@immutable
class OnlineNovelMissingImagesRetry {
  const OnlineNovelMissingImagesRetry({
    required this.index,
    required this.recovered,
    required this.remaining,
  });

  final int index;

  /// 这一轮补到几张（已写回解压树，章节文件里换回了 `<img>`）。
  final int recovered;

  /// 补完还缺几张。
  final int remaining;
}

/// 网文书的可选能力：章节里没取到的插图能查、能补取。
///
/// 三个实现，都靠章节文件里的缺图占位（`lnreader_missing_images.dart`）：
/// LNReader 在线书与网页小说书的按需取章加载器（`LnReaderOnlineChapterLoader` /
/// `WebNovelChapterLoader`），以及 LNReader 下载成 EPUB 的书
/// （`LnReaderDownloadedBookImages`，没有取章加载器）。阅读器只认这个接口，不分来源。
abstract interface class OnlineNovelMissingImagesRetrier {
  /// [filePath] 对应的章（0 基）；不是本书的正文文件返回 null。阅读器据此把
  /// 下发的章节文件对到章号、补到图后丢这一章的缓存。
  int? chapterIndexForFile(String filePath);

  /// 第 [index] 章还缺几张图。章节文件不在 / 还是占位页时 count = 0。
  Future<OnlineNovelMissingImages> missingImages(int index);

  /// 补取第 [index] 章缺的图。[automatic] = 打开章节时的自动补取：只试还没用尽
  /// 自动次数的图；手动补取试全部。每张没补到的图记一次尝试。取不到插件 / 运行时
  /// 抛出。
  Future<OnlineNovelMissingImagesRetry> retryMissingImages(
    int index, {
    required bool automatic,
  });
}

/// 阅读器顶部「本章 N 张插图没取到」提示的当前内容。
@immutable
class OnlineNovelMissingImagesNotice {
  const OnlineNovelMissingImagesNotice({
    required this.chapter,
    required this.count,
    required this.retrying,
  });

  final int chapter;
  final int count;

  /// 用户点了「重新获取」、正在取。
  final bool retrying;
}

/// 阅读器侧的缺图状态机（维护者拍板 a+b）：
///
/// - 章节被请求时（[chapterRequested]）查一次缺图；还有自动次数就在后台静默补
///   取一轮（每章每次开书至多一轮，每张图跨会话至多
///   `kLnReaderMissingImageAutoRetries` 轮），补到了经 [onRecovered] 让阅读器刷新
///   这一章；
/// - 补完仍缺（或自动次数已用尽）时，当前章（[show]）给出可关的提示，用户点
///   「重新获取」才再取（[retry]）——坏图床不会被反复自动请求；
/// - 自动补取进行中不出提示（取不到才提示）。
class OnlineNovelMissingImagesController extends ChangeNotifier {
  OnlineNovelMissingImagesController({
    required this.retrier,
    required this.onRecovered,
    this.onManualRetryFinished,
    this.onError,
  });

  final OnlineNovelMissingImagesRetrier retrier;

  /// 第 index 章补到了图（文件已写回）：阅读器丢缓存、必要时重载这一章。
  final void Function(int index) onRecovered;

  /// 手动补取结束（给出结果提示用）。
  final void Function(OnlineNovelMissingImagesRetry result)?
  onManualRetryFinished;

  /// 手动补取出错（插件没装 / 运行时起不来）。
  final void Function(Object error)? onError;

  final Map<int, int> _remaining = <int, int>{};
  final Set<int> _inspected = <int>{};
  final Set<int> _autoRetrying = <int>{};
  final Set<int> _manualRetrying = <int>{};
  final Set<int> _dismissed = <int>{};
  int? _visible;
  bool _disposed = false;

  /// 当前该显示的提示；没有返回 null。
  OnlineNovelMissingImagesNotice? get notice {
    final int? chapter = _visible;
    if (chapter == null ||
        _dismissed.contains(chapter) ||
        _autoRetrying.contains(chapter)) {
      return null;
    }
    final int count = _remaining[chapter] ?? 0;
    if (count <= 0) return null;
    return OnlineNovelMissingImagesNotice(
      chapter: chapter,
      count: count,
      retrying: _manualRetrying.contains(chapter),
    );
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// 第 [index] 章成了当前章（导航落定 / 连续模式无缝换章）。
  void show(int index) {
    if (_visible == index) return;
    _visible = index;
    _changed();
  }

  /// 第 [index] 章被阅读器请求（导航目标、预热的邻章都算）：本次开书第一次请求
  /// 时查缺图，能自动补取就补一轮。
  Future<void> chapterRequested(int index) async {
    if (_disposed || !_inspected.add(index)) return;
    try {
      final OnlineNovelMissingImages missing = await retrier.missingImages(
        index,
      );
      if (_disposed) return;
      _remaining[index] = missing.count;
      if (missing.count == 0) {
        _changed();
        return;
      }
      if (!missing.autoRetryAvailable) {
        _changed();
        return;
      }
      _autoRetrying.add(index);
      _changed();
      final OnlineNovelMissingImagesRetry result = await retrier
          .retryMissingImages(index, automatic: true);
      _apply(result);
    } on Object catch (error, stack) {
      // 自动补取失败不打断阅读：提示照样按已知的缺图数出，用户可手动再取。
      ErrorLogService.instance.log(
        'OnlineNovelMissingImages.autoRetry',
        error,
        stack,
      );
    } finally {
      _autoRetrying.remove(index);
      _changed();
    }
  }

  /// 用户点了当前提示上的「重新获取」。
  Future<void> retry() async {
    final OnlineNovelMissingImagesNotice? current = notice;
    if (current == null || current.retrying) return;
    final int index = current.chapter;
    _manualRetrying.add(index);
    _changed();
    try {
      final OnlineNovelMissingImagesRetry result = await retrier
          .retryMissingImages(index, automatic: false);
      _apply(result);
      if (!_disposed) onManualRetryFinished?.call(result);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'OnlineNovelMissingImages.manualRetry',
        error,
        stack,
      );
      if (!_disposed) onError?.call(error);
    } finally {
      _manualRetrying.remove(index);
      _changed();
    }
  }

  /// 关掉当前章的提示（本次开书内不再出；补取状态不变）。
  void dismiss() {
    final int? chapter = _visible;
    if (chapter == null || !_dismissed.add(chapter)) return;
    _changed();
  }

  void _apply(OnlineNovelMissingImagesRetry result) {
    if (_disposed) return;
    _remaining[result.index] = result.remaining;
    if (result.recovered > 0) onRecovered(result.index);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
