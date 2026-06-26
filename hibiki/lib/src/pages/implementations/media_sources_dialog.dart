// TODO-817 M1c 来源库管理对话框：列出某媒体种类（'video' | 'book'）的来源库，
// 支持添加本地文件夹、重新扫描、打开文件夹（仅 Windows）、移除来源、拖拽重排。
//
// 骨架抄自 LocalAudioSourcesDialog（HibikiDialogFrame + HibikiModalSheetFrame +
// HibikiReorderableColumn，三态 null/empty/列表），但各操作即时落库（无批量保存），
// 数据来自 HibikiDatabase 的 MediaSources DAO。
//
// 凭据红线（M1c）：网络传输只渲染占位 UI——configJson 恒不传（NULL）、零密码
// 输入落库、提交按钮 disabled。密码存储方案是 M3 决策点，本对话框不碰任何凭据。

import 'dart:io' show Platform, Process;

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/source/media_source_scanner.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 管理网络/本地来源库的对话框：按 mediaKind（'video' | 'book'）过滤，
/// 列出该种类下所有来源库，提供添加 / 重新扫描 / 打开 / 移除 / 重排。
class MediaSourcesDialog extends ConsumerStatefulWidget {
  const MediaSourcesDialog({required this.mediaKind, super.key});

  /// 'video' | 'book' —— 决定标题/统计文案与 mediaKind 过滤。
  final String mediaKind;

  @override
  ConsumerState<MediaSourcesDialog> createState() => _MediaSourcesDialogState();
}

class _MediaSourcesDialogState extends ConsumerState<MediaSourcesDialog> {
  /// null = 仍在加载；非 null = 已加载（可能为空列表）。
  List<MediaSourceRow>? _rows;

  /// 正在扫描中的来源 id 集合（行级 loading）。
  final Set<int> _scanning = <int>{};

  HibikiDatabase get _db => ref.read(appProvider).database;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final List<MediaSourceRow> rows =
        await _db.getMediaSourcesByKind(widget.mediaKind);
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double maxHeight =
        (MediaQuery.of(context).size.height * 0.55).clamp(160.0, 480.0);

    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.92,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.media_source_manage_title,
        leadingIcon: Icons.folder_copy_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: double.maxFinite,
            maxHeight: maxHeight,
          ),
          child: _buildBody(tokens),
        ),
        footer: Row(
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: _addSource,
              child: Text(t.media_source_add),
            ),
            const Spacer(),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_close),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(HibikiDesignTokens tokens) {
    final List<MediaSourceRow>? rows = _rows;
    if (rows == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(t.media_source_no_sources, textAlign: TextAlign.center),
        ),
      );
    }
    // 自实现的 HibikiReorderableColumn（局部坐标长按拖拽，消祖先 HibikiAppUiScale
    // 缩放），与 LocalAudioSourcesDialog 同款，而非 SDK ReorderableListView。
    return HibikiReorderableColumn(
      itemCount: rows.length,
      keyForIndex: (int index) =>
          ValueKey<String>('media_source_${rows[index].id}'),
      onReorder: (int from, int to) {
        setState(() {
          final MediaSourceRow item = rows.removeAt(from);
          rows.insert(to, item);
        });
        _persistOrder();
      },
      itemBuilder: (BuildContext context, int index) =>
          _buildRow(tokens, rows[index]),
    );
  }

  Widget _buildRow(HibikiDesignTokens tokens, MediaSourceRow row) {
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
          Icon(Icons.folder_outlined, color: cs.onSurfaceVariant),
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
                  row.rootPath,
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
                // 打开文件夹只在 Windows + 本地来源可用（仓库内唯一现成的跨平台
                // 打开目录是 explorer，见 crash_dump_page.dart）；其它平台禁用，
                // 不为此新造 mac/Linux 平台代码（TODO-817 M1c plan-review 决策）。
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

  Widget _buildStatusLine(
    ThemeData theme,
    ColorScheme cs,
    TextStyle? subStyle,
    MediaSourceRow row,
  ) {
    if (row.lastScanError != null) {
      return Text(
        t.media_source_scan_error,
        style: subStyle?.copyWith(color: cs.error),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    final String count = widget.mediaKind == 'book'
        ? t.media_source_count_book(n: row.mediaCount)
        : t.media_source_count_video(n: row.mediaCount);
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
  String _formatTime(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  /// 拖拽重排后逐行回写 sortOrder（与 DAO orderBy(sortOrder, id) 对齐）。
  Future<void> _persistOrder() async {
    final List<MediaSourceRow> rows = _rows ?? const <MediaSourceRow>[];
    for (int i = 0; i < rows.length; i++) {
      await _db.updateMediaSourceSortOrder(rows[i].id, i);
    }
  }

  /// 添加来源：先让用户选本地文件夹或网络（占位），本地走目录选择 +
  /// 立即扫描；网络只弹占位提示（不落库、零凭据）。
  Future<void> _addSource() async {
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
                Text(t.media_source_add_local_folder),
              ],
            ),
          ),
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
                        t.media_source_network_coming_soon,
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
        // 占位：M1c 不实现网络来源，不写库、不存凭据。
        HibikiToast.show(msg: t.media_source_network_coming_soon);
    }
  }

  Future<void> _addLocalFolder() async {
    final String? picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: t.media_source_add_local_folder,
    );
    if (!mounted || picked == null || picked.isEmpty) return;

    final String norm = normalizeSourceRootPath(picked, transport: 'local');
    final List<MediaSourceRow> existing = _rows ?? const <MediaSourceRow>[];
    final bool dup = existing.any((MediaSourceRow r) => r.rootPath == norm);
    if (dup) {
      HibikiToast.show(msg: norm);
      return;
    }

    final int nextOrder = existing.isEmpty
        ? 0
        : existing
                .map((MediaSourceRow r) => r.sortOrder)
                .reduce((int a, int b) => a > b ? a : b) +
            1;
    final int newId = await _db.insertMediaSource(
      MediaSourcesCompanion(
        label: Value(defaultLabelFromRoot(norm, transport: 'local')),
        mediaKind: Value(widget.mediaKind),
        transport: const Value('local'),
        rootPath: Value(norm),
        recursive: const Value(true),
        sortOrder: Value(nextOrder),
        createdAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    await _load();
    // 插入后立即扫描新行（拿回带 scanResult 的最新行刷新统计）。
    final MediaSourceRow? fresh = await _db.getMediaSourceById(newId);
    if (fresh != null) await _rescan(fresh);
  }

  /// 重新扫描一个来源：行级 loading → scanner.scan（内部吞异常写 lastScanError）→
  /// 重读该行刷新统计/时间/错误。
  Future<void> _rescan(MediaSourceRow row) async {
    if (_scanning.contains(row.id)) return;
    setState(() => _scanning.add(row.id));
    try {
      await MediaSourceScanner(_db).scan(row);
    } finally {
      final MediaSourceRow? updated = await _db.getMediaSourceById(row.id);
      if (mounted) {
        setState(() {
          _scanning.remove(row.id);
          final List<MediaSourceRow>? rows = _rows;
          if (rows != null && updated != null) {
            final int idx =
                rows.indexWhere((MediaSourceRow r) => r.id == row.id);
            if (idx >= 0) rows[idx] = updated;
          }
        });
      }
    }
  }

  /// 打开来源根目录（仅 Windows，复用仓库唯一现成的 explorer 调用）。
  Future<void> _openFolder(MediaSourceRow row) async {
    if (!Platform.isWindows) return;
    try {
      await Process.run('explorer', <String>[row.rootPath]);
    } catch (_) {
      // 打开失败不致命（路径可能已不存在）；静默即可。
    }
  }

  /// 移除来源：确认对话框强调移除来源不会删除已导入的媒体（FK setNull 自动
  /// 把归属媒体的 source_id 归 NULL，条目保留）→ 确认则 deleteMediaSource → 刷新。
  Future<void> _remove(MediaSourceRow row) async {
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
    await _load();
  }
}

/// 添加来源的两个 case：本地文件夹 / 网络（M1c 占位）。
enum _AddSourceChoice { local, network }
