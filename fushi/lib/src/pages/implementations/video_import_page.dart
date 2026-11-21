/// 视频库「导入」视图（导入稿 v2「3. 视频」）：本域内容入库的唯一入口页，套
/// 共用的 [ImportCollagePage]（引导首块 + 方式块 + 常驻来源色块区）。
///
/// - 方式按规范顺序：导入视频 → 导入文件夹 → IPTV 频道列表 → 网络共享（R8）；
///   网络说明从 [importNetworkTransportsSummary] 派生（BUG-4858 / IM10）；
/// - 整页收拖放（BUG-4857 / IM2）：落下交给视频库页现有的分发
///   （[VideoLibraryDropPort]，`HomeVideoPage._handleVideoDrop`），不另写一份；
/// - 刮削三件套（整库刮削 / 后台任务 / 清空刮削记录）登记进库页壳浮动顶栏
///   （IM18）：Material 平铺前两项、「清空刮削记录」收进 ⋯；Apple 形态三项都在
///   大标题行的 ⋯ 里。此前它们画在 Cupertino 不渲染的页头里，iOS 上看不到。
/// - 来源区是 [MediaSourcesView] 的色块呈现：视频来源块的刮削进度与可点刮削
///   摘要（BUG-1720）、「导入文件夹」里的音频 CD 抓轨（BUG-3312）都在它里面，
///   本页只接线。
library;

import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart'
    show kDragPlaylistExtensions;
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart'
    show FileDropCallback;
import 'package:fushi/src/media/import/import_collage_page.dart';
import 'package:fushi/src/media/import/import_inbox.dart';
import 'package:fushi/src/media/import/import_inbox_text.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/media/video/iptv_playlist_import_dialog.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_header_more_button.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_engine/media/media_extensions.dart' show kVideoExtensions;
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

/// 视频「导入文件夹」块的音频 CD 附注只在能抓轨的桌面出现（与
/// `audio_cd_import.dart` 的 `_canRip` 一致：Windows 光驱 / macOS 挂载点）。
bool get videoImportFolderShowsAudioCdNote =>
    Platform.isWindows || Platform.isMacOS;

/// 视频导入面的 spec（纯数据装配，便于单测）。
ImportSurfaceSpec buildVideoImportSpec({
  required Future<void> Function() onImportVideo,
  required Future<void> Function() onImportFolder,
  required Future<void> Function() onImportIptv,
  required Future<void> Function() onAddNetworkSource,
  required bool busy,
  required bool showAudioCdNote,
  Future<void> Function()? onImportFromInbox,
  FileDropCallback? onDrop,
}) => ImportSurfaceSpec(
  id: 'video',
  tone: ImportTone.cyan,
  guideIcon: FushiIcons.video,
  guideTitle: t.import_guide_video_title,
  guideDescription: t.import_guide_video_desc,
  guideDescriptionWithoutDrop: t.import_guide_video_desc_no_drop,
  methods: <ImportMethod>[
    ImportMethod(
      id: 'video',
      kind: ImportMethodKind.primary,
      icon: FushiIcons.video,
      label: t.video_import_action,
      description: t.import_method_video_desc,
      destination: ImportDestination.dialog,
      onTap: onImportVideo,
    ),
    ImportMethod(
      id: 'folder',
      kind: ImportMethodKind.folder,
      icon: FushiIcons.folder,
      label: t.media_import_folder,
      description: t.import_method_folder_desc,
      note: showAudioCdNote ? t.import_method_video_cd_note : null,
      destination: ImportDestination.choice,
      enabled: !busy,
      onTap: onImportFolder,
    ),
    // iOS「文件」App 收件箱（拍板台 nLXhu0d7gV）：调用方只在有收件箱的平台传入口。
    if (onImportFromInbox != null)
      ImportMethod(
        id: 'inbox',
        kind: ImportMethodKind.folder,
        icon: FushiIcons.folderOpen,
        label: t.media_import_inbox,
        description: importInboxHintText(
          folder: ImportInbox.folderNameFor('video') ?? '',
        ),
        destination: ImportDestination.dialog,
        enabled: !busy,
        onTap: onImportFromInbox,
      ),
    ImportMethod(
      id: 'iptv',
      kind: ImportMethodKind.iptv,
      icon: FushiIcons.tv,
      label: t.video_iptv_import_action,
      description: t.import_method_iptv_desc,
      destination: ImportDestination.dialog,
      onTap: onImportIptv,
    ),
    ImportMethod(
      id: 'network',
      kind: ImportMethodKind.network,
      icon: FushiIcons.cloud,
      label: t.media_source_add_network,
      description: t.import_method_video_network_desc(
        transports: importNetworkTransportsSummary('video'),
      ),
      destination: ImportDestination.source,
      enabled: !busy,
      onTap: onAddNetworkSource,
    ),
  ],
  // 视频库收录的视频（纯音频归音乐库，反馈 QAondMh4M5）、M3U 播放列表，以及
  // 网络串流地址（协议名不翻译）。
  formatGroups: <ImportFormatGroup>[
    ImportFormatGroup(
      title: t.import_format_group_video,
      labels: importFormatLabels(<Iterable<String>>[kVideoExtensions]),
    ),
    ImportFormatGroup(
      title: t.import_format_group_playlist,
      labels: importFormatLabels(<Iterable<String>>[kDragPlaylistExtensions]),
    ),
    ImportFormatGroup(
      title: t.import_format_group_stream,
      labels: const <String>['HTTP'],
    ),
  ],
  onDrop: onDrop,
);

class VideoImportPage extends ConsumerStatefulWidget {
  const VideoImportPage({
    super.key,
    this.navigation,
    this.onScrapeAll,
    this.onClearAllScrapeRecords,
    this.onScrapeSource,
    this.onVideoScanCompleted,
    this.scrapeTaskController,
    this.onOpenScrapeTasks,
    this.onLibraryChanged,
    this.onDrop,
  });

  /// 壳给的页头主位（零尺寸占位：页签由壳的浮动顶栏画）；null = 独立使用。
  final Widget? navigation;

  /// 整库刮削。
  final Future<void> Function()? onScrapeAll;

  /// 清空全部刮削记录（危险操作，收进 ⋯）。
  final Future<void> Function()? onClearAllScrapeRecords;

  /// 单个视频来源的刮削入口（来源块上）。
  final Future<void> Function(SourceLibraryRow source)? onScrapeSource;

  /// 视频来源扫描完成后上报摘要；是否继续自动刮削由上层决定。
  final Future<void> Function(
    SourceLibraryRow source,
    SourceScanSummary summary,
  )?
  onVideoScanCompleted;

  /// 应用生命周期级刮削任务：来源块显示进度、防止重入。
  final VideoSourceScrapeTaskController? scrapeTaskController;

  /// 后台刮削任务面板；有任务在跑时也必须可进入查看或取消。
  final VoidCallback? onOpenScrapeTasks;

  /// 导入 / 扫描收尾后通知保活的视频库重读。
  final VoidCallback? onLibraryChanged;

  /// 整页落点（BUG-4857）：壳经 [VideoLibraryDropPort.drop] 转交库页分发；
  /// null = 不收拖放（不画虚线、不进拖放态）。
  final FileDropCallback? onDrop;

  @override
  ConsumerState<VideoImportPage> createState() => _VideoImportPageState();
}

class _VideoImportPageState extends ConsumerState<VideoImportPage> {
  final GlobalKey<MediaSourcesViewState> _viewKey =
      GlobalKey<MediaSourcesViewState>();

  /// BUG-513 同款纪律：AppModel 在 initState 捕获，async gap 之后不再 `ref.read`。
  late final AppModel _appModel = ref.read(appProvider);
  bool _clearingScrapeRecords = false;

  @override
  void initState() {
    super.initState();
    widget.scrapeTaskController?.addListener(_taskChanged);
  }

  @override
  void didUpdateWidget(covariant VideoImportPage oldWidget) {
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

  bool get _busy =>
      _clearingScrapeRecords ||
      widget.scrapeTaskController?.isBusy == true ||
      _viewKey.currentState?.isBusy == true;

  Future<void> _clearAllScrapeRecords() async {
    final Future<void> Function()? clear = widget.onClearAllScrapeRecords;
    if (clear == null || _busy) return;
    setState(() => _clearingScrapeRecords = true);
    try {
      await clear();
    } finally {
      if (mounted) setState(() => _clearingScrapeRecords = false);
    }
  }

  /// 单个视频 / 网络流导入（[VideoImportDialog] 只管单件：文件 / 链接）。
  Future<void> _importVideo() async {
    final String? bookUid = await showAppDialog<String>(
      context: context,
      builder: (_) =>
          VideoImportDialog(repo: VideoBookRepository(_appModel.database)),
    );
    if (bookUid != null && mounted) widget.onLibraryChanged?.call();
  }

  /// 「导入文件夹」：二选一（设为常驻来源 / 仅导入这一次），对话框、分发与
  /// 音频 CD 识别都在 [MediaSourcesViewState.importFolder]。
  Future<void> _importFolder() async {
    await _viewKey.currentState?.importFolder();
    if (mounted) widget.onLibraryChanged?.call();
  }

  /// 「从『文件』App 导入」：收 `我的 iPhone › Fushi › 视频子目录` 里的文件（重入保护在
  /// [MediaSourcesViewState.importFromInbox] 入口）。
  Future<void> _importFromInbox() async {
    await _viewKey.currentState?.importFromInbox();
    if (mounted) widget.onLibraryChanged?.call();
  }

  /// 整页落点（BUG-4857）：交给库页分发；拖入文件夹会登记常驻来源，端口等到
  /// 落库扫描完才返回，之后重读本页的来源色块（否则新来源要切走再回来才出现）。
  Future<void> _drop(List<String> paths, Offset globalPosition) async {
    final FileDropCallback? onDrop = widget.onDrop;
    if (onDrop == null) return;
    await onDrop(paths, globalPosition);
    if (!mounted) return;
    await _viewKey.currentState?.reload();
  }

  /// 「网络共享」：直接打开网络来源表单（传输集按域收窄）。
  Future<void> _addNetworkSource() async {
    await _viewKey.currentState?.addNetworkSource();
  }

  /// M3U / IPTV 频道列表导入。填进来的若其实是一条 HLS 流，转交
  /// [VideoImportDialog] 按单个视频 / 流链接导入。
  Future<void> _importIptvPlaylist() async {
    final VideoBookRepository repo = VideoBookRepository(_appModel.database);
    final IptvPlaylistImportOutcome? outcome =
        await showAppDialog<IptvPlaylistImportOutcome>(
          context: context,
          builder: (_) => IptvPlaylistImportDialog(repo: repo),
        );
    if (!mounted || outcome == null) return;
    switch (outcome) {
      case IptvPlaylistImported():
        widget.onLibraryChanged?.call();
      case IptvPlaylistIsHlsStream(
        :final String? url,
        :final String? localPath,
      ):
        final String? bookUid = await showAppDialog<String>(
          context: context,
          builder: (_) => VideoImportDialog(
            repo: repo,
            initialStreamUrl: url,
            initialVideoPath: localPath,
          ),
        );
        if (bookUid != null && mounted) widget.onLibraryChanged?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool busy = _busy;
    final ImportSurfaceSpec spec = buildVideoImportSpec(
      onImportVideo: _importVideo,
      onImportFolder: _importFolder,
      onImportIptv: _importIptvPlaylist,
      onAddNetworkSource: _addNetworkSource,
      busy: busy,
      showAudioCdNote: videoImportFolderShowsAudioCdNote,
      onImportFromInbox: ImportInbox.isSupported ? _importFromInbox : null,
      onDrop: widget.onDrop == null ? null : _drop,
    );
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          // 两套设计系统都建页头：在库页壳里它是零尺寸占位、只把动作登记进壳的
          // 浮动顶栏（IM18：此前 Cupertino 下整个页头不建，iOS 看不到刮削入口）。
          _buildHeader(busy),
          Expanded(
            child: ImportCollagePage(
              spec: spec,
              onAddSource: () {
                if (!_busy) unawaited(_viewKey.currentState?.addSource());
              },
              addSourceEnabled: !busy,
              sources: MediaSourcesView(
                key: _viewKey,
                mediaKind: 'video',
                presentation: MediaSourcesPresentation.blocks,
                entranceIndexOffset: spec.sourceEntranceIndex,
                onScrapeSource: widget.onScrapeSource,
                onVideoScanCompleted: widget.onVideoScanCompleted,
                scrapeTaskController: widget.scrapeTaskController,
                onLibraryChanged: widget.onLibraryChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 刮削三件套（IM18）。Material：平铺「整库刮削」「后台任务」，「清空刮削
  /// 记录」进 ⋯（放不下时浮动顶栏自适应收纳再收）；Apple：三项都进大标题行的 ⋯。
  Widget _buildHeader(bool busy) {
    final Future<void> Function()? scrapeAll = widget.onScrapeAll;
    final VoidCallback? openTasks = widget.onOpenScrapeTasks;
    final bool canClear = widget.onClearAllScrapeRecords != null;
    final IconData tasksIcon = widget.scrapeTaskController?.isBusy == true
        ? FushiIcons.sync
        : FushiIcons.pending;
    final FushiHeaderMoreEntry scrapeAllEntry = FushiHeaderMoreEntry(
      key: const ValueKey<String>('video-import-scrape-all-item'),
      icon: FushiIcons.manageSearch,
      label: t.scrape_all,
      enabled: !busy,
      onSelected: () async {
        if (!_busy) await scrapeAll!();
      },
    );
    final FushiHeaderMoreEntry tasksEntry = FushiHeaderMoreEntry(
      key: const ValueKey<String>('video-import-scrape-tasks-item'),
      icon: tasksIcon,
      label: t.video_source_scrape_tasks_open,
      onSelected: () => openTasks!(),
    );
    final FushiHeaderMoreEntry clearEntry = FushiHeaderMoreEntry(
      key: const ValueKey<String>('video-import-scrape-clear-all-item'),
      icon: FushiIcons.deleteSweep,
      label: t.video_source_scrape_clear_all,
      enabled: !busy,
      onSelected: _clearAllScrapeRecords,
    );
    final bool apple = isCupertinoPlatform(context);
    final List<FushiHeaderMoreEntry> moreEntries = <FushiHeaderMoreEntry>[
      if (apple && scrapeAll != null) scrapeAllEntry,
      if (apple && openTasks != null) tasksEntry,
      if (canClear) clearEntry,
    ];
    final List<Widget> actions = <Widget>[
      if (!apple && scrapeAll != null)
        FushiIconButton(
          key: const ValueKey<String>('video-import-scrape-all'),
          tooltip: t.scrape_all,
          label: t.scrape_all,
          icon: FushiIcons.manageSearch,
          enabled: !busy,
          onTap: () {
            if (!_busy) unawaited(scrapeAll());
          },
        ),
      if (!apple && openTasks != null)
        FushiIconButton(
          key: const ValueKey<String>('video-import-scrape-tasks'),
          tooltip: t.video_source_scrape_tasks_open,
          label: t.video_source_scrape_tasks_open,
          icon: tasksIcon,
          onTap: openTasks,
        ),
      if (moreEntries.isNotEmpty)
        FushiHeaderMoreButton(
          key: const ValueKey<String>('video-import-more-anchor'),
          buttonKey: const ValueKey<String>('video-import-more'),
          entries: moreEntries,
        ),
    ];
    final Widget? navigation = widget.navigation;
    if (navigation != null) {
      return FushiPageHeader.customTitle(title: navigation, actions: actions);
    }
    return FushiPageHeader(
      title: t.media_source_manage_title,
      actions: actions,
    );
  }
}
