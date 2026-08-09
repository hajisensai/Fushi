// TODO-817 M1c / TODO-1274 来源库管理视图：列出某媒体种类（'video' | 'book' |
// 'manga'）的来源库，支持添加本地文件夹、添加网络来源（SFTP/FTP/WebDAV，仅 'book'）、
// 重新扫描、打开文件夹（仅 Windows 本地）、移除来源、拖拽重排。
//
// 本文件是**内容体**，两处消费：
// - [MediaSourcesDialog]（`media_sources_dialog.dart`）——旧的对话框入口，逐像素不变；
// - [MediaSourcesPage]（`media_sources_page.dart`）——库页三视图导航里的「来源」视图。
// 提取的动因：来源管理从「藏在页头按钮后的对话框」升级为库页一等视图后，两种语境
// 必须共用同一份行为，否则两份实现必然漂开（本仓在书架/视频页各写一份的教训）。
//
// 🔴 凭据红线（TODO-1274）：网络来源的连接参数（host/port/username/useTls）落
// MediaSources.configJson；密码/私钥经 SourceLibraryCredentialStore 以 base64 单独落
// Preferences（键 `media_source_secret_<id>`），绝不进入 configJson。
//
// 网络来源只对 'book' 开放：EPUB 小体积、扫描时下载后导入；远端 SFTP/FTP/WebDAV 视频
// 路径不可被播放器直接播放，故 'video' 只保留本地来源。漫画同理只支持本地（卷体积大且
// 导入要解包，远端流式扫描无意义）。WebDAV 的 rootPath 即完整集合 URL（scheme/host/
// 端口/路径都在里面），无需单独存 host/port（见 NetworkSourceFileSystem）。

import 'dart:async' show unawaited;
import 'dart:io' show Platform, Process;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/source_library/source_library_credential_store.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/src/sync/ftp_sync_backend.dart';
import 'package:fushi/src/sync/sftp_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/webdav_sync_backend.dart';
import 'package:fushi/src/pages/fushi_page_placeholders.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';

/// 来源库列表内容体：按 [mediaKind] 过滤，提供添加 / 重新扫描 / 打开 / 移除 / 重排。
///
/// 「添加来源」按钮**不在**本视图里——它由外层提供（对话框放页脚、页面放页头动作），
/// 经 `GlobalKey<MediaSourcesViewState>` 调 [MediaSourcesViewState.addSource]。这样
/// 两种语境各自遵守自己的 chrome 约定，而行为只有一份。
class MediaSourcesView extends ConsumerStatefulWidget {
  const MediaSourcesView({
    required this.mediaKind,
    super.key,
    this.scrollable = false,
    this.onScrapeSource,
    this.onVideoScanCompleted,
    this.scrapeTaskController,
    this.onLibraryChanged,
  });

  /// 'video' | 'book' | 'manga' —— 决定统计文案与 mediaKind 过滤。
  final String mediaKind;

  /// true = 自带纵向滚动（页面语境，外层给的是 Expanded 无界高度）；
  /// false = 返回裸内容（对话框语境，由外层 ConstrainedBox + SingleChildScrollView
  /// 限高并滚动，保持 BUG-445 / TODO-1389 的既有修法不变）。
  final bool scrollable;

  /// 单个视频来源的刮削动作。书籍/漫画行永远不渲染该入口。
  final Future<void> Function(SourceLibraryRow source)? onScrapeSource;

  /// 视频扫描完成摘要。上层在此根据来源设置决定是否自动刮削。
  final Future<void> Function(
    SourceLibraryRow source,
    SourceScanSummary summary,
  )? onVideoScanCompleted;

  /// 与页面生命周期解耦的刮削任务控制器，仅用于忙状态和进度。
  final VideoSourceScrapeTaskController? scrapeTaskController;

  /// 一次来源扫描收尾后的媒体库变化通知（无论扫描成功、部分成功或记录错误）。
  final VoidCallback? onLibraryChanged;

  @override
  ConsumerState<MediaSourcesView> createState() => MediaSourcesViewState();
}

class MediaSourcesViewState extends ConsumerState<MediaSourcesView>
    with FushiPagePlaceholders<MediaSourcesView> {
  /// null = 仍在加载；非 null = 已加载（可能为空列表）。
  List<SourceLibraryRow>? _rows;

  /// Fushi 互联不是 `media_sources` 扫描根，但它确实是**本机之外的同一批本地
  /// 文件**（局域网里另一台自己的设备），所以与扫描根同列。
  ///
  /// 🔴 别再往这里加「网站」型来源（BUG-1431）：mokuro.moe 曾挂在这一节，用户口径
  /// 是它不该跟扫描根混在一起。在线漫画源统一归 `MangaSourcesPage` 的「漫画源」
  /// 一节（`MokuroMoeSourceRow`），与扩展提供的源同级。
  bool? _interconnectEnabled;

  /// 每个来源 id → 当前**累计拥有**的媒体条目数（TODO-1036）。
  /// 与列表一起加载，避免逐行 FutureBuilder 抖动。来源不在 map 里时回退 0。
  final Map<int, int> _cumulativeCount = <int, int>{};

  /// 每个视频来源最近一次持久化的刮削记录。
  final Map<int, VideoSourceScrapeRunRow> _latestScrapeRuns =
      <int, VideoSourceScrapeRunRow>{};

  /// 正在扫描中的来源 id 集合（行级 loading）。
  final Set<int> _scanning = <int>{};

  /// 由行按钮启动、但任务控制器尚未发布首个进度的来源。
  final Set<int> _scraping = <int>{};

  VideoSourceScrapePhase _lastObservedScrapePhase = VideoSourceScrapePhase.idle;

  /// 数据库引用在 initState（ProviderScope 必然存活）时捕获一次，之后所有 async
  /// 操作都用它，绝不在 async gap 恢复后再 `ref.read`。否则用户点「重新扫描」后关闭
  /// 对话框，扫描完成的 finally 里若再 `ref.read(appProvider)`，此 State 的
  /// ConsumerStatefulElement 已 dispose、ProviderScope 已销毁，
  /// `containerOf` 抛 `Bad state: No ProviderScope found`（BUG-513）。
  late final FushiDatabase _db;

  /// 同 [_db]：`AppModel` 也在 initState 捕获。`_addLocalFolder` 要把它交给
  /// `pickRealDirectoryPath`（安卓那条腿用它申请全文件访问），而系统目录选择器是一段
  /// **很长的 async gap**——用户完全可能在选择器开着时把对话框关掉。捕获成字段后此处
  /// 不再出现任何 `ref.*`，BUG-513 的不变量（ref 只在 initState）继续成立。
  late final AppModel _appModel;

  /// 网络来源仅对 'book' 开放（见文件头说明）。
  bool get _networkSupported => widget.mediaKind == 'book';

  /// 页面页头与所有行级 mutation 共用的忙状态。
  bool get isBusy =>
      _scanning.isNotEmpty ||
      _scraping.isNotEmpty ||
      (widget.mediaKind == 'video' &&
          widget.scrapeTaskController?.isBusy == true);

  @override
  void initState() {
    super.initState();
    _appModel = ref.read(appProvider);
    _db = _appModel.database;
    widget.scrapeTaskController?.addListener(_onScrapeTaskChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant MediaSourcesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrapeTaskController == widget.scrapeTaskController) return;
    oldWidget.scrapeTaskController?.removeListener(_onScrapeTaskChanged);
    widget.scrapeTaskController?.addListener(_onScrapeTaskChanged);
  }

  @override
  void dispose() {
    widget.scrapeTaskController?.removeListener(_onScrapeTaskChanged);
    super.dispose();
  }

  Future<void> _load() async {
    final List<SourceLibraryRow> rows =
        await _db.getMediaSourcesByKind(widget.mediaKind);
    final bool interconnectEnabled =
        await SyncRepository(_db).isInterconnectEnabled();
    final Map<int, int> counts = await _loadCumulativeCounts(rows);
    final Map<int, VideoSourceScrapeRunRow> latestRuns =
        await _loadLatestScrapeRuns(rows);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _interconnectEnabled = interconnectEnabled;
      _cumulativeCount
        ..clear()
        ..addAll(counts);
      _latestScrapeRuns
        ..clear()
        ..addAll(latestRuns);
    });
  }

  Future<Map<int, VideoSourceScrapeRunRow>> _loadLatestScrapeRuns(
    List<SourceLibraryRow> rows,
  ) async {
    if (widget.mediaKind != 'video') {
      return const <int, VideoSourceScrapeRunRow>{};
    }
    final Map<int, VideoSourceScrapeRunRow> result =
        <int, VideoSourceScrapeRunRow>{};
    for (final SourceLibraryRow row in rows) {
      final List<VideoSourceScrapeRunRow> runs =
          await _db.getVideoSourceScrapeRuns(sourceId: row.id, limit: 1);
      if (runs.isNotEmpty) result[row.id] = runs.first;
    }
    return result;
  }

  Future<void> _refreshLatestScrapeRun(int sourceId) async {
    final List<VideoSourceScrapeRunRow> runs =
        await _db.getVideoSourceScrapeRuns(sourceId: sourceId, limit: 1);
    if (!mounted) return;
    setState(() {
      if (runs.isEmpty) {
        _latestScrapeRuns.remove(sourceId);
      } else {
        _latestScrapeRuns[sourceId] = runs.first;
      }
    });
  }

  void _onScrapeTaskChanged() {
    if (!mounted) return;
    final VideoSourceScrapeProgress progress =
        widget.scrapeTaskController?.progress ??
            const VideoSourceScrapeProgress();
    final VideoSourceScrapePhase previous = _lastObservedScrapePhase;
    _lastObservedScrapePhase = progress.phase;
    setState(() {});
    if (previous == progress.phase || progress.isRunning) return;
    final Iterable<int> sourceIds = progress.report?.sourceIds ??
        (progress.sourceId == null ? const <int>[] : <int>[progress.sourceId!]);
    for (final int sourceId in sourceIds) {
      unawaited(_refreshLatestScrapeRun(sourceId));
    }
  }

  /// 一次性查出每个来源累计拥有的媒体条目数（按 mediaKind 选表）。
  Future<Map<int, int>> _loadCumulativeCounts(
    List<SourceLibraryRow> rows,
  ) async {
    final Map<int, int> counts = <int, int>{};
    for (final SourceLibraryRow row in rows) {
      counts[row.id] = await _db.countMediaBySourceId(row.id, widget.mediaKind);
    }
    return counts;
  }

  /// 重读单个来源的累计计数（重新扫描后刷新该行用）。
  Future<void> _refreshCount(int sourceId) async {
    final int count =
        await _db.countMediaBySourceId(sourceId, widget.mediaKind);
    if (!mounted) return;
    setState(() => _cumulativeCount[sourceId] = count);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget body = _buildBody(tokens);
    return widget.scrollable ? SingleChildScrollView(child: body) : body;
  }

  Widget _buildBody(FushiDesignTokens tokens) {
    final List<SourceLibraryRow>? rows = _rows;
    final bool? interconnectEnabled = _interconnectEnabled;
    if (rows == null || interconnectEnabled == null) {
      return buildLoading(padding: const EdgeInsets.all(24));
    }
    final List<Widget> sourceRows = <Widget>[
      _buildVirtualSourceRow(
        tokens,
        icon: Icons.devices_outlined,
        title: t.audio_source_fushi_interconnect,
        subtitle: t.interconnect_enable_hint,
        value: interconnectEnabled,
        onChanged: _setInterconnectEnabled,
      ),
      if (rows.isNotEmpty) ...<Widget>[
        Padding(
          padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
          child: const Divider(height: 1),
        ),
        _buildFolderRows(tokens, rows),
      ],
    ];
    return Column(children: sourceRows);
  }

  Widget _buildFolderRows(
    FushiDesignTokens tokens,
    List<SourceLibraryRow> rows,
  ) {
    // 自实现的 FushiReorderableColumn（局部坐标长按拖拽，消祖先 FushiAppUiScale
    // 缩放），与 LocalAudioSourcesDialog 同款，而非 SDK ReorderableListView。
    return FushiReorderableColumn(
      itemCount: rows.length,
      keyForIndex: (int index) =>
          ValueKey<String>('media_source_${rows[index].id}'),
      onReorder: (int from, int to) {
        setState(() {
          final SourceLibraryRow item = rows.removeAt(from);
          rows.insert(to, item);
        });
        _persistOrder();
      },
      itemBuilder: (BuildContext context, int index) =>
          _buildRow(tokens, rows[index]),
    );
  }

  Widget _buildVirtualSourceRow(
    FushiDesignTokens tokens, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
      child: Row(
        children: <Widget>[
          Icon(icon, color: cs.onSurfaceVariant),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(title, style: theme.textTheme.titleSmall),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          adaptiveSwitch(
            context: context,
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Future<void> _setInterconnectEnabled(bool value) async {
    setState(() => _interconnectEnabled = value);
    try {
      await SyncRepository(_db).setInterconnectEnabled(value);
    } catch (_) {
      if (!mounted) return;
      setState(() => _interconnectEnabled = !value);
    }
  }

  Widget _buildRow(FushiDesignTokens tokens, SourceLibraryRow row) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final TextStyle? subStyle =
        theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final bool isLocal = row.transport == 'local';
    final bool isVideo = widget.mediaKind == 'video';
    final bool scanning = _scanning.contains(row.id);
    final bool scraping = _isScrapingSource(row.id);
    final bool busy = scanning || scraping || isBusy;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(
            isLocal ? Icons.folder_outlined : Icons.cloud_outlined,
            color: cs.onSurfaceVariant,
          ),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  row.label,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _rowLocation(row),
                  style: subStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                _buildStatusLine(theme, cs, subStyle, row),
              ],
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiIconButton(
                icon: Icons.refresh,
                size: 18,
                tooltip: t.media_source_rescan,
                busy: scanning,
                enabled: !busy,
                padding: EdgeInsets.all(tokens.spacing.gap / 2),
                onTap: () => _rescan(row),
              ),
              if (isVideo && widget.onScrapeSource != null)
                FushiIconButton(
                  icon: Icons.manage_search_outlined,
                  size: 18,
                  tooltip: t.video_source_scrape_action,
                  busy: scraping,
                  enabled: !busy,
                  padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  onTap: () => _scrapeSource(row),
                ),
              if (isVideo)
                FushiIconButton(
                  icon: Icons.tune,
                  size: 18,
                  tooltip: t.video_source_scrape_settings,
                  enabled: !busy,
                  padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  onTap: () => _openVideoScrapeSettings(row),
                ),
              FushiIconButton(
                icon: Icons.folder_open,
                size: 18,
                tooltip: t.media_source_open_folder,
                // 打开文件夹只在 Windows + 本地来源可用；网络来源无本地目录可开。
                enabled: isLocal && Platform.isWindows,
                padding: EdgeInsets.all(tokens.spacing.gap / 2),
                onTap: () => _openFolder(row),
              ),
              FushiIconButton(
                icon: Icons.remove_circle_outline,
                size: 18,
                tooltip: t.media_source_remove,
                enabled: !busy,
                padding: EdgeInsets.all(tokens.spacing.gap / 2),
                onTap: () => _remove(row),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 行副标题的「位置」文案：本地=路径；网络=`TRANSPORT · user@host  rootPath`。
  String _rowLocation(SourceLibraryRow row) {
    if (row.transport == 'local') {
      return row.rootPath;
    }
    final Map<String, Object?> config = decodeSourceConfig(row.configJson);
    final String host = (config['host'] as String?) ?? '';
    final String user = (config['username'] as String?) ?? '';
    final String prefix = row.transport.toUpperCase();
    final String authority =
        user.isEmpty ? host : (host.isEmpty ? user : '$user@$host');
    return '$prefix · $authority  ${row.rootPath}';
  }

  Widget _buildStatusLine(
    ThemeData theme,
    ColorScheme cs,
    TextStyle? subStyle,
    SourceLibraryRow row,
  ) {
    final VideoSourceScrapeProgress? active = _scrapeProgressFor(row.id);
    if (active != null) {
      final String phase = _scrapePhaseLabel(active.phase);
      final String progress = t.video_source_scrape_progress(
        phase: phase,
        current: active.current,
        total: active.total,
      );
      final String? title = active.currentWorkTitle;
      return Text(
        title == null || title.isEmpty ? progress : '$progress  ·  $title',
        style: subStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (row.lastScanError != null) {
      return Text(
        t.media_source_scan_error,
        style: subStyle?.copyWith(color: cs.error),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    final VideoSourceScrapeRunRow? latest = _latestScrapeRuns[row.id];
    if (widget.mediaKind == 'video' && latest != null) {
      return Text(
        t.video_source_scrape_last_summary(
          status: _scrapeRunStatusLabel(latest.status),
          succeeded: latest.succeededWorks,
          pending: latest.pendingConfirmations,
          failed: latest.failedWorks,
        ),
        style: subStyle?.copyWith(
          color: latest.failedWorks > 0 ? cs.error : null,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    // TODO-1036：显示该来源**累计拥有**的条目数（不是上次扫描新增数 mediaCount，
    // 后者在重扫已全部导入的来源时会因去重跳过而显示 0）。
    final int total = _cumulativeCount[row.id] ?? row.mediaCount;
    final String count = switch (widget.mediaKind) {
      'book' => t.media_source_count_book(n: total),
      'manga' => t.media_source_count_manga(n: total),
      _ => t.media_source_count_video(n: total),
    };
    final DateTime? scannedAt = row.lastScannedAt;
    final String text = scannedAt == null
        ? count
        : '$count  ·  ${t.media_source_last_scan(time: _formatTime(scannedAt))}';
    return Text(
      text,
      style: subStyle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 本地化无关的简洁时间格式（YYYY-MM-DD HH:MM）；不引 intl，跨 17 语言一致。
  String _formatTime(DateTime time) => FushiTimeFormat.dateHourMinute(time);

  bool _isScrapingSource(int sourceId) {
    if (_scraping.contains(sourceId)) return true;
    final VideoSourceScrapeProgress? progress =
        widget.scrapeTaskController?.progress;
    return progress != null &&
        progress.isRunning &&
        progress.sourceId == sourceId;
  }

  VideoSourceScrapeProgress? _scrapeProgressFor(int sourceId) {
    final VideoSourceScrapeProgress? progress =
        widget.scrapeTaskController?.progress;
    if (progress == null || !progress.isRunning) return null;
    return progress.sourceId == sourceId ? progress : null;
  }

  String _scrapePhaseLabel(VideoSourceScrapePhase phase) => switch (phase) {
        VideoSourceScrapePhase.planning => t.video_source_scrape_phase_planning,
        VideoSourceScrapePhase.recognizing =>
          t.video_source_scrape_phase_recognizing,
        VideoSourceScrapePhase.fetching => t.video_source_scrape_phase_fetching,
        VideoSourceScrapePhase.applying => t.video_source_scrape_phase_applying,
        VideoSourceScrapePhase.writingSidecars =>
          t.video_source_scrape_phase_writing_sidecars,
        _ => t.video_source_scrape_action,
      };

  String _scrapeRunStatusLabel(String status) => switch (status) {
        'completed' => t.download_task_status_completed,
        'cancelled' => t.download_status_cancelled,
        'interrupted' => t.video_source_scrape_status_interrupted,
        'failed' => t.download_task_status_error,
        _ => status,
      };

  /// 拖拽重排后逐行回写 sortOrder（与 DAO orderBy(sortOrder, id) 对齐）。
  Future<void> _persistOrder() async {
    final List<SourceLibraryRow> rows = _rows ?? const <SourceLibraryRow>[];
    for (int i = 0; i < rows.length; i++) {
      await _db.updateMediaSourceSortOrder(rows[i].id, i);
    }
  }

  /// 计算新来源的 sortOrder（现有最大值 +1，空则 0）。
  int _nextSortOrder() {
    final List<SourceLibraryRow> existing = _rows ?? const <SourceLibraryRow>[];
    return existing.isEmpty
        ? 0
        : existing
                .map((SourceLibraryRow r) => r.sortOrder)
                .reduce((int a, int b) => a > b ? a : b) +
            1;
  }

  /// 添加来源：让用户选本地文件夹或网络来源（后者仅 'book' 开放）。
  ///
  /// 公开给外层的唯一动作入口（对话框页脚 / 页面页头按钮都调它）。
  Future<void> addSource() async {
    if (isBusy) return;
    // 视频来源只有本地文件夹这一种合法入口，直接选择并立即登记/扫描，避免再弹一层
    // 只有一个选项的对话框。书籍仍保留本地/网络选择，漫画 UX 保持不变。
    if (widget.mediaKind == 'video') {
      await _addLocalFolder();
      return;
    }
    final _AddSourceChoice? choice = await showAppDialog<_AddSourceChoice>(
      context: context,
      builder: (BuildContext ctx) => SimpleDialog(
        title: Text(t.media_source_add),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, _AddSourceChoice.local),
            child: Row(
              children: <Widget>[
                const Icon(Icons.folder_outlined),
                const SizedBox(width: 16),
                // BUG-1184：紧邻的「网络来源」选项已用 Expanded，这条漏了——窄屏 +
                // 长本地化文案时裸 Text 直接把 Row 撑溢出。
                Expanded(child: Text(t.media_source_add_local_folder)),
              ],
            ),
          ),
          if (_networkSupported)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, _AddSourceChoice.network),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(Icons.cloud_outlined),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(t.media_source_add_network),
                        Text(
                          t.media_source_network_subtitle,
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _AddSourceChoice.local:
        await _addLocalFolder();
      case _AddSourceChoice.network:
        await _addNetworkSource();
    }
  }

  Future<void> _addLocalFolder() async {
    // 扫描根是**长期存储并反复复扫**的路径，必须是 `dart:io` 真读得动的绝对路径：
    // 安卓上裸 `getDirectoryPath()` 只是把 tree URI 拼成路径串（映射不出 volume 时
    // 还会退化成 `/`），而 SAF 授的是 URI 权限不是路径权限——没有全文件访问，扫描
    // 器读它必失败，于是「加了来源却永远扫不出书」。统一走 pickRealDirectoryPath
    // （安卓先取全文件访问再经原生 SAF 解析真实路径；桌面/iOS 行为逐字不变）。
    final String? picked = await pickRealDirectoryPath(
      context: context,
      appModel: _appModel,
      dialogTitle: t.media_source_add_local_folder,
    );
    if (!mounted || picked == null || picked.isEmpty) return;

    final String norm = normalizeSourceRootPath(picked, transport: 'local');
    final List<SourceLibraryRow> existing = _rows ?? const <SourceLibraryRow>[];
    final bool dup = existing.any(
        (SourceLibraryRow r) => r.transport == 'local' && r.rootPath == norm);
    if (dup) {
      FushiToast.show(msg: norm, severity: ToastSeverity.warning);
      return;
    }

    final int newId = await _db.insertMediaSource(
      MediaSourcesCompanion(
        label: Value(defaultLabelFromRoot(norm, transport: 'local')),
        mediaKind: Value(widget.mediaKind),
        transport: const Value('local'),
        rootPath: Value(norm),
        recursive: const Value(true),
        sortOrder: Value(_nextSortOrder()),
        createdAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    await _load();
    // 插入后立即扫描新行（拿回带 scanResult 的最新行刷新统计）。
    final SourceLibraryRow? fresh = await _db.getMediaSourceById(newId);
    if (fresh != null) await _rescan(fresh);
  }

  /// 添加网络来源：弹连接表单（SFTP/FTP）→ 落库连接参数 + 单独存凭据 → 立即扫描。
  Future<void> _addNetworkSource() async {
    final _NetworkSourceResult? result =
        await showAppDialog<_NetworkSourceResult>(
      context: context,
      builder: (BuildContext ctx) => const _NetworkSourceFormDialog(),
    );
    if (!mounted || result == null) return;

    final String norm =
        normalizeSourceRootPath(result.remotePath, transport: result.transport);
    final List<SourceLibraryRow> existing = _rows ?? const <SourceLibraryRow>[];
    // 去重：同传输 + 同 host + 同 rootPath 视为同一来源。
    final bool dup = existing.any((SourceLibraryRow r) {
      if (r.transport != result.transport || r.rootPath != norm) return false;
      final Map<String, Object?> cfg = decodeSourceConfig(r.configJson);
      return (cfg['host'] as String?) == result.host;
    });
    if (dup) {
      FushiToast.show(msg: norm, severity: ToastSeverity.warning);
      return;
    }

    final String label = result.label.trim().isNotEmpty
        ? result.label.trim()
        : defaultLabelFromRoot(norm, transport: result.transport);
    final String? configJson = encodeSourceConfig(<String, Object?>{
      'host': result.host,
      'port': result.port,
      'username': result.username,
      'useTls': result.useTls,
    });

    final int newId = await _db.insertMediaSource(
      MediaSourcesCompanion(
        label: Value(label),
        mediaKind: Value(widget.mediaKind),
        transport: Value(result.transport),
        rootPath: Value(norm),
        configJson: Value(configJson),
        recursive: const Value(true),
        sortOrder: Value(_nextSortOrder()),
        createdAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    // 凭据单独落库（绝不进 configJson）。
    await SourceLibraryCredentialStore(_db).saveSecret(
      newId,
      password: result.password,
      privateKey: result.privateKey,
    );
    await _load();
    final SourceLibraryRow? fresh = await _db.getMediaSourceById(newId);
    if (fresh != null) await _rescan(fresh);
  }

  /// 重新扫描一个来源：行级 loading → scanner.scan（内部吞异常写 lastScanError）→
  /// 重读该行刷新统计/时间/错误。
  Future<void> _rescan(SourceLibraryRow row) async {
    if (isBusy) return;
    final VoidCallback? onLibraryChanged = widget.onLibraryChanged;
    final Future<void> Function(SourceLibraryRow, SourceScanSummary)?
        onVideoScanCompleted = widget.onVideoScanCompleted;
    SourceScanSummary? summary;
    setState(() => _scanning.add(row.id));
    try {
      Future<SourceScanSummary> scan() => SourceLibraryScanner(_db).scan(row);
      final VideoSourceScrapeTaskController? controller =
          widget.mediaKind == 'video' ? widget.scrapeTaskController : null;
      summary = controller == null
          ? await scan()
          : await controller.runSourceScan(row.id, scan);
    } finally {
      try {
        final SourceLibraryRow? updated = await _db.getMediaSourceById(row.id);
        if (row.mediaKind == 'video' &&
            summary != null &&
            onVideoScanCompleted != null) {
          // 回调属于 HomePage，页面在扫描期间被切走也要继续执行。
          // 保持 _scanning 到回调结束，确保同来源扫描与自动刮削不会重入。
          await onVideoScanCompleted(updated ?? row, summary);
        }
        if (mounted) {
          setState(() {
            _scanning.remove(row.id);
            final List<SourceLibraryRow>? rows = _rows;
            if (rows != null && updated != null) {
              final int idx =
                  rows.indexWhere((SourceLibraryRow r) => r.id == row.id);
              if (idx >= 0) rows[idx] = updated;
            }
          });
          // 扫描可能新增条目，刷新累计计数（TODO-1036）。
          await _refreshCount(row.id);
        }
      } finally {
        onLibraryChanged?.call();
      }
    }
  }

  Future<void> _scrapeSource(SourceLibraryRow row) async {
    final Future<void> Function(SourceLibraryRow source)? scrape =
        widget.onScrapeSource;
    if (scrape == null || isBusy) {
      return;
    }
    final VoidCallback? onLibraryChanged = widget.onLibraryChanged;
    setState(() => _scraping.add(row.id));
    try {
      await scrape(row);
    } finally {
      await _refreshLatestScrapeRun(row.id);
      if (mounted) setState(() => _scraping.remove(row.id));
      onLibraryChanged?.call();
    }
  }

  Future<void> _openVideoScrapeSettings(SourceLibraryRow row) async {
    if (widget.mediaKind != 'video' || isBusy) {
      return;
    }
    final VideoSourceScrapeSettingRow? existing =
        await _db.getVideoSourceScrapeSettings(row.id);
    if (!mounted) return;
    final _VideoSourceScrapeSettingsDraft? draft =
        await showAppDialog<_VideoSourceScrapeSettingsDraft>(
      context: context,
      builder: (BuildContext context) => _VideoSourceScrapeSettingsDialog(
        initial: _VideoSourceScrapeSettingsDraft.fromRow(existing),
      ),
    );
    if (draft == null) return;
    await _db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
        sourceId: Value<int>(row.id),
        enabled: Value<bool>(existing?.enabled ?? true),
        providerOverride: Value<String?>(draft.providerOverride),
        autoAfterScan: Value<bool>(draft.autoAfterScan),
        writeNfo: Value<bool>(draft.writeNfo),
        writeImages: Value<bool>(draft.writeImages),
        fanartEnabled: Value<bool>(draft.fanartEnabled),
        nfoPolicy: Value<String>(draft.nfoPolicy),
        imagePolicy: Value<String>(draft.imagePolicy),
        allowExternalOverwrite: Value<bool>(draft.allowExternalOverwrite),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 打开来源根目录（仅 Windows 本地来源，复用仓库唯一现成的 explorer 调用）。
  Future<void> _openFolder(SourceLibraryRow row) async {
    if (!Platform.isWindows || row.transport != 'local') return;
    try {
      // rootPath 由 normalizeSourceRootPath 归一化为正斜杠（跨平台一致 + dedup），
      // 但 Windows explorer.exe 只认反斜杠路径参数：传正斜杠会被忽略、改开默认
      // 「文档」目录（BUG-920）。仅在 explorer 这个平台边界把 `/` 转回 `\`。
      final String windowsPath = row.rootPath.replaceAll('/', r'\');
      await Process.run('explorer', <String>[windowsPath]);
    } catch (_) {
      // 打开失败不致命（路径可能已不存在）；静默即可。
    }
  }

  /// 移除来源：确认对话框强调移除来源不会删除已导入的媒体（FK setNull 自动
  /// 把归属媒体的 source_id 归 NULL，条目保留）→ 确认则 deleteMediaSource +
  /// 清除该来源的网络凭据 → 刷新。
  Future<void> _remove(SourceLibraryRow row) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog.adaptive(
        title: Text(t.media_source_remove),
        content: Text(t.media_source_remove_keeps_media),
        actions: <Widget>[
          adaptiveDialogAction(
            context: ctx,
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: ctx,
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.media_source_remove),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _db.deleteMediaSource(row.id);
    // 网络来源凭据随行清除（本地来源无凭据，deleteSecret 幂等无副作用）。
    await SourceLibraryCredentialStore(_db).deleteSecret(row.id);
    await _load();
  }
}

class _VideoSourceScrapeSettingsDraft {
  const _VideoSourceScrapeSettingsDraft({
    required this.providerOverride,
    required this.autoAfterScan,
    required this.writeNfo,
    required this.writeImages,
    required this.fanartEnabled,
    required this.nfoPolicy,
    required this.imagePolicy,
    required this.allowExternalOverwrite,
  });

  factory _VideoSourceScrapeSettingsDraft.fromRow(
    VideoSourceScrapeSettingRow? row,
  ) {
    const Set<String> providers = <String>{
      'tmdb',
      'douban',
      'bangumi',
      'anilist',
    };
    final String? provider = row?.providerOverride;
    return _VideoSourceScrapeSettingsDraft(
      providerOverride: providers.contains(provider) ? provider : null,
      autoAfterScan: row?.autoAfterScan ?? false,
      writeNfo: row?.writeNfo ?? true,
      writeImages: row?.writeImages ?? true,
      fanartEnabled: row?.fanartEnabled ?? true,
      nfoPolicy: _validPolicy(row?.nfoPolicy),
      imagePolicy: _validPolicy(row?.imagePolicy),
      allowExternalOverwrite: row?.allowExternalOverwrite ?? false,
    );
  }

  final String? providerOverride;
  final bool autoAfterScan;
  final bool writeNfo;
  final bool writeImages;
  final bool fanartEnabled;
  final String nfoPolicy;
  final String imagePolicy;
  final bool allowExternalOverwrite;

  static String _validPolicy(String? value) =>
      const <String>{'skip', 'missingOnly', 'overwrite'}.contains(value)
          ? value!
          : 'missingOnly';
}

class _VideoSourceScrapeSettingsDialog extends StatefulWidget {
  const _VideoSourceScrapeSettingsDialog({required this.initial});

  final _VideoSourceScrapeSettingsDraft initial;

  @override
  State<_VideoSourceScrapeSettingsDialog> createState() =>
      _VideoSourceScrapeSettingsDialogState();
}

class _VideoSourceScrapeSettingsDialogState
    extends State<_VideoSourceScrapeSettingsDialog> {
  static const String _inheritProvider = '';

  late String _provider = widget.initial.providerOverride ?? _inheritProvider;
  late bool _autoAfterScan = widget.initial.autoAfterScan;
  late bool _writeNfo = widget.initial.writeNfo;
  late bool _writeImages = widget.initial.writeImages;
  late bool _fanartEnabled = widget.initial.fanartEnabled;
  late String _nfoPolicy = widget.initial.nfoPolicy;
  late String _imagePolicy = widget.initial.imagePolicy;
  late bool _allowExternalOverwrite = widget.initial.allowExternalOverwrite;

  void _save() {
    Navigator.pop(
      context,
      _VideoSourceScrapeSettingsDraft(
        providerOverride: _provider.isEmpty ? null : _provider,
        autoAfterScan: _autoAfterScan,
        writeNfo: _writeNfo,
        writeImages: _writeImages,
        fanartEnabled: _fanartEnabled,
        nfoPolicy: _nfoPolicy,
        imagePolicy: _imagePolicy,
        allowExternalOverwrite: _allowExternalOverwrite,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.video_source_scrape_settings),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AdaptiveSettingsPickerRow<String>(
                title: t.video_source_scrape_provider,
                selected: _provider,
                options: <AdaptiveSettingsPickerOption<String>>[
                  AdaptiveSettingsPickerOption<String>(
                    value: _inheritProvider,
                    label: t.video_source_scrape_provider_inherit,
                  ),
                  const AdaptiveSettingsPickerOption<String>(
                    value: 'tmdb',
                    label: 'TMDB',
                  ),
                  const AdaptiveSettingsPickerOption<String>(
                    value: 'douban',
                    label: 'Douban',
                  ),
                  const AdaptiveSettingsPickerOption<String>(
                    value: 'bangumi',
                    label: 'Bangumi',
                  ),
                  const AdaptiveSettingsPickerOption<String>(
                    value: 'anilist',
                    label: 'AniList',
                  ),
                ],
                onChanged: (String value) => setState(() => _provider = value),
                controlBelow: true,
              ),
              AdaptiveSettingsSwitchRow(
                title: t.video_source_scrape_auto_after_scan,
                subtitle: t.video_source_scrape_auto_after_scan_hint,
                value: _autoAfterScan,
                onChanged: (bool value) =>
                    setState(() => _autoAfterScan = value),
              ),
              AdaptiveSettingsSwitchRow(
                title: t.video_source_scrape_write_nfo,
                value: _writeNfo,
                onChanged: (bool value) => setState(() => _writeNfo = value),
              ),
              AdaptiveSettingsSwitchRow(
                title: t.video_source_scrape_write_images,
                value: _writeImages,
                onChanged: (bool value) => setState(() => _writeImages = value),
              ),
              AdaptiveSettingsSwitchRow(
                title: t.video_source_scrape_use_fanart,
                value: _fanartEnabled,
                onChanged: (bool value) =>
                    setState(() => _fanartEnabled = value),
              ),
              AdaptiveSettingsPickerRow<String>(
                title: t.video_source_scrape_nfo_policy,
                selected: _nfoPolicy,
                options: _policyOptions(),
                onChanged: (String value) => setState(() => _nfoPolicy = value),
                controlBelow: true,
              ),
              AdaptiveSettingsPickerRow<String>(
                title: t.video_source_scrape_image_policy,
                selected: _imagePolicy,
                options: _policyOptions(),
                onChanged: (String value) =>
                    setState(() => _imagePolicy = value),
                controlBelow: true,
              ),
              AdaptiveSettingsSwitchRow(
                title: t.video_source_scrape_external_overwrite,
                subtitle: t.video_source_scrape_external_overwrite_hint,
                value: _allowExternalOverwrite,
                onChanged: (bool value) =>
                    setState(() => _allowExternalOverwrite = value),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        adaptiveDialogAction(
          context: context,
          isDefaultAction: true,
          onPressed: _save,
          child: Text(t.dialog_save),
        ),
      ],
    );
  }

  List<AdaptiveSettingsPickerOption<String>> _policyOptions() =>
      <AdaptiveSettingsPickerOption<String>>[
        AdaptiveSettingsPickerOption<String>(
          value: 'skip',
          label: t.video_source_scrape_policy_skip,
        ),
        AdaptiveSettingsPickerOption<String>(
          value: 'missingOnly',
          label: t.video_source_scrape_policy_missing_only,
        ),
        AdaptiveSettingsPickerOption<String>(
          value: 'overwrite',
          label: t.video_source_scrape_policy_overwrite,
        ),
      ];
}

/// 添加来源的两个 case：本地文件夹 / 网络来源。
enum _AddSourceChoice { local, network }

/// 网络来源表单返回值（连接参数 + 凭据；凭据不落 configJson）。
class _NetworkSourceResult {
  const _NetworkSourceResult({
    required this.transport,
    required this.host,
    required this.port,
    required this.username,
    required this.remotePath,
    required this.label,
    this.password,
    this.privateKey,
    this.useTls = false,
  });

  final String transport; // 'sftp' | 'ftp'
  final String host;
  final int port;
  final String username;
  final String remotePath;
  final String label;
  final String? password;
  final String? privateKey;
  final bool useTls;
}

/// 网络来源连接表单：SFTP/FTP 二选一，填 host/port/user/password（SFTP 可用私钥、
/// FTP 可开 TLS）+ 远端根路径 + 可选显示名，附「测试连接」（复用 sync 后端）。
class _NetworkSourceFormDialog extends StatefulWidget {
  const _NetworkSourceFormDialog();

  @override
  State<_NetworkSourceFormDialog> createState() =>
      _NetworkSourceFormDialogState();
}

class _NetworkSourceFormDialogState extends State<_NetworkSourceFormDialog> {
  String _transport = 'sftp';
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController =
      TextEditingController(text: '22');
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  final TextEditingController _labelController = TextEditingController();
  // WebDAV 专用：完整集合 URL（既是连接目标，也是来源 rootPath）。
  final TextEditingController _urlController = TextEditingController();
  bool _useTls = false;
  bool _testing = false;
  bool _portTouched = false;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _keyController.dispose();
    _pathController.dispose();
    _labelController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  bool get _isSftp => _transport == 'sftp';

  bool get _isWebDav => _transport == 'webdav';

  int get _port =>
      int.tryParse(_portController.text.trim()) ?? (_isSftp ? 22 : 21);

  void _onTransportChanged(String value) {
    if (value == _transport) return;
    setState(() {
      _transport = value;
      // 未手动改过端口时，切协议自动填默认端口（WebDAV 无独立端口字段，端口在 URL 里）。
      if (!_portTouched && !_isWebDav) {
        _portController.text = _isSftp ? '22' : '21';
      }
      if (_isSftp || _isWebDav) _useTls = false;
    });
  }

  /// 校验必填项：
  /// - WebDAV：URL（http/https）+ 用户名 + 密码。
  /// - SFTP/FTP：host / username / remotePath 非空，且密码或私钥至少一个。
  String? _validate() {
    if (_isWebDav) {
      final String url = _urlController.text.trim();
      if (url.isEmpty ||
          _userController.text.trim().isEmpty ||
          _passwordController.text.isEmpty) {
        return t.sync_webdav_missing_fields;
      }
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        return t.sync_webdav_missing_fields;
      }
      return null;
    }
    if (_hostController.text.trim().isEmpty ||
        _userController.text.trim().isEmpty ||
        _pathController.text.trim().isEmpty) {
      return t.media_source_network_missing_fields;
    }
    final bool hasPass = _passwordController.text.isNotEmpty;
    final bool hasKey = _isSftp && _keyController.text.trim().isNotEmpty;
    if (!hasPass && !hasKey) {
      return t.media_source_network_missing_fields;
    }
    return null;
  }

  Future<void> _testConnection() async {
    final String? error = _validate();
    if (error != null) {
      FushiToast.show(msg: error, severity: ToastSeverity.error);
      return;
    }
    setState(() => _testing = true);
    try {
      final String host = _hostController.text.trim();
      final String user = _userController.text.trim();
      final String pass = _passwordController.text;
      final String key = _keyController.text.trim();
      if (_isWebDav) {
        // 复用 sync 子系统的 WebDAV 后端探活（PROPFIND Depth:0）。
        await WebDavSyncBackend.instance.testConnection(
          url: _urlController.text.trim(),
          username: user,
          password: pass,
        );
      } else if (_isSftp) {
        await SftpSyncBackend.instance.testConnection(
          host: host,
          port: _port,
          username: user,
          password: pass.isEmpty ? null : pass,
          privateKey: key.isEmpty ? null : key,
        );
      } else {
        await FtpSyncBackend.testConnection(
          host: host,
          port: _port,
          username: user,
          password: pass,
          useTls: _useTls,
        );
      }
      if (mounted) {
        FushiToast.show(
          msg: t.sync_connection_success,
          severity: ToastSeverity.success,
        );
      }
    } catch (e) {
      if (mounted) {
        FushiToast.show(
          msg: '${t.sync_connection_failed}: $e',
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _submit() {
    final String? error = _validate();
    if (error != null) {
      FushiToast.show(msg: error, severity: ToastSeverity.error);
      return;
    }
    final String pass = _passwordController.text;
    final String key = _keyController.text.trim();
    if (_isWebDav) {
      // WebDAV：URL 既是连接目标也是来源 rootPath；host/port 仅供列表展示，从 URL 派生。
      final String url = _urlController.text.trim();
      final Uri u = Uri.tryParse(url) ?? Uri();
      Navigator.pop(
        context,
        _NetworkSourceResult(
          transport: 'webdav',
          host: u.host,
          port: u.hasPort ? u.port : (u.scheme == 'https' ? 443 : 80),
          username: _userController.text.trim(),
          remotePath: url,
          label: _labelController.text,
          password: pass.isEmpty ? null : pass,
          useTls: false,
        ),
      );
      return;
    }
    Navigator.pop(
      context,
      _NetworkSourceResult(
        transport: _transport,
        host: _hostController.text.trim(),
        port: _port,
        username: _userController.text.trim(),
        remotePath: _pathController.text.trim(),
        label: _labelController.text,
        password: pass.isEmpty ? null : pass,
        privateKey: _isSftp && key.isNotEmpty ? key : null,
        useTls: _isSftp ? false : _useTls,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.media_source_add_network),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SegmentedButton<String>(
                segments: const <ButtonSegment<String>>[
                  ButtonSegment<String>(value: 'sftp', label: Text('SFTP')),
                  ButtonSegment<String>(value: 'ftp', label: Text('FTP')),
                  ButtonSegment<String>(value: 'webdav', label: Text('WebDAV')),
                ],
                selected: <String>{_transport},
                onSelectionChanged: (Set<String> s) =>
                    _onTransportChanged(s.first),
              ),
              const SizedBox(height: 12),
              // WebDAV：整库定位靠单个集合 URL（含 scheme/host/端口/路径），故不显示
              // host/port/远端路径，只填 URL + 账号密码；SFTP/FTP 走 host/port/路径。
              if (_isWebDav) ...<Widget>[
                FushiTextField(
                  controller: _urlController,
                  labelText: t.sync_webdav_url,
                  hintText: 'https://dav.example.com/dav/books',
                ),
                const SizedBox(height: 12),
              ],
              if (!_isWebDav) ...<Widget>[
                FushiTextField(
                  controller: _hostController,
                  labelText: t.sync_host,
                  hintText: _isSftp ? 'ssh.example.com' : 'ftp.example.com',
                ),
                const SizedBox(height: 12),
                FushiTextField(
                  controller: _portController,
                  labelText: t.sync_port,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _portTouched = true,
                ),
                const SizedBox(height: 12),
              ],
              FushiTextField(
                controller: _userController,
                labelText: t.sync_username,
              ),
              const SizedBox(height: 12),
              FushiTextField(
                controller: _passwordController,
                labelText: t.sync_password,
                obscureText: true,
              ),
              if (_isSftp) ...<Widget>[
                const SizedBox(height: 12),
                FushiTextField(
                  controller: _keyController,
                  labelText: t.sync_private_key,
                  hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                  maxLines: 4,
                ),
              ],
              if (!_isSftp && !_isWebDav) ...<Widget>[
                const SizedBox(height: 4),
                AdaptiveSettingsSwitchRow(
                  title: t.sync_use_tls,
                  value: _useTls,
                  onChanged: (bool v) => setState(() => _useTls = v),
                ),
              ],
              if (!_isWebDav) ...<Widget>[
                const SizedBox(height: 12),
                FushiTextField(
                  controller: _pathController,
                  labelText: t.media_source_network_remote_path,
                  hintText: '/books',
                ),
              ],
              const SizedBox(height: 12),
              FushiTextField(
                controller: _labelController,
                labelText: t.media_source_network_label_optional,
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: _testing
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : FilledButton.tonal(
                        onPressed: _testConnection,
                        child: Text(t.sync_test_connection),
                      ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        adaptiveDialogAction(
          context: context,
          isDefaultAction: true,
          onPressed: _submit,
          child: Text(t.media_source_add),
        ),
      ],
    );
  }
}
