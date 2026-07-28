import 'package:flutter/widgets.dart';

import 'package:hibiki/src/media/manga/online/mokuro_moe_catalog_page.dart';
import 'package:hibiki/src/pages/implementations/media_library_shell.dart';
import 'package:hibiki/src/pages/implementations/media_sources_page.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart';
import 'package:hibiki/utils.dart';

/// 顶层漫画库页（中文按域叫「漫画书架」），三视图：书架 / 浏览 / 来源。
///
/// - **书架**：数据、卡片、搜索、排序、合集、进度和删除全部复用小说书架；唯一差异
///   是只展示 `EpubBooks.format == 'manga'` 的条目。普通书架由同一页面反向排除漫画。
/// - **浏览**：mokuro.moe 在线目录（下载页的对话框入口保留，两处同一份实现）。
/// - **来源**：本地漫画扫描根 + 未来的在线源设置，与书/视频域共用 [MediaSourcesPage]。
///
/// 在线收藏不另建「在线书架」——收藏即建行进同一个书架（数据模型统一，本地/在线不是
/// 两个库）。本地/在线的区分只活在「来源」视图里。
///
/// 命名：`shelf` 在本仓命名术语表里已冻结给 `ShelfEntries`（条目排序/归属映射
/// 层），页面统称 library page，因此这里叫 `MangaLibraryPage` 而不是
/// `MangaShelfPage`（BUG-1164）。
class MangaLibraryPage extends StatelessWidget {
  const MangaLibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MediaLibraryShell(
      focusIdPrefix: 'manga-library-view',
      views: <MediaLibraryViewSpec>[
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.library,
          label: t.library_view_shelf,
          builder: (BuildContext context, Widget navigation) =>
              ReaderHibikiHistoryPage(mangaOnly: true, navigation: navigation),
        ),
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.browse,
          label: t.library_view_browse,
          builder: (BuildContext context, Widget navigation) =>
              MokuroMoeCatalogPage(navigation: navigation),
        ),
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.sources,
          label: t.library_view_sources,
          builder: (BuildContext context, Widget navigation) =>
              MediaSourcesPage(mediaKind: 'manga', navigation: navigation),
        ),
      ],
    );
  }
}
