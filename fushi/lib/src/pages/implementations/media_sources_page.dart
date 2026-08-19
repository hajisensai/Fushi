import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/media/import/quick_import_section.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi/utils.dart';

/// 库页导航壳里的「导入」视图：**本域内容入库的唯一入口页**。
///
/// 自上而下两区：
/// 1. 快速导入（[QuickImportSection]）——单件 / 一次性入口：书 / 视频统一为
///    「导入单件 + 导入文件夹」两个按钮（文件夹二选一：设为常驻来源 / 仅导入
///    一次，见 [MediaSourcesViewState.importFolder]）。
/// 2. 常驻来源（[MediaSourcesView]）——本地与网络扫描根的管理列表，区头带
///    「添加来源」按钮（TODO-2930 从页头收敛至此）。
///
/// 此前单件导入按钮散在各库页页头（书 / 漫画在页头、视频已删、游戏在 FAB），
/// 五个模块五种入口；现在统一收敛到「导入」视图同一位置（2026-08-13 用户定案）。
/// 与 [MediaSourcesDialog] 共用同一个来源列表内容体 [MediaSourcesView]，对话框
/// 语境（旧兼容路径）不带快速导入区、逐像素不变。
class MediaSourcesPage extends ConsumerStatefulWidget {
  const MediaSourcesPage({
    required this.mediaKind,
    super.key,
    this.navigation,
    this.onScrapeAll,
    this.onScrapeSource,
    this.onVideoScanCompleted,
    this.scrapeTaskController,
    this.onOpenScrapeTasks,
    this.onLibraryChanged,
  });

  /// 'video' | 'book' | 'manga'。
  final String mediaKind;

  /// 库页视图导航条（由 [MediaLibraryShell] 传入，作为页头主内容与动作同一行）。
  final Widget? navigation;

  /// 视频来源页专用的整库刮削动作；其它媒体种类即使误传也不会显示。
  final Future<void> Function()? onScrapeAll;

  /// 单个视频来源的刮削入口。
  final Future<void> Function(SourceLibraryRow source)? onScrapeSource;

  /// 视频来源扫描完成后上报摘要；是否继续自动刮削由上层决定。
  final Future<void> Function(
    SourceLibraryRow source,
    SourceScanSummary summary,
  )? onVideoScanCompleted;

  /// 应用生命周期级刮削任务，来源行用它显示进度并防止重入。
  final VideoSourceScrapeTaskController? scrapeTaskController;

  /// 视频后台刮削任务面板；即使当前有任务运行也必须可进入查看或取消。
  final VoidCallback? onOpenScrapeTasks;

  /// 来源扫描 / 快速导入完成后通知保活的媒体库重读合集、排序和封面。
  final VoidCallback? onLibraryChanged;

  @override
  ConsumerState<MediaSourcesPage> createState() => _MediaSourcesPageState();
}

class _MediaSourcesPageState extends ConsumerState<MediaSourcesPage> {
  final GlobalKey<MediaSourcesViewState> _viewKey =
      GlobalKey<MediaSourcesViewState>();

  /// BUG-513 同款纪律：AppModel 在 initState 捕获，async gap 之后不再 `ref.read`。
  late final AppModel _appModel = ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    widget.scrapeTaskController?.addListener(_taskChanged);
  }

  @override
  void didUpdateWidget(covariant MediaSourcesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrapeTaskController == widget.scrapeTaskController) return;
    oldWidget.scrapeTaskController?.removeListener(_taskChanged);
    widget.scrapeTaskController?.addListener(_taskChanged);
  }

  @override
  void dispose() {
    widget.scrapeTaskController?.removeListener(_taskChanged);
    super.dispose();
  }

  void _taskChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<QuickImportAction> quickActions = _quickImportActions();
    // 与书架 / 视频 / 词典三个库页同构：DesktopContentLayout + FushiPageHeader
    // 大标题 + FushiIconButton 动作，外层 Scaffold 由 HomePage 提供。
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context)) _buildHeader(),
          Expanded(
            // 正文自带内边距：readerShelf 的 desktopContentPadding 已恒为零
            // （PR#675 撤强制侧向留白），而 [MediaSourcesView] 自身只有行间的纵向
            // 间距，桌面上文字与开关会直接贴窗口边。留白取 spacing.page，与上方
            // [FushiPageHeader] 的横向内边距同源，标题与正文左边缘对齐；滚动条仍
            // 贴真实边缘（padding 在 SingleChildScrollView 里，不在它外面）。
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (quickActions.isNotEmpty) ...<Widget>[
                    QuickImportSection(actions: quickActions),
                    const SizedBox(height: 28),
                  ],
                  _buildSourcesSectionHeader(),
                  const SizedBox(height: 8),
                  MediaSourcesView(
                    key: _viewKey,
                    mediaKind: widget.mediaKind,
                    onScrapeSource: widget.onScrapeSource,
                    onVideoScanCompleted: widget.onVideoScanCompleted,
                    scrapeTaskController: widget.scrapeTaskController,
                    onLibraryChanged: widget.onLibraryChanged,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 本域的快速导入入口（各域只声明真正有的入口）。
  ///
  /// 'manga' 走 [MangaSourcesPage] 自己的快速导入区，不经过本页；对话框语境
  /// （[MediaSourcesDialog]）直接用 [MediaSourcesView]，也不经过本页。
  List<QuickImportAction> _quickImportActions() {
    return switch (widget.mediaKind) {
      'book' => <QuickImportAction>[
          QuickImportAction(
            icon: Icons.upload_file_outlined,
            label: t.srt_import,
            onTap: _importBookFile,
          ),
          QuickImportAction(
            icon: Icons.drive_folder_upload_outlined,
            label: t.media_import_folder,
            onTap: _importFolder,
          ),
        ],
      'video' => <QuickImportAction>[
          QuickImportAction(
            icon: Icons.movie_outlined,
            label: t.video_import_action,
            onTap: _importVideo,
          ),
          QuickImportAction(
            icon: Icons.drive_folder_upload_outlined,
            label: t.media_import_folder,
            onTap: _importFolder,
          ),
        ],
      _ => const <QuickImportAction>[],
    };
  }

  /// 单本书导入：与旧书架页头按钮同一个对话框（EPUB/PDF/文本/字幕/有声书对齐）。
  Future<void> _importBookFile() async {
    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => BookImportDialog(
        repo: SrtBookRepository(_appModel.database),
        audiobookRepo: AudiobookRepository(_appModel.database),
        db: _appModel.database,
      ),
    );
    if (imported == true) _invalidateBookProviders();
  }

  /// 「导入文件夹」：二选一——设为常驻来源（Komga 式，长期自动扫描）或
  /// 仅导入这一次（同一条扫描管线，扫完不留扫描根）。对话框与分发在
  /// [MediaSourcesViewState.importFolder]，书 / 视频 / 漫画三个导入视图共用。
  Future<void> _importFolder() async {
    await _viewKey.currentState?.importFolder();
    if (!mounted) return;
    if (widget.mediaKind == 'book') {
      _invalidateBookProviders();
    } else {
      widget.onLibraryChanged?.call();
    }
  }

  /// 单个视频 / 网络流导入：复用 [VideoImportDialog]（原页头入口迁到来源视图后
  /// 的唯一常规入口；对话框只管单件——文件 / 链接，文件夹与 m3u8 建合集入口已删，
  /// 文件夹导入统一走 [_importFolder] 的常驻来源 / 仅导入一次二选一）。
  Future<void> _importVideo() async {
    final String? bookUid = await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(
        repo: VideoBookRepository(_appModel.database),
      ),
    );
    if (bookUid != null && mounted) widget.onLibraryChanged?.call();
  }

  /// 书架 provider 失效（快速导入落库后书架 / 漫画库立即刷新）。
  void _invalidateBookProviders() {
    if (!mounted) return;
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    ref.invalidate(srtBooksProvider);
    widget.onLibraryChanged?.call();
  }

  /// 「常驻来源」区头：标题 + 区块内「添加来源」按钮。
  ///
  /// 原页头的「添加来源」收敛到此（TODO-2930 用户反馈：页头按钮与页内来源区
  /// 割裂）；Cupertino 布局本就不渲染页头，这里也顺带补上了 iOS 的添加入口。
  Widget _buildSourcesSectionHeader() {
    final bool busy = widget.scrapeTaskController?.isBusy == true ||
        _viewKey.currentState?.isBusy == true;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            t.media_source_section_title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        FushiIconButton(
          tooltip: t.media_source_add,
          label: t.media_source_add,
          icon: Icons.create_new_folder_outlined,
          enabled: !busy,
          onTap: () {
            if (!busy) unawaited(_viewKey.currentState?.addSource());
          },
        ),
      ],
    );
  }

  Widget _buildHeader() {
    final bool busy = widget.scrapeTaskController?.isBusy == true ||
        _viewKey.currentState?.isBusy == true;
    final List<Widget> actions = <Widget>[
      if (widget.mediaKind == 'video' && widget.onScrapeAll != null)
        FushiIconButton(
          tooltip: t.scrape_all,
          label: t.scrape_all,
          icon: Icons.manage_search_outlined,
          enabled: !busy,
          onTap: () {
            if (!busy) unawaited(widget.onScrapeAll!());
          },
        ),
      if (widget.mediaKind == 'video' && widget.onOpenScrapeTasks != null)
        FushiIconButton(
          tooltip: t.video_source_scrape_tasks_open,
          label: t.video_source_scrape_tasks_open,
          icon: widget.scrapeTaskController?.isBusy == true
              ? Icons.sync
              : Icons.pending_actions_outlined,
          onTap: widget.onOpenScrapeTasks,
        ),
    ];
    final Widget? navigation = widget.navigation;
    if (navigation != null) {
      return FushiPageHeader.customTitle(
        title: navigation,
        actions: actions,
      );
    }
    return FushiPageHeader(
      title: t.media_source_manage_title,
      actions: actions,
    );
  }
}
