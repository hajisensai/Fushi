import 'package:flutter/widgets.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/pages/implementations/media_discovery_page.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/pages/implementations/media_sources_page.dart';
import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/models/store_compliance.dart';

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

  /// 书 tab 是「书架 + 浏览 + 来源」三视图（与漫画 / 视频同一套导航结构）。
  ///
  /// 书架视图仍走 `mediaSource.buildHistoryPage()`——书 tab 支持切换来源
  /// （EPUB / PDF / 通用），页面类型由当前来源决定，壳不得硬编某一个实现。
  /// 「浏览」= 统一发现页（小说 + 有声书在线源：nyaa 等，源可切换、默认全部源
  /// 聚合，下载完自动入库）。
  ///
  /// iOS 上「浏览」整个不声明（[StoreRestrictedCapability.externalDiscovery]）：
  /// 那一页的全部内容都是内置外部源，源不装配后它只剩一个空壳。省略而不是留个
  /// 空 tab，正是 [MediaLibraryViewKind] 文档说的「各域只声明自己真正有的视图」。
  @override
  Widget build(BuildContext context) {
    return MediaLibraryShell(
      focusIdPrefix: 'book-library-view',
      views: <MediaLibraryViewSpec>[
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.library,
          label: t.library_view_shelf,
          builder: (BuildContext context, Widget navigation) =>
              mediaSource.buildHistoryPage(navigation: navigation),
        ),
        if (StoreRestrictedCapability.externalDiscovery.isAvailable)
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.browse,
            label: t.library_view_browse,
            builder: (BuildContext context, Widget navigation) =>
                MediaDiscoveryPage(
              kinds: const <DiscoveryMediaKind>[
                DiscoveryMediaKind.novel,
                DiscoveryMediaKind.audiobook,
              ],
              navigation: navigation,
            ),
          ),
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.sources,
          label: t.library_view_import,
          builder: (BuildContext context, Widget navigation) =>
              MediaSourcesPage(mediaKind: 'book', navigation: navigation),
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
