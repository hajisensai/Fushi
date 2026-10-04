import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_local_model_labels.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_model_downloads.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi/utils.dart';

/// 「设置 › 存储 › 本机 OCR 模型」正文：**每个本机模型一行**，逐个下载 / 取消 /
/// 删除。
///
/// 漫画 OCR 设置里只管「用哪个」，那里的下载 / 删除只作用于当前选中的模型；换过
/// 模型的用户磁盘上会留着别的模型（经典 manga-ocr 一套约 470 MB），以前只能在存储总览里
/// 看见一个裸目录。这里把每个模型都摆出来。
///
/// 下载走全局 [MangaOcrModelDownloads]（与设置区同一份，离开页面照跑），删除走
/// [MangaOcrService.deleteModels] 原语——不裸删目录。服务按模型经 [serviceFor]
/// 注入，测试注 fake。
class MangaOcrModelsStorageSection extends ConsumerStatefulWidget {
  const MangaOcrModelsStorageSection({
    required this.serviceFor,
    this.models,
    super.key,
  });

  /// 取某个模型的服务（真实现 `createMangaOcrService(localModel: model)`）。
  final MangaOcrService Function(MangaOcrLocalModel model) serviceFor;

  /// 要列出的模型；null = 本平台可用的全部模型。
  final List<MangaOcrLocalModel>? models;

  @override
  ConsumerState<MangaOcrModelsStorageSection> createState() =>
      _MangaOcrModelsStorageSectionState();
}

class _ModelRow {
  _ModelRow(this.model, this.service);

  final MangaOcrLocalModel model;
  final MangaOcrService service;
  MangaOcrModelStatus? status;
  bool loading = true;
  bool deleting = false;
  bool wasDownloading = false;
}

class _MangaOcrModelsStorageSectionState
    extends ConsumerState<MangaOcrModelsStorageSection> {
  late final MangaOcrModelDownloads _downloads;
  late final List<_ModelRow> _rows;

  @override
  void initState() {
    super.initState();
    _downloads = ref.read(mangaOcrModelDownloadsProvider);
    _rows = <_ModelRow>[
      for (final MangaOcrLocalModel model
          in widget.models ?? platformMangaOcrLocalModels())
        _ModelRow(model, widget.serviceFor(model))
          ..wasDownloading = _downloads.isActive(model),
    ];
    _downloads.addListener(_onDownloadsChanged);
    for (final _ModelRow row in _rows) {
      unawaited(_loadStatus(row));
    }
  }

  @override
  void dispose() {
    // 只摘监听：下载在后台继续。
    _downloads.removeListener(_onDownloadsChanged);
    super.dispose();
  }

  void _onDownloadsChanged() {
    if (!mounted) return;
    setState(() {});
    for (final _ModelRow row in _rows) {
      final bool downloading = _downloads.isActive(row.model);
      if (row.wasDownloading && !downloading) unawaited(_loadStatus(row));
      row.wasDownloading = downloading;
    }
  }

  Future<void> _loadStatus(_ModelRow row) async {
    MangaOcrModelStatus? status;
    try {
      status = await row.service.modelStatus();
    } catch (_) {
      status = null;
    }
    if (!mounted) return;
    setState(() {
      row.status = status;
      row.loading = false;
    });
  }

  void _startDownload(_ModelRow row) {
    _downloads.start(row.model, row.service);
  }

  Future<void> _confirmDelete(_ModelRow row) async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => FushiAlertDialog(
        title: Text(t.manga_ocr_delete_confirm_title),
        content: Text(
          '${localModelLabel(row.model)}\n\n'
          '${t.manga_ocr_delete_confirm_message}',
        ),
        actions: <Widget>[
          FushiTextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          FushiFilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.manga_ocr_delete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => row.deleting = true);
    int freed = 0;
    try {
      freed = await row.service.deleteModels();
    } finally {
      if (mounted) setState(() => row.deleting = false);
    }
    if (!mounted) return;
    FushiToast.show(
      msg: freed > 0
          ? t.manga_ocr_delete_done_freed(size: FushiByteFormat.bytes(freed))
          : t.manga_ocr_delete_done,
      severity: ToastSeverity.success,
    );
    await _loadStatus(row);
  }

  String _subtitle(_ModelRow row) {
    final MangaOcrModelStatus? status = row.status;
    final MangaOcrModelDownloadProgress? progress = _downloads.progressOf(
      row.model,
    );
    final List<String> parts = <String>[];
    if (progress != null) {
      if (status != null && status.totalBytes > 0) {
        parts.add(
          t.manga_ocr_download_total_progress(
            done: FushiByteFormat.bytes(progress.receivedBytes),
            total: FushiByteFormat.bytes(status.totalBytes),
          ),
        );
      }
    } else if (status != null) {
      parts.add(
        status.allReady
            ? t.manga_ocr_model_status_ready
            : t.manga_ocr_model_status_missing,
      );
      if (status.hasAnyFiles) {
        parts.add(
          t.manga_ocr_model_disk_usage(
            size: FushiByteFormat.bytes(status.diskBytes),
          ),
        );
      }
      if (!status.allReady && status.totalBytes > 0) {
        parts.add(
          t.manga_ocr_model_download_size(
            size: FushiByteFormat.bytes(status.totalBytes),
          ),
        );
      }
    }
    parts.add(localModelDescription(row.model));
    return parts.join(' · ');
  }

  Widget _actions(_ModelRow row) {
    final MangaOcrModelStatus? status = row.status;
    final MangaOcrModelDownloadProgress? progress = _downloads.progressOf(
      row.model,
    );
    if (progress != null) {
      return FushiTextButton(
        key: ValueKey<String>('ocr-models-cancel-${row.model.key}'),
        onPressed: progress.cancelling
            ? null
            : () => unawaited(_downloads.cancel(row.model)),
        child: Text(t.dialog_cancel),
      );
    }
    if (row.loading || status == null) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: FushiCircularProgressIndicator(strokeWidth: 2),
      );
    }
    final Widget delete = FushiOutlinedButton.icon(
      key: ValueKey<String>('ocr-models-delete-${row.model.key}'),
      onPressed: row.deleting ? null : () => unawaited(_confirmDelete(row)),
      icon: row.deleting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: FushiCircularProgressIndicator(strokeWidth: 2),
            )
          : const FushiIcon(Icons.delete_outline, size: 18),
      label: Text(t.manga_ocr_delete),
    );
    if (status.allReady) return delete;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        FushiFilledButton.icon(
          key: ValueKey<String>('ocr-models-download-${row.model.key}'),
          onPressed: row.deleting ? null : () => _startDownload(row),
          icon: const FushiIcon(Icons.download_outlined, size: 18),
          label: Text(
            status.hasResumableDownload
                ? t.manga_ocr_download_resume
                : t.manga_ocr_download,
          ),
        ),
        // 不全但磁盘上有残留（中断的 `.part`、换档遗留）也得能清掉。
        if (status.hasAnyFiles) delete,
      ],
    );
  }

  Widget _row(_ModelRow row) {
    final MangaOcrModelDownloadProgress? progress = _downloads.progressOf(
      row.model,
    );
    final int total = row.status?.totalBytes ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdaptiveSettingsRow(
          key: ValueKey<String>('ocr-models-row-${row.model.key}'),
          title: localModelLabel(row.model),
          subtitle: _subtitle(row),
          icon: (row.status?.allReady ?? false)
              ? Icons.check_circle_outline
              : Icons.download_outlined,
          showIcon: true,
          controlBelow: true,
          trailing: Align(
            alignment: Alignment.centerLeft,
            child: _actions(row),
          ),
        ),
        if (progress != null) ...<Widget>[
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
            ),
            child: FushiLinearProgressIndicator(
              value: total <= 0
                  ? null
                  : (progress.receivedBytes / total).clamp(0.0, 1.0),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 透明 Material：cupertino 桌面嵌入渲染下设置正文没有 Material 祖先。
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(
              FushiDesignTokens.of(context).spacing.rowHorizontal,
              8,
              FushiDesignTokens.of(context).spacing.rowHorizontal,
              4,
            ),
            child: Text(
              t.storage_ocr_models_hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final _ModelRow row in _rows) _row(row),
        ],
      ),
    );
  }
}
