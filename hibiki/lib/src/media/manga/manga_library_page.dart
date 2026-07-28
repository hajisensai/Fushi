import 'package:flutter/widgets.dart';

import 'package:hibiki/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_source_settings_page.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_sources_page.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_catalog_page.dart';
import 'package:hibiki/src/pages/implementations/media_library_shell.dart';
import 'package:hibiki/src/pages/implementations/media_sources_page.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart';
import 'package:hibiki/utils.dart';

/// 顶层漫画库页。Android / Windows / macOS 提供书架、漫画源、漫画扩展、来源设置；
/// iOS / Linux 没有动态扩展宿主，继续保留书架、Mokuro 浏览和本地来源三视图。
///
/// - **书架**：数据、卡片、搜索、排序、合集、进度和删除全部复用小说书架；唯一差异
///   是只展示 `EpubBooks.format == 'manga'` 的条目。普通书架由同一页面反向排除漫画。
/// - **漫画源**：Mokuro 内置来源和已启用的 Mihon 在线来源。
/// - **来源设置**：本地漫画扫描根、在线来源排序/启停及扩展偏好。
///
/// V1 在线章节只在临时会话内流式阅读，不写书籍数据库、阅读进度或离线下载。
///
/// 命名：`shelf` 在本仓命名术语表里已冻结给 `ShelfEntries`（条目排序/归属映射
/// 层），页面统称 library page，因此这里叫 `MangaLibraryPage` 而不是
/// `MangaShelfPage`（BUG-1164）。
class MangaLibraryPage extends StatelessWidget {
  const MangaLibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final bool mihonSupported = MihonRuntimeFactory.isSupported;
    return MediaLibraryShell(
      focusIdPrefix: 'manga-library-view',
      views: <MediaLibraryViewSpec>[
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.library,
          label: t.library_view_shelf,
          builder: (BuildContext context, Widget navigation) =>
              ReaderHibikiHistoryPage(mangaOnly: true, navigation: navigation),
        ),
        if (mihonSupported) ...<MediaLibraryViewSpec>[
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.mangaSources,
            label: t.library_view_manga_sources,
            builder: (BuildContext context, Widget navigation) =>
                MihonSourcesPage(navigation: navigation),
          ),
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.mangaExtensions,
            label: t.library_view_manga_extensions,
            builder: (BuildContext context, Widget navigation) =>
                MihonExtensionsPage(navigation: navigation),
          ),
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.sourceSettings,
            label: t.library_view_source_settings,
            builder: (BuildContext context, Widget navigation) =>
                MihonSourceSettingsPage(navigation: navigation),
          ),
        ] else ...<MediaLibraryViewSpec>[
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
      ],
    );
  }
}
