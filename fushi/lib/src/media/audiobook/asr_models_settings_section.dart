import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/asr/asr_engine.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/asr/asr_model_store.dart';
import 'package:fushi/src/asr/asr_transcription_service.dart';
import 'package:fushi/src/media/audiobook/asr_transcribe_sheet.dart';
import 'package:fushi/src/onnx/model_file_downloader.dart';
import 'package:fushi/utils.dart';

/// 设置区「语音识别模型」组的正文（隶属**听**设置分类）。
///
/// 一语言一行（[kAsrModelPacks]）：标题 = 模型名，副标题 = 语言 + 状态
/// （已下载·占用 / 下载了一部分·已得/总 / 未下载·需要多少），行尾 下载（下载中
/// 变成进度条 + 取消）/ 删除（二次确认，报释放字节）。变体取自
/// [AsrTranscriptionService.plan] 的 `auto` 推荐——与转录弹层默认会下的那一套
/// 一致，用户在这里预先备好的模型到弹层里就是「模型就绪」。
///
/// 服务经构造参数注入，最小 widget 测试注 fake；真实接线在
/// `settings_schema_listening.dart`。
class AsrModelsSettingsSection extends StatefulWidget {
  const AsrModelsSettingsSection({required this.service, super.key});

  final AsrTranscriptionService service;

  @override
  State<AsrModelsSettingsSection> createState() =>
      _AsrModelsSettingsSectionState();
}

/// 一行（一个语言包）的运行态。
class _PackRow {
  _PackRow(this.pack);

  final AsrModelPack pack;
  AsrTranscribePlan? plan;
  bool loading = true;
  bool deleting = false;

  // 下载态：按「之前文件的总量 + 当前文件已收」累计成整包进度（与转录弹层同一
  // 套算法：下载器事件是逐文件 0→100% 的，直接照搬进度条会来回跑好几趟）。
  StreamSubscription<ModelDownloadEvent>? downloadSub;
  int downloadReceived = 0;
  int downloadTotal = 0;
  String downloadFile = '';

  bool get downloading => downloadSub != null;

  /// 取消进行中的下载订阅（没有则无事）。已落盘的 `.part` 留着，下次「下载」
  /// 由下载器 Range 续上。
  Future<void> cancelDownload() async {
    await downloadSub?.cancel();
    downloadSub = null;
  }
}

class _AsrModelsSettingsSectionState extends State<AsrModelsSettingsSection> {
  late final List<_PackRow> _rows = <_PackRow>[
    for (final AsrModelPack pack in kAsrModelPacks) _PackRow(pack),
  ];

  @override
  void initState() {
    super.initState();
    for (final _PackRow row in _rows) {
      unawaited(_refresh(row));
    }
  }

  @override
  void dispose() {
    for (final _PackRow row in _rows) {
      unawaited(row.cancelDownload());
    }
    super.dispose();
  }

  Future<void> _refresh(_PackRow row) async {
    if (mounted) setState(() => row.loading = true);
    AsrTranscribePlan? plan;
    try {
      plan = await widget.service.plan(
        language: row.pack.language,
        preference: AsrAccelerationPreference.auto,
      );
    } catch (_) {
      plan = null;
    }
    if (!mounted) return;
    setState(() {
      row.plan = plan;
      row.loading = false;
    });
  }

  void _startDownload(_PackRow row) {
    final AsrTranscribePlan? plan = row.plan;
    if (plan == null || row.downloading) return;
    int completedBytes = 0;
    String lastFile = '';
    int lastFileTotal = 0;
    setState(() {
      row.downloadTotal = plan.modelStatus.totalBytes;
      row.downloadReceived = plan.modelStatus.obtainedBytes;
      row.downloadFile = '';
    });
    row.downloadSub = widget.service
        .downloadModel(language: row.pack.language, variant: plan.variant)
        .listen(
      (ModelDownloadEvent e) {
        if (e.fileName != lastFile) {
          completedBytes += lastFileTotal;
          lastFile = e.fileName;
          lastFileTotal = e.totalBytes;
        }
        if (!mounted) return;
        setState(() {
          row.downloadFile = e.fileName;
          row.downloadReceived = completedBytes + e.receivedBytes;
        });
      },
      onError: (Object e, StackTrace _) {
        row.downloadSub = null;
        if (!mounted) return;
        setState(() {});
        FushiToast.show(
          msg: t.asr_models_download_failed(error: '$e'),
          severity: ToastSeverity.error,
        );
        unawaited(_refresh(row));
      },
      onDone: () {
        row.downloadSub = null;
        if (!mounted) return;
        unawaited(_refresh(row));
      },
    );
    setState(() {});
  }

  Future<void> _cancelDownload(_PackRow row) async {
    await row.cancelDownload();
    if (!mounted) return;
    // 重查状态让副标题给出准数（已拿到手的 `.part` 字节算进「已下载一部分」）。
    await _refresh(row);
  }

  Future<void> _confirmDelete(_PackRow row) async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.asr_models_delete_confirm_title),
        content: Text(t.asr_models_delete_confirm_message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          FilledButton(
            key: ValueKey<String>('asr-models-delete-confirm-${row.pack.id}'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.asr_models_delete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => row.deleting = true);
    int freed = 0;
    try {
      final AsrModelStore store =
          await widget.service.modelStore(row.pack.language);
      freed = await store.deleteAll();
    } finally {
      if (mounted) setState(() => row.deleting = false);
    }
    if (!mounted) return;
    FushiToast.show(
      msg: t.asr_models_delete_done_freed(size: FushiByteFormat.bytes(freed)),
      severity: ToastSeverity.success,
    );
    await _refresh(row);
  }

  // ── 展示 ───────────────────────────────────────────────────────────────────

  /// 副标题：语言 + 状态（三态都给真实字节数）。
  String _subtitle(_PackRow row) {
    final String language = asrLanguageLabel(row.pack.language);
    final AsrModelStatus? status = row.plan?.modelStatus;
    if (status == null) return language;
    final String state = status.ready
        ? t.asr_models_status_ready(
            size: FushiByteFormat.bytes(status.diskBytes),
          )
        : status.obtainedBytes > 0
            ? t.asr_models_status_partial(
                obtained: FushiByteFormat.bytes(status.obtainedBytes),
                total: FushiByteFormat.bytes(status.totalBytes),
              )
            : t.asr_models_status_missing(
                size: FushiByteFormat.bytes(status.totalBytes),
              );
    return '$language · $state';
  }

  Widget _inset(Widget child) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
      ),
      child: child,
    );
  }

  Widget _actions(_PackRow row) {
    final AsrTranscribePlan? plan = row.plan;
    if (row.loading || plan == null) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (row.downloading) {
      return TextButton(
        key: ValueKey<String>('asr-models-cancel-${row.pack.id}'),
        onPressed: () => unawaited(_cancelDownload(row)),
        child: Text(t.dialog_cancel),
      );
    }
    final AsrModelStatus status = plan.modelStatus;
    final Widget delete = OutlinedButton.icon(
      key: ValueKey<String>('asr-models-delete-${row.pack.id}'),
      onPressed: row.deleting ? null : () => unawaited(_confirmDelete(row)),
      icon: row.deleting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.delete_outline, size: 18),
      label: Text(t.asr_models_delete),
    );
    if (status.ready) return delete;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        FilledButton.icon(
          key: ValueKey<String>('asr-models-download-${row.pack.id}'),
          onPressed: row.deleting ? null : () => _startDownload(row),
          icon: const Icon(Icons.download_outlined, size: 18),
          label: Text(t.asr_models_download),
        ),
        // 不全但磁盘上有残留（中断的 `.part`、另一变体的编码器）也得能清掉。
        if (status.hasAnyFiles) delete,
      ],
    );
  }

  Widget _row(ThemeData theme, _PackRow row) {
    final AsrModelStatus? status = row.plan?.modelStatus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdaptiveSettingsRow(
          key: ValueKey<String>('asr-models-row-${row.pack.id}'),
          title: row.pack.displayName,
          subtitle: _subtitle(row),
          icon: (status?.ready ?? false)
              ? Icons.check_circle_outline
              : Icons.download_outlined,
          showIcon: true,
          controlBelow: true,
          trailing: Align(
            alignment: Alignment.centerLeft,
            child: _actions(row),
          ),
        ),
        if (row.downloading) ...<Widget>[
          _inset(
            LinearProgressIndicator(
              value: row.downloadTotal > 0
                  ? (row.downloadReceived / row.downloadTotal).clamp(0.0, 1.0)
                  : null,
            ),
          ),
          const SizedBox(height: 4),
          _inset(
            Text(
              t.audiobook_transcribe_model_downloading(
                name: row.downloadFile,
                received: FushiByteFormat.bytes(row.downloadReceived),
                total: FushiByteFormat.bytes(row.downloadTotal),
              ),
              style: theme.textTheme.bodySmall,
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
    // 透明 Material：cupertino 桌面嵌入渲染下设置正文没有 Material 祖先，而本组
    // 含按钮墨水。
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final _PackRow row in _rows) _row(theme, row),
        ],
      ),
    );
  }
}
