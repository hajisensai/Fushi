import 'package:flutter/widgets.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/pages/implementations/media_sources_page.dart';
import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/settings/settings_destination.dart';
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

  /// 书 tab 是「书架 + 导入」两视图（外加设置），与漫画 / 视频同一套导航结构。
  ///
  /// 书架视图仍走 `mediaSource.buildHistoryPage()`——书 tab 支持切换来源
  /// （EPUB / PDF / 通用），页面类型由当前来源决定，壳不得硬编某一个实现。
  ///
  /// 发现页（nyaa / OPDS 等）与小说在线源（LNReader）2026-09-27 起只住在顶层
  /// 「浏览」模块（`browse_page.dart`），库页不再挂在线入口。
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
