import 'package:flutter/widgets.dart';

import 'package:hibiki/src/media/manga/manga_browse_page.dart';
import 'package:hibiki/src/media/manga/manga_sources_page.dart';
import 'package:hibiki/src/pages/implementations/media_library_shell.dart';
import 'package:hibiki/src/pages/implementations/module_settings_view.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/utils.dart';

/// 顶层漫画库页：**恒为三视图**，五个平台完全同构。
///
/// - **书架**：数据、卡片、搜索、排序、合集、进度和删除全部复用小说书架；唯一差异
///   是只展示 `EpubBooks.format == 'manga'` 的条目。普通书架由同一页面反向排除漫画。
/// - **浏览**：可浏览内容的在线来源清单——内置 mokuro.moe 目录 + 已启用的 Mihon
///   在线来源，两者并列。
/// - **来源**：本地漫画扫描根 + 漫画扩展（仓库/安装/启停）+ 扩展提供的在线来源
///   设置。**扩展就是来源**，因此收在这里而不是另开一个顶层 tab。
///
/// 视图列表是**无条件常量**：不按 `MihonRuntimeFactory.isSupported` 分叉，
/// iOS / Linux 与 Android / Windows / macOS 的 tab 数量、顺序、kind 完全一致，
/// 差异只落在各视图**内部内容**（没有扩展宿主时相应小节显示为不可用）。导航结构
/// 分平台漂移会让快捷键、焦点顺序和用户肌肉记忆按平台裂开。
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
              ReaderHibikiHistoryPage(mangaOnly: true, navigation: navigation),
        ),
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.browse,
          label: t.library_view_browse,
          builder: (BuildContext context, Widget navigation) =>
              MangaBrowsePage(navigation: navigation),
        ),
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.sources,
          label: t.library_view_sources,
          builder: (BuildContext context, Widget navigation) =>
              MangaSourcesPage(navigation: navigation),
        ),
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.settings,
          label: t.settings,
          builder: (BuildContext context, Widget navigation) =>
              ModuleSettingsView(
            destinationId: SettingsDestinationId.reading,
            navigation: navigation,
          ),
        ),
      ],
    );
  }
}
