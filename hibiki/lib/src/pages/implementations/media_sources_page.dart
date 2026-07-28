import 'package:flutter/material.dart';

import 'package:hibiki/src/pages/implementations/media_sources_view.dart';
import 'package:hibiki/utils.dart';

/// 库页三视图里的「来源」视图：本地扫描根 + 网络来源的管理页。
///
/// 与 [MediaSourcesDialog] 共用同一个内容体 [MediaSourcesView]，差别只在 chrome：
/// 对话框把「添加来源」放页脚，页面把它放页头动作区（与书架的导入按钮同位）。
class MediaSourcesPage extends StatefulWidget {
  const MediaSourcesPage({
    required this.mediaKind,
    super.key,
    this.navigation,
  });

  /// 'video' | 'book' | 'manga'。
  final String mediaKind;

  /// 库页视图导航条（由 [MediaLibraryShell] 传入，落在页头 bottom 槽）。
  final Widget? navigation;

  @override
  State<MediaSourcesPage> createState() => _MediaSourcesPageState();
}

class _MediaSourcesPageState extends State<MediaSourcesPage> {
  final GlobalKey<MediaSourcesViewState> _viewKey =
      GlobalKey<MediaSourcesViewState>();

  @override
  Widget build(BuildContext context) {
    // 与书架 / 视频 / 词典三个库页同构：DesktopContentLayout + HibikiPageHeader
    // 大标题 + HibikiIconButton 动作，外层 Scaffold 由 HomePage 提供。
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context))
            HibikiPageHeader(
              title: t.media_source_manage_title,
              actions: <Widget>[
                HibikiIconButton(
                  tooltip: t.media_source_add,
                  label: t.media_source_add,
                  icon: Icons.create_new_folder_outlined,
                  onTap: () => _viewKey.currentState?.addSource(),
                ),
              ],
              bottom: widget.navigation,
            ),
          Expanded(
            child: MediaSourcesView(
              key: _viewKey,
              mediaKind: widget.mediaKind,
              scrollable: true,
            ),
          ),
        ],
      ),
    );
  }
}
