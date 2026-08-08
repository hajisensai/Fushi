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
    this.onScrapeAll,
    this.onLibraryChanged,
  });

  /// 'video' | 'book' | 'manga'。
  final String mediaKind;

  /// 库页视图导航条（由 [MediaLibraryShell] 传入，作为页头主内容与动作同一行）。
  final Widget? navigation;

  /// 视频来源页专用的整库刮削动作；其它媒体种类即使误传也不会显示。
  final Future<void> Function()? onScrapeAll;

  /// 来源扫描完成后通知保活的媒体库重读合集、排序和封面。
  final VoidCallback? onLibraryChanged;

  @override
  State<MediaSourcesPage> createState() => _MediaSourcesPageState();
}

class _MediaSourcesPageState extends State<MediaSourcesPage> {
  final GlobalKey<MediaSourcesViewState> _viewKey =
      GlobalKey<MediaSourcesViewState>();

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    // 与书架 / 视频 / 词典三个库页同构：DesktopContentLayout + HibikiPageHeader
    // 大标题 + HibikiIconButton 动作，外层 Scaffold 由 HomePage 提供。
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context)) _buildHeader(),
          Expanded(
            // 正文自带内边距：readerShelf 的 desktopContentPadding 已恒为零
            // （PR#675 撤强制侧向留白），而 [MediaSourcesView] 自身只有行间的纵向
            // 间距，桌面上文字与开关会直接贴窗口边。留白取 spacing.page，与上方
            // [HibikiPageHeader] 的横向内边距同源，标题与正文左边缘对齐；滚动条仍
            // 贴真实边缘（padding 在 SingleChildScrollView 里，不在它外面）。
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
              child: MediaSourcesView(
                key: _viewKey,
                mediaKind: widget.mediaKind,
                onLibraryChanged: widget.onLibraryChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final List<Widget> actions = <Widget>[
      HibikiIconButton(
        tooltip: t.media_source_add,
        label: t.media_source_add,
        icon: Icons.create_new_folder_outlined,
        onTap: () => _viewKey.currentState?.addSource(),
      ),
      if (widget.mediaKind == 'video' && widget.onScrapeAll != null)
        HibikiIconButton(
          tooltip: t.scrape_all,
          label: t.scrape_all,
          icon: Icons.manage_search_outlined,
          onTap: () => widget.onScrapeAll!(),
        ),
    ];
    final Widget? navigation = widget.navigation;
    if (navigation != null) {
      return HibikiPageHeader.customTitle(
        title: navigation,
        actions: actions,
      );
    }
    return HibikiPageHeader(
      title: t.media_source_manage_title,
      actions: actions,
    );
  }
}
