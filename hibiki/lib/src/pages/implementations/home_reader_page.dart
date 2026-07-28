import 'package:flutter/widgets.dart';

import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/media_library_shell.dart';
import 'package:hibiki/src/pages/implementations/media_sources_page.dart';
import 'package:hibiki/utils.dart';

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

  /// 书 tab 是「书架 + 来源」两视图（与漫画 / 视频同一套导航结构）。
  ///
  /// 书架视图仍走 `mediaSource.buildHistoryPage()`——书 tab 支持切换来源
  /// （EPUB / PDF / 通用），页面类型由当前来源决定，壳不得硬编某一个实现。
  /// 「浏览」视图暂缺：小说在线源（Kakuyomu / なろう 等）尚未落地，此处不放空壳
  /// tab——[MediaLibraryShell] 在只有一个视图时连导航条都不显示，等在线源到位
  /// 只需在这里多声明一条。
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
          label: t.library_view_sources,
          builder: (BuildContext context, Widget navigation) =>
              MediaSourcesPage(mediaKind: 'book', navigation: navigation),
        ),
      ],
    );
  }
}
