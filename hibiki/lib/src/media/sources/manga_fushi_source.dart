import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/utils.dart';

/// 漫画书的媒体源（漫画 OCR / mokuro，P1）。
///
/// 设计要点（与 PDF 同款「漫画只是第三种书身份」）：
/// - 漫画与 EPUB/PDF **共用一张 `EpubBooks` 表、一块书架、一套删除/进度管线**。书架列书
///   仍走 [ReaderFushiSource.getBooksFromDb]（列全部行，format-agnostic）；漫画行靠
///   `EpubBooks.format=='manga'` 在 [ReaderFushiSource] 的 `_bookToMediaItem` 里被打上
///   `mediaSourceIdentifier: `[kUniqueKey]，从而在**打开时**被路由到本源、进
///   [MangaFushiPage]，而不是 EPUB 的 [ReaderFushiPage]。
/// - 漫画复用 EPUB 的媒体标识方案（`hoshi://book/<bookKey>`，bookKey 是 `EpubBooks`
///   主键，与 format 无关）——**没有漫画专属 scheme 特例**：路由只认
///   `mediaSourceIdentifier`，而关书自动同步（`triggerAutoSyncAfterClose` 的
///   `hoshi://book/` 前缀识别）天然工作。
/// - 阅读器设置（翻页/查词等偏好）统一读 `ReaderFushiSource.instance`，本源不重复一套。
///
/// 本源只在打开一本漫画时被 `item.getMediaSource` 解析并短暂成为 `_currentMediaSource`；
/// 书架页头/搜索/源切换 UI 恒用默认的 [ReaderFushiSource]，故本源的
/// [getActions]/[buildHistoryPage] 极少被触达，实现取与 PDF 源一致的安全回退。
class MangaFushiSource extends ReaderMediaSource {
  MangaFushiSource._()
      : super(
          uniqueKey: kUniqueKey,
          sourceName: t.source_name_bookshelf,
          description: t.source_description_epub,
          icon: Icons.collections_bookmark_outlined,
          implementsSearch: false,
          implementsHistory: false,
        );

  /// 媒体源唯一键（持久化标识，与 `reader_fushi`/`reader_pdf` 互异）。
  /// [ReaderFushiSource] 的 `_bookToMediaItem` 用它把 `format=='manga'` 的行路由到本源。
  static const String kUniqueKey = 'reader_manga';

  static MangaFushiSource get instance => _instance;
  static final MangaFushiSource _instance = MangaFushiSource._();

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
        ReaderFushiSource.parseBookKey(item?.mediaIdentifier ?? '') ?? '';
    // 漫画在 WebView 里按原生密度渲染；与阅读器一致包 UI-scale 中和层，
    // 保证弹窗坐标契约（JS getClientRects 视口坐标 → 屏幕坐标恒等映射）。
    return FushiAppUiScaleNeutralizer(
      child: MangaFushiPage(item: item, bookKey: bookKey),
    );
  }

  @override
  List<Widget> getActions({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) {
    // 漫画有自己的导入按钮与对话框（载体不同、可填字段就不同）；本源作为打开-漫画
    // 的短暂当前源，页头动作给出漫画导入以防被设为当前源时缺动作。
    return <Widget>[
      buildMangaImportButton(
        context: context,
        ref: ref,
        appModel: appModel,
      ),
    ];
  }

  /// 「导入漫画」按钮。与 [ReaderFushiSource.buildBookImportButton] 并列而非复用：
  /// 两者打开的是不同对话框，仅外观规格（尺寸/宽窗展开成图标+文字）保持一致。
  Widget buildMangaImportButton({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    FushiFocusId? focusId,
    String? label,
  }) {
    return FushiIconButton(
      tooltip: t.manga_import_action,
      label: label,
      icon: Icons.library_add_outlined,
      focusId: focusId,
      onTap: () async {
        final bool? imported = await showAppDialog<bool>(
          context: context,
          builder: (_) => MangaImportDialog(db: appModel.database),
        );
        if (imported == true) {
          ref.invalidate(hibikiBooksProvider(JapaneseLanguage.instance));
          ref.invalidate(srtBooksProvider);
        }
      },
    );
  }

  @override
  BasePage buildHistoryPage({MediaItem? item, Widget? navigation}) {
    return ReaderFushiHistoryPage(navigation: navigation);
  }

  /// 漫画是 `EpubBooks`（`format=='manga'`）的行，和 EPUB 共用可编辑的 `author` 列，
  /// 因此同样开放作者编辑。此前 `MangaFushiSource extends ReaderMediaSource` 未覆盖，
  /// 沿用基类默认 `false`，导致漫画长按编辑里缺作者字段（EPUB 有）——补齐这条缺口。
  @override
  bool get supportsAuthorEdit => true;

  /// 委托给 [ReaderFushiSource]：作者写库逻辑（按 bookKey 写 `epubBooks.author`）与源
  /// 实例无关（走 sharedDatabase + item.mediaIdentifier），漫画行的 bookKey 解析一致，
  /// 直接复用同一条写入路径，不重复实现。
  @override
  Future<void> setAuthorFromMediaItem({
    required MediaItem item,
    required String? author,
  }) =>
      ReaderFushiSource.instance
          .setAuthorFromMediaItem(item: item, author: author);
}
