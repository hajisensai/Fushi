import 'package:flutter/widgets.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart'
    show AiMediaAcquisitionDomain;
import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_library_view.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_ui_helpers.dart';
import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart';
import 'package:fushi/src/pages/implementations/discovery_ai_acquire_action.dart';
import 'package:fushi/src/pages/implementations/library_online_sources_view.dart';
import 'package:fushi/src/pages/implementations/media_discovery_page.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/pages/implementations/media_sources_page.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeInsetPadding;
import 'package:fushi/utils.dart';

/// The body content for the Reader tab in the main menu.
class HomeReaderPage extends BaseTabPage {
  /// Create an instance of this page.
  const HomeReaderPage({super.key});

  @override
  BaseTabPageState<HomeReaderPage> createState() => _HomeReaderPageState();
}

class _HomeReaderPageState extends BaseTabPageState<HomeReaderPage> {
  @override
  MediaType get mediaType => ReaderMediaType.instance;

  /// 书 tab：书架 / 发现 / 来源 / 扩展 / 导入，与漫画 / 视频同一套导航结构。
  ///
  /// 书架视图仍走 `mediaSource.buildHistoryPage()`——书 tab 支持切换来源
  /// （EPUB / PDF / 通用），页面类型由当前来源决定，壳不得硬编某一个实现。
  ///
  /// 发现（nyaa / OPDS 等）与小说在线源（LNReader）的来源 / 扩展同时住在顶层
  /// 「浏览」模块与这里（2026-10-01 用户拍板加回库页子标签），两处是同一组组件。
  /// 各自过 iOS 合规门 / 平台宿主门；书 tab 存在即书模块开着。
  @override
  Widget build(BuildContext context) {
    final bool online = isOnlineSourcesDomainAvailable(
      OnlineSourcesDomain.novel,
    );
    // 用户自己的 Audiobookshelf 服务器：有已启用且已登录的才出标签页。它是用户自己的
    // 服务器（同 Jellyfin / Plex），流式播放不属于 App Store 受限的「外部发现源」，
    // 所以不过 externalDiscovery 门——iOS 上也能用；下载另受下载中心的门限制。
    final List<AudiobookshelfServerConfig> absServers =
        appModel.isPreferencesReady
        ? audiobookshelfTabServers(
            appModel.prefsRepo.discoveryAudiobookshelfServers,
          )
        : const <AudiobookshelfServerConfig>[];
    return MediaLibraryShell(
      focusIdPrefix: 'book-library-view',
      views: <MediaLibraryViewSpec>[
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.library,
          label: t.library_view_shelf,
          // 书架（[ReaderFushiHistoryPage]）主滚动视图自己让出浮动工具栏的高度；
          // 其它来源的通用回退页不认识工具栏，整体下移。
          handlesChromeInset: true,
          builder: (BuildContext context, Widget navigation) {
            final Widget page =
                mediaSource.buildHistoryPage(navigation: navigation);
            return page is ReaderFushiHistoryPage
                ? page
                : FushiFloatingChromeInsetPadding(child: page);
          },
        ),
        if (StoreRestrictedCapability.externalDiscovery.isAvailable)
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.discover,
            // 发现页把自己的搜索 / 筛选行叠进浮动工具区，主滚动视图自己让位。
            handlesChromeInset: true,
            label: t.library_view_discover,
            builder: (BuildContext context, Widget navigation) =>
                MediaDiscoveryPage(
              kinds: const <DiscoveryMediaKind>[
                DiscoveryMediaKind.novel,
                DiscoveryMediaKind.audiobook,
              ],
              navigation: navigation,
              onAiAcquire: discoveryAiAcquireAction(
                context: context,
                readAppModel: () => appModelNoUpdate,
                domain: AiMediaAcquisitionDomain.novel,
                domainLabel: t.books,
                onlineDomain: OnlineSourcesDomain.novel,
              ),
            ),
          ),
        if (absServers.isNotEmpty)
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.audiobookshelf,
            // 主滚动视图自己把浮动工具区高度加成顶部内边距。
            handlesChromeInset: true,
            label: t.library_view_audiobookshelf,
            builder: (BuildContext context, Widget navigation) =>
                AudiobookshelfLibraryView(
                  servers: absServers,
                  apiFor: (AudiobookshelfServerConfig server) =>
                      appModelNoUpdate.audiobookshelfApis.apiFor(server),
                ),
          ),
        if (online)
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.onlineSources,
            // 主滚动视图自己把浮动工具区高度加成顶部内边距：工具区收起后不留空白。
            handlesChromeInset: true,
            label: t.library_view_sources,
            builder: (BuildContext context, Widget navigation) =>
                LibraryOnlineSourcesView(
              domain: OnlineSourcesDomain.novel,
              section: OnlineSourcesSection.sources,
              navigation: navigation,
            ),
          ),
        if (online)
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.extensions,
            // 主滚动视图自己把浮动工具区高度加成顶部内边距：工具区收起后不留空白。
            handlesChromeInset: true,
            label: t.media_import_segment_extensions,
            builder: (BuildContext context, Widget navigation) =>
                LibraryOnlineSourcesView(
              domain: OnlineSourcesDomain.novel,
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
              MediaSourcesPage(mediaKind: 'book', navigation: navigation),
        ),
      ],
    );
  }
}
