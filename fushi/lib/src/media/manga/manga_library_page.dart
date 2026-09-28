import 'package:flutter/widgets.dart';

import 'package:fushi/src/media/manga/manga_sources_page.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// 顶层漫画库页：**书架 + 导入**两视图（外加设置）。
///
/// - **书架**：数据、卡片、搜索、排序、合集、进度和删除全部复用小说书架；唯一差异
///   是只展示 `EpubBooks.format == 'manga'` 的条目。普通书架由同一页面反向排除漫画。
/// - **导入**：本地漫画扫描根 + 快速导入 + 互联对端的漫画库。
///
/// 发现页（AniList 榜单 / 来源热门行）与在线来源、扩展仓库、扩展目录
/// 2026-09-27 起只住在顶层「浏览」模块（`browse_page.dart`，Mihon 的 Browse 形态），
/// 库页不再挂在线入口；iOS 的合规边界因此也只需要在「浏览」一处判。
///
/// Mihon 在线漫画复用 EpubBooks 的漫画身份进入同一书架，当前章节/页码可跨重启
/// 继续；页面仍由来源运行时按需流式获取，不把鉴权 URL 暴露给 WebView。
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
              ReaderFushiHistoryPage(mangaOnly: true, navigation: navigation),
        ),
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.sources,
          label: t.library_view_import,
          builder: (BuildContext context, Widget navigation) =>
              MangaSourcesPage(navigation: navigation),
        ),
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.settings,
          label: t.settings,
          builder: (BuildContext context, Widget navigation) =>
              ModuleSettingsView(
                // 漫画有独立的「漫画」设置分类（观看偏好 + OCR 引擎/模型 + 在线目录）；
                // 此前误指 reading（EPUB 字体/排版），漫画库页的设置标签里根本找不到 OCR。
                destinationId: SettingsDestinationId.manga,
                navigation: navigation,
              ),
        ),
      ],
    );
  }
}
