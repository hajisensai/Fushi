import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart'
    show AiMediaAcquisitionDomain;
import 'package:fushi/src/media/discovery/user_server_discovery_view.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_page.dart';
import 'package:fushi/src/media/manga/manga_sources_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart';
import 'package:fushi/src/pages/implementations/discovery_ai_acquire_action.dart';
import 'package:fushi/src/pages/implementations/library_online_sources_view.dart';
import 'package:fushi/src/pages/implementations/media_discovery_page.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/pages/implementations/media_server/user_media_servers_view.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';

/// 顶层漫画库页：书架 / 发现 / 来源 / 扩展 / 导入。
///
/// - **书架**：数据、卡片、搜索、排序、合集、进度和删除全部复用小说书架；唯一差异
///   是只展示 `EpubBooks.format == 'manga'` 的条目。普通书架由同一页面反向排除漫画。
/// - **发现**（AniList 榜单 / 来源热门行 / mokuro.moe、OPDS 的「浏览来源」节）、
///   **来源**（Mihon 已装源 + mokuro.moe）、**扩展**（扩展目录，仓库在页头动作）：
///   与顶层「浏览」模块同一组组件（2026-10-01 用户拍板加回库页子标签）。各自过
///   iOS 合规门；没有 Mihon 宿主的平台由漫画来源面自己换成「不可用」说明，视图
///   列表不按宿主分叉。iOS 上没有内置发现源与 Mihon / mokuro.moe（AniList 榜单、
///   来源热门都不存在），「发现」只在用户配了能服务漫画的 OPDS / AList 服务器时
///   出现，直接是这些服务器的统一发现页（[userServerDiscoverViewAvailable]，
///   2026-10-27 用户拍板）。
/// - **导入**：本地漫画扫描根 + 快速导入 + 互联对端的漫画库。
///
/// Mihon 在线漫画复用 EpubBooks 的漫画身份进入同一书架，当前章节/页码可跨重启
/// 继续；页面仍由来源运行时按需流式获取，不把鉴权 URL 暴露给 WebView。
///
/// 命名：`shelf` 在本仓命名术语表里已冻结给 `ShelfEntries`（条目排序/归属映射
/// 层），页面统称 library page，因此这里叫 `MangaLibraryPage` 而不是
/// `MangaShelfPage`（BUG-1164）。
class MangaLibraryPage extends ConsumerWidget {
  const MangaLibraryPage({super.key});

  static const List<DiscoveryMediaKind> _userServerKinds = <DiscoveryMediaKind>[
    DiscoveryMediaKind.manga,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 平台常量先短路：有内置发现源的平台不订阅 appModel，行为与原来一致。
    final bool builtInDiscover =
        StoreRestrictedCapability.externalDiscovery.isAvailable;
    final bool userServerDiscover =
        !builtInDiscover &&
        ref.watch(
          appProvider.select(
            (AppModel appModel) => userServerDiscoverViewAvailable(
              appModel.mediaDiscoveryService,
              _userServerKinds,
            ),
          ),
        );
    final bool mediaServers = ref.watch(
      userMediaServersAvailableProvider(UserMediaServersDomain.manga),
    );
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
        // 「发现」只有一个视图：有内置发现源的平台是漫画发现页，iOS 上换成用户
        // 自配服务器的统一发现页（两者互斥，不能各占一个 tab，BUG-1710 守卫）。
        if (builtInDiscover || userServerDiscover)
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.discover,
            // 发现页把自己的搜索 / 筛选行叠进浮动工具区，主滚动视图自己让位。
            handlesChromeInset: true,
            label: t.library_view_discover,
            // 「浏览来源」节经库页壳的 [MediaLibraryShellScope] 切到本页「来源」。
            builder: (BuildContext context, Widget navigation) =>
                builtInDiscover
                ? Consumer(
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
                  )
                : MediaDiscoveryPage(
                    kinds: _userServerKinds,
                    navigation: navigation,
                  ),
          ),
        // 用户自己的 Kavita 服务器：配了可用的才出页签（漫画域只有 Kavita），设置里
        // 增删后随之出现 / 消失。用户服务器不受 iOS 合规门约束。
        if (mediaServers)
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.mediaServers,
            // 主滚动视图自己把浮动工具区高度加成顶部内边距。
            handlesChromeInset: true,
            label: t.library_view_media_servers,
            builder: (BuildContext context, Widget navigation) =>
                const UserMediaServersView(
                  domain: UserMediaServersDomain.manga,
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
      ],
    );
  }
}
