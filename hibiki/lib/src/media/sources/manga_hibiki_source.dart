import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// 漫画书的媒体源（漫画 OCR / mokuro，P1）。
///
/// 设计要点（与 PDF 同款「漫画只是第三种书身份」）：
/// - 漫画与 EPUB/PDF **共用一张 `EpubBooks` 表、一块书架、一套删除/进度管线**。书架列书
///   仍走 [ReaderHibikiSource.getBooksFromDb]（列全部行，format-agnostic）；漫画行靠
///   `EpubBooks.format=='manga'` 在 [ReaderHibikiSource] 的 `_bookToMediaItem` 里被打上
///   `mediaSourceIdentifier: `[kUniqueKey]，从而在**打开时**被路由到本源、进
///   [MangaHibikiPage]，而不是 EPUB 的 [ReaderHibikiPage]。
/// - 漫画复用 EPUB 的媒体标识方案（`hoshi://book/<bookKey>`，bookKey 是 `EpubBooks`
///   主键，与 format 无关）——**没有漫画专属 scheme 特例**：路由只认
///   `mediaSourceIdentifier`，而关书自动同步（`triggerAutoSyncAfterClose` 的
///   `hoshi://book/` 前缀识别）天然工作。
/// - 阅读器设置（翻页/查词等偏好）统一读 `ReaderHibikiSource.instance`，本源不重复一套。
///
/// 本源只在打开一本漫画时被 `item.getMediaSource` 解析并短暂成为 `_currentMediaSource`；
/// 书架页头/搜索/源切换 UI 恒用默认的 [ReaderHibikiSource]，故本源的
/// [getActions]/[buildHistoryPage] 极少被触达，实现取与 PDF 源一致的安全回退。
class MangaHibikiSource extends ReaderMediaSource {
  MangaHibikiSource._()
      : super(
          uniqueKey: kUniqueKey,
          sourceName: t.source_name_bookshelf,
          description: t.source_description_epub,
          icon: Icons.collections_bookmark_outlined,
          implementsSearch: false,
          implementsHistory: false,
        );

  /// 媒体源唯一键（持久化标识，与 `reader_ttu`/`reader_pdf` 互异）。
  /// [ReaderHibikiSource] 的 `_bookToMediaItem` 用它把 `format=='manga'` 的行路由到本源。
  static const String kUniqueKey = 'reader_manga';

  static MangaHibikiSource get instance => _instance;
  static final MangaHibikiSource _instance = MangaHibikiSource._();

  @override
  Future<void> prepareResources() async {}

  @override
  Future<void> onSourceExit({
    required AppModel appModel,
    required WidgetRef ref,
  }) async {
    // 与 EPUB/PDF 源同点失效：关书回书架时刷新书列表与「最近阅读」recency。
    ref.invalidate(hibikiBooksProvider(JapaneseLanguage.instance));
    ref.invalidate(bookLastReadAtProvider);
  }

  @override
  Future<void> onSearchBarTap({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) async {}

  @override
  Widget buildLaunchPage({
    MediaItem? item,
    Bookmark? initialBookmarkJump,
  }) {
    final String bookKey =
        ReaderHibikiSource.parseBookKey(item?.mediaIdentifier ?? '') ?? '';
    // 漫画在 WebView 里按原生密度渲染；与阅读器一致包 UI-scale 中和层，
    // 保证弹窗坐标契约（JS getClientRects 视口坐标 → 屏幕坐标恒等映射）。
    return HibikiAppUiScaleNeutralizer(
      child: MangaHibikiPage(item: item, bookKey: bookKey),
    );
  }

  @override
  List<Widget> getActions({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) {
    // 导入按钮统一由 EPUB 源提供（同一个对话框通吃 epub/pdf/manga）；本源作为打开-漫画
    // 的短暂当前源，页头动作复用同一按钮以防被设为当前源时缺动作。
    return <Widget>[
      ReaderHibikiSource.instance.buildBookImportButton(
        context: context,
        ref: ref,
        appModel: appModel,
      ),
    ];
  }

  @override
  BasePage buildHistoryPage({MediaItem? item}) {
    return const ReaderHibikiHistoryPage();
  }

  /// 漫画是 `EpubBooks`（`format=='manga'`）的行，和 EPUB 共用可编辑的 `author` 列，
  /// 因此同样开放作者编辑。此前 `MangaHibikiSource extends ReaderMediaSource` 未覆盖，
  /// 沿用基类默认 `false`，导致漫画长按编辑里缺作者字段（EPUB 有）——补齐这条缺口。
  @override
  bool get supportsAuthorEdit => true;

  /// 委托给 [ReaderHibikiSource]：作者写库逻辑（按 bookKey 写 `epubBooks.author`）与源
  /// 实例无关（走 sharedDatabase + item.mediaIdentifier），漫画行的 bookKey 解析一致，
  /// 直接复用同一条写入路径，不重复实现。
  @override
  Future<void> setAuthorFromMediaItem({
    required MediaItem item,
    required String? author,
  }) =>
      ReaderHibikiSource.instance
          .setAuthorFromMediaItem(item: item, author: author);
}
