import 'package:flutter/widgets.dart';

import 'package:fushi/src/media/manga/discovery/manga_discovery_page.dart';
import 'package:fushi/src/media/manga/manga_sources_page.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// 顶层漫画库页：**书架 + 发现 + 来源**三视图（外加设置）。
///
/// - **书架**：数据、卡片、搜索、排序、合集、进度和删除全部复用小说书架；唯一差异
///   是只展示 `EpubBooks.format == 'manga'` 的条目。普通书架由同一页面反向排除漫画。
/// - **发现**：漫画唯一的发现入口——来源筛选下拉 + 搜索框，正文是 AniList 元数据
///   横滑行 + 各来源热门行 + 「浏览来源」清单（mokuro.moe / Aidoku / Mihon）。
///   AniList 条目点开后在已启用来源里自动匹配可读条目（`discovery/`）。
/// - **来源**：本地漫画扫描根 + 漫画扩展（仓库/安装/启停）+ 扩展提供的在线来源
///   设置。**扩展就是来源**，因此收在这里而不是另开一个顶层 tab。
///
/// 曾经还有第四个「浏览」视图（`library_view_browse`）放在线来源清单。它的文案被
/// 改成「发现」之后，漫画库里出现了两个字面完全相同的 tab，用户点哪个都叫发现
/// （BUG-1710）；两页能力互补，已合并进上面的「发现」，冗余 tab 删除。
///
/// 视图列表不按**运行时能力**分叉：不看 `MihonRuntimeFactory.isSupported`，
/// Linux 与 Android / Windows / macOS 的 tab 数量、顺序、kind 完全一致，差异只落
/// 在各视图**内部内容**（没有扩展宿主时相应小节显示为不可用）。导航结构按能力漂移
/// 会让快捷键、焦点顺序和用户肌肉记忆按平台裂开。
///
/// **iOS 是这条规则唯一的例外，且理由不同**：那里的「发现」不是「功能暂不可用」，
/// 而是按 App Store 合规整条不存在（[StoreRestrictedCapability]）——发现页的全部
/// 内容（AniList 榜单点开后的来源匹配、各来源热门行、mokuro.moe 卷下载）都以在线
/// 源宿主为前提，宿主不装配后留下的是一个点进去什么都没有的死 tab。「不可用提示」
/// 这条常规退路在这里也不合适：合规要求的是不提供入口，不是提供一个说明为什么没有
/// 的入口。
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
        if (StoreRestrictedCapability.externalDiscovery.isAvailable)
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.discover,
            label: t.library_view_discover,
            builder: (BuildContext context, Widget navigation) =>
                MangaDiscoveryPage(navigation: navigation),
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
