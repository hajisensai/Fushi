/// 漫画阅读器「当前屏上那份窗口文档」的快照（manga-13）。
///
/// 改阅读器设置时，以前不论改的是哪一项都整份 `loadData` 重载窗口文档（webtoon
/// 是整卷 DOM），连常亮、音量键、全屏这类根本不进文档的项也会让页图全部重取、
/// 画面闪一下。判断「这次设置变更是否改到了文档」不能拿当前状态现建一份去和屏上
/// 那份比：翻页 / 滚动 / 捏合由 JS 在文档内推进、不重载，当前 spread、滚动比例、
/// 会话缩放早已和装载那一刻不同，现建的文档必然不一样。
///
/// 所以本类把装载那一刻的**导航输入**（[MangaWindowNavigation]）和文档串一起记下；
/// 判定时用这组导航输入、配上**当前**的设置重建一份，逐字比较。文档是这些输入的
/// 纯函数，相同即说明设置变更没有碰到文档，跳过重载（屏上的翻页 / 滚动 / 缩放
/// 状态原样保留）。
library;

import 'package:meta/meta.dart';

/// 窗口文档里由 JS 在文档内推进、不经重载就会变的输入。
@immutable
class MangaWindowNavigation {
  const MangaWindowNavigation({
    required this.documentGeneration,
    required this.currentSpread,
    required this.restoreFraction,
    required this.zoomPercent,
  });

  /// 文档自证归属用的 generation（每次装载都不同）。
  final int documentGeneration;

  /// 装载时的落点 spread（spread 模式窗口内翻页只 translateX，不重载）。
  final int currentSpread;

  /// 装载时的页内滚动比例（webtoon 滚动不重载）。
  final double restoreFraction;

  /// 装载时的会话缩放（捏合 / 滚轮缩放在 JS 里改，不重载）。
  final int zoomPercent;

  @override
  bool operator ==(Object other) =>
      other is MangaWindowNavigation &&
      other.documentGeneration == documentGeneration &&
      other.currentSpread == currentSpread &&
      other.restoreFraction == restoreFraction &&
      other.zoomPercent == zoomPercent;

  @override
  int get hashCode => Object.hash(
    documentGeneration,
    currentSpread,
    restoreFraction,
    zoomPercent,
  );
}

/// 按导航输入生成窗口文档串。
typedef MangaWindowDocumentBuilder =
    String Function(MangaWindowNavigation navigation);

/// 见库级注释。
class MangaWindowDocumentSnapshot {
  String? _document;
  MangaWindowNavigation? _navigation;

  /// 屏上是否有一份确知内容的文档。
  bool get hasDocument => _document != null;

  /// 文档装载成功（新文档已自证持有本次 generation）后记下。
  void record(String document, MangaWindowNavigation navigation) {
    _document = document;
    _navigation = navigation;
  }

  /// 屏上文档不再确知：开始新一次装载、WebView 被交还 / 重建、页面销毁。
  void invalidate() {
    _document = null;
    _navigation = null;
  }

  /// 用装载时的导航输入、配当前设置重建（[build]）后是否与屏上文档逐字相同。
  /// 没有确知文档时恒为 false（调用方照常重载）。
  bool matches(MangaWindowDocumentBuilder build) {
    final String? document = _document;
    final MangaWindowNavigation? navigation = _navigation;
    if (document == null || navigation == null) return false;
    return build(navigation) == document;
  }
}
