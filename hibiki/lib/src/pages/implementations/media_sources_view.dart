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

import 'dart:io' show Platform, Process;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/source_library/source_library_credential_store.dart';
import 'package:hibiki/src/media/source_library/source_library_row.dart';
import 'package:hibiki/src/media/source_library/source_library_scanner.dart';
import 'package:hibiki/src/sync/ftp_sync_backend.dart';
import 'package:hibiki/src/sync/sftp_sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/webdav_sync_backend.dart';
import 'package:hibiki/src/pages/hibiki_page_placeholders.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/import/real_path_directory_picker.dart';

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
    this.onLibraryChanged,
  });

  /// 'video' | 'book' | 'manga' —— 决定统计文案与 mediaKind 过滤。
  final String mediaKind;

  /// true = 自带纵向滚动（页面语境，外层给的是 Expanded 无界高度）；
  /// false = 返回裸内容（对话框语境，由外层 ConstrainedBox + SingleChildScrollView
  /// 限高并滚动，保持 BUG-445 / TODO-1389 的既有修法不变）。
  final bool scrollable;

  /// 一次来源扫描收尾后的媒体库变化通知（无论扫描成功、部分成功或记录错误）。
  final VoidCallback? onLibraryChanged;

  @override
  ConsumerState<MediaSourcesView> createState() => MediaSourcesViewState();
}

class MediaSourcesViewState extends ConsumerState<MediaSourcesView>
    with HibikiPagePlaceholders<MediaSourcesView> {
  /// null = 仍在加载；非 null = 已加载（可能为空列表）。
  List<SourceLibraryRow>? _rows;

  /// Hibiki 互联不是 `media_sources` 扫描根，但它确实是**本机之外的同一批本地
  /// 文件**（局域网里另一台自己的设备），所以与扫描根同列。
  ///
  /// 🔴 别再往这里加「网站」型来源（BUG-1431）：mokuro.moe 曾挂在这一节，用户口径
  /// 是它不该跟扫描根混在一起。在线漫画源统一归 `MangaSourcesPage` 的「漫画源」
  /// 一节（`MokuroMoeSourceRow`），与扩展提供的源同级。
  bool? _interconnectEnabled;

  /// 每个来源 id → 当前**累计拥有**的媒体条目数（TODO-1036）。
  /// 与列表一起加载，避免逐行 FutureBuilder 抖动。来源不在 map 里时回退 0。
  final Map<int, int> _cumulativeCount = <int, int>{};

  /// 正在扫描中的来源 id 集合（行级 loading）。
  final Set<int> _scanning = <int>{};

  /// 数据库引用在 initState（ProviderScope 必然存活）时捕获一次，之后所有 async
  /// 操作都用它，绝不在 async gap 恢复后再 `ref.read`。否则用户点「重新扫描」后关闭
  /// 对话框，扫描完成的 finally 里若再 `ref.read(appProvider)`，此 State 的
  /// ConsumerStatefulElement 已 dispose、ProviderScope 已销毁，
  /// `containerOf` 抛 `Bad state: No ProviderScope found`（BUG-513）。
  late final HibikiDatabase _db;

  /// 同 [_db]：`AppModel` 也在 initState 捕获。`_addLocalFolder` 要把它交给
  /// `pickRealDirectoryPath`（安卓那条腿用它申请全文件访问），而系统目录选择器是一段
  /// **很长的 async gap**——用户完全可能在选择器开着时把对话框关掉。捕获成字段后此处
  /// 不再出现任何 `ref.*`，BUG-513 的不变量（ref 只在 initState）继续成立。
  late final AppModel _appModel;

  /// 网络来源仅对 'book' 开放（见文件头说明）。
  bool get _networkSupported => widget.mediaKind == 'book';

  @override
  void initState() {
    super.initState();
    _appModel = ref.read(appProvider);
    _db = _appModel.database;
    _load();
  }

  Future<void> _load() async {
    final List<SourceLibraryRow> rows =
        await _db.getMediaSourcesByKind(widget.mediaKind);
    final bool interconnectEnabled =
        await SyncRepository(_db).isInterconnectEnabled();
    final Map<int, int> counts = await _loadCumulativeCounts(rows);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _interconnectEnabled = interconnectEnabled;
      _cumulativeCount
        ..clear()
        ..addAll(counts);
    });
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Widget body = _buildBody(tokens);
    return widget.scrollable ? SingleChildScrollView(child: body) : body;
  }

  Widget _buildBody(HibikiDesignTokens tokens) {
    final List<SourceLibraryRow>? rows = _rows;
    final bool? interconnectEnabled = _interconnectEnabled;
    if (rows == null || interconnectEnabled == null) {
      return buildLoading(padding: const EdgeInsets.all(24));
    }
    final List<Widget> sourceRows = <Widget>[
      _buildVirtualSourceRow(
        tokens,
        icon: Icons.devices_outlined,
        title: t.audio_source_hibiki_interconnect,
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
    HibikiDesignTokens tokens,
    List<SourceLibraryRow> rows,
  ) {
    // 自实现的 HibikiReorderableColumn（局部坐标长按拖拽，消祖先 HibikiAppUiScale
    // 缩放），与 LocalAudioSourcesDialog 同款，而非 SDK ReorderableListView。
    return HibikiReorderableColumn(
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
    HibikiDesignTokens tokens, {
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

  Widget _buildRow(HibikiDesignTokens tokens, SourceLibraryRow row) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final TextStyle? subStyle =
        theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final bool isLocal = row.transport == 'local';
    final bool busy = _scanning.contains(row.id);

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
              HibikiIconButton(
                icon: Icons.refresh,
                size: 18,
                tooltip: t.media_source_rescan,
                busy: busy,
                enabled: !busy,
                padding: EdgeInsets.all(tokens.spacing.gap / 2),
                onTap: () => _rescan(row),
              ),
              HibikiIconButton(
                icon: Icons.folder_open,
                size: 18,
                tooltip: t.media_source_open_folder,
                // 打开文件夹只在 Windows + 本地来源可用；网络来源无本地目录可开。
                enabled: isLocal && Platform.isWindows,
                padding: EdgeInsets.all(tokens.spacing.gap / 2),
                onTap: () => _openFolder(row),
              ),
              HibikiIconButton(
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
    if (row.lastScanError != null) {
      return Text(
        t.media_source_scan_error,
        style: subStyle?.copyWith(color: cs.error),
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
  String _formatTime(DateTime time) => HibikiTimeFormat.dateHourMinute(time);

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
      HibikiToast.show(msg: norm);
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
      HibikiToast.show(msg: norm);
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
    if (_scanning.contains(row.id)) return;
    final VoidCallback? onLibraryChanged = widget.onLibraryChanged;
    setState(() => _scanning.add(row.id));
    try {
      await SourceLibraryScanner(_db).scan(row);
    } finally {
      try {
        final SourceLibraryRow? updated = await _db.getMediaSourceById(row.id);
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
      HibikiToast.show(msg: error);
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
      if (mounted) HibikiToast.show(msg: t.sync_connection_success);
    } catch (e) {
      if (mounted) {
        HibikiToast.show(msg: '${t.sync_connection_failed}: $e');
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _submit() {
    final String? error = _validate();
    if (error != null) {
      HibikiToast.show(msg: error);
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
                HibikiTextField(
                  controller: _urlController,
                  labelText: t.sync_webdav_url,
                  hintText: 'https://dav.example.com/dav/books',
                ),
                const SizedBox(height: 12),
              ],
              if (!_isWebDav) ...<Widget>[
                HibikiTextField(
                  controller: _hostController,
                  labelText: t.sync_host,
                  hintText: _isSftp ? 'ssh.example.com' : 'ftp.example.com',
                ),
                const SizedBox(height: 12),
                HibikiTextField(
                  controller: _portController,
                  labelText: t.sync_port,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _portTouched = true,
                ),
                const SizedBox(height: 12),
              ],
              HibikiTextField(
                controller: _userController,
                labelText: t.sync_username,
              ),
              const SizedBox(height: 12),
              HibikiTextField(
                controller: _passwordController,
                labelText: t.sync_password,
                obscureText: true,
              ),
              if (_isSftp) ...<Widget>[
                const SizedBox(height: 12),
                HibikiTextField(
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
                HibikiTextField(
                  controller: _pathController,
                  labelText: t.media_source_network_remote_path,
                  hintText: '/books',
                ),
              ],
              const SizedBox(height: 12),
              HibikiTextField(
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
