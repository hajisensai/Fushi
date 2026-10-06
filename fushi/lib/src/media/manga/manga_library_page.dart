import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart'
    show AiMediaAcquisitionDomain;
import 'package:fushi/src/media/manga/discovery/manga_discovery_page.dart';
import 'package:fushi/src/media/manga/manga_sources_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart';
import 'package:fushi/src/pages/implementations/discovery_ai_acquire_action.dart';
import 'package:fushi/src/pages/implementations/library_online_sources_view.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeScrollInset;
import 'package:fushi/utils.dart';

/// 顶层漫画库页：书架 / 发现 / 来源 / 扩展 / 导入 / 设置。
///
/// - **书架**：数据、卡片、搜索、排序、合集、进度和删除全部复用小说书架；唯一差异
///   是只展示 `EpubBooks.format == 'manga'` 的条目。普通书架由同一页面反向排除漫画。
/// - **发现**（AniList 榜单 / 来源热门行 / mokuro.moe、OPDS 的「浏览来源」节）、
///   **来源**（Mihon 已装源 + mokuro.moe）、**扩展**（扩展目录，仓库在页头动作）：
///   与顶层「浏览」模块同一组组件（2026-10-01 用户拍板加回库页子标签）。各自过
///   iOS 合规门；没有 Mihon 宿主的平台由漫画来源面自己换成「不可用」说明，视图
///   列表不按宿主分叉。
/// - **导入**：本地漫画扫描根 + 快速导入 + 互联对端的漫画库。
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
          // 书架主滚动视图自己让出浮动工具栏的高度（内容滚到工具栏底下）。
          handlesChromeInset: true,
          builder: (BuildContext context, Widget navigation) =>
              ReaderFushiHistoryPage(mangaOnly: true, navigation: navigation),
        ),
        if (StoreRestrictedCapability.externalDiscovery.isAvailable)
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.discover,
            // 发现页把自己的搜索 / 筛选行叠进浮动工具区，主滚动视图自己让位。
            handlesChromeInset: true,
            label: t.library_view_discover,
            // 「浏览来源」节经库页壳的 [MediaLibraryShellScope] 切到本页「来源」。
            builder: (BuildContext context, Widget navigation) => Consumer(
              builder: (BuildContext context, WidgetRef ref, Widget? _) =>
                  MangaDiscoveryPage(
                    navigation: navigation,
                    onAiAcquire: discoveryAiAcquireAction(
                      context: context,
                      readAppModel: () => ref.read(appProvider),
                      domain: AiMediaAcquisitionDomain.manga,
                      domainLabel: t.manga_library,
                      onlineDomain: OnlineSourcesDomain.manga,
                    ),
                  ),
            ),
          ),
        if (isOnlineSourcesDomainAvailable(OnlineSourcesDomain.manga))
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.onlineSources,
            // 主滚动视图自己把浮动工具区高度加成顶部内边距：工具区收起后不留空白。
            handlesChromeInset: true,
            label: t.library_view_sources,
            builder: (BuildContext context, Widget navigation) =>
                LibraryOnlineSourcesView(
                  domain: OnlineSourcesDomain.manga,
                  section: OnlineSourcesSection.sources,
                  navigation: navigation,
                ),
          ),
        if (isOnlineSourcesDomainAvailable(OnlineSourcesDomain.manga))
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.extensions,
            // 主滚动视图自己把浮动工具区高度加成顶部内边距：工具区收起后不留空白。
            handlesChromeInset: true,
            label: t.media_import_segment_extensions,
            builder: (BuildContext context, Widget navigation) =>
                LibraryOnlineSourcesView(
                  domain: OnlineSourcesDomain.manga,
                  section: OnlineSourcesSection.extensions,
                  navigation: navigation,
                ),
          ),
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.sources,
          // 主滚动视图自己把浮动工具区高度加成顶部内边距：工具区收起后不留空白。
          handlesChromeInset: true,
          label: t.library_view_import,
          builder: (BuildContext context, Widget navigation) =>
              MangaSourcesPage(navigation: navigation),
        ),
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.settings,
          // 设置正文的滚动视图自己吃掉工具区让位（MediaQuery 顶部 padding）。
          handlesChromeInset: true,
          label: t.settings,
          builder: (BuildContext context, Widget navigation) =>
              FushiFloatingChromeScrollInset(
                child: ModuleSettingsView(
                  // 漫画有独立的「漫画」设置分类（观看偏好 + OCR 引擎/模型 + 在线目录）；
                  // 此前误指 reading（EPUB 字体/排版），漫画库页的设置标签里根本找不到 OCR。
                  destinationId: SettingsDestinationId.manga,
                  navigation: navigation,
                ),
              ),
        ),
      ],
    );
  }
}
