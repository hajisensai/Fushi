import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/asr_host/asr_model_catalog.dart';
import 'package:fushi/src/media/audiobook/asr_transcribe_sheet.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 设置区「语音识别模型」组的正文（隶属**听**设置分类）。
///
/// 一个包一行（当前注册表 `asrModelRegistry.packs`，含用户自带包）：标题 = 模型名，
/// 副标题 = 语言 + 状态
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

/// 设置页要列出来的包：本仓基础清单 + 用户手动接入的包，按 id 去重。
///
/// **不读 `asrModelRegistry.packs`**：给某语言换模型时，注册表最前面会多一份
/// 「只声明那一种语言」的窄包（见 `asr_model_catalog.dart` 文件头），它与原包同
/// id。按 id 取第一个就会把 Omnilingual 那行的语言列表从「德语 · 西语 · 法语 …」
/// 缩成只剩「日本語」，而这一行的副标题本来就是要把它服务的语言全列出来。
List<AsrModelPack> _listedPacks() {
  final List<AsrModelPack> out = <AsrModelPack>[];
  final Set<String> seen = <String>{};
  final Map<String, AsrModelPack> custom = <String, AsrModelPack>{
    for (final AsrModelPack pack in asrModelCatalog.customPacks) pack.id: pack,
  };
  for (final AsrModelPack pack in fushiAsrBasePacks()) {
    if (seen.add(pack.id)) out.add(custom[pack.id] ?? pack);
  }
  for (final AsrModelPack pack in asrModelCatalog.customPacks) {
    if (seen.add(pack.id)) out.add(pack);
  }
  return out;
}

class _AsrModelsSettingsSectionState extends State<AsrModelsSettingsSection> {
  late List<_PackRow> _rows = <_PackRow>[
    // 读注册表而不是内置常量表：用户自带的包与「给某语言换了模型」都只体现在
    // 注册表里，照着 kAsrModelPacks 画会让自带模型在设置页整个不可见。
    for (final AsrModelPack pack in _listedPacks()) _PackRow(pack),
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

  /// 移除一个手动接入的本地模型：只改目录，不动用户的文件。
  Future<void> _detach(_PackRow row) async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => FushiAlertDialog(
        title: Text(t.audiobook_transcribe_model_custom_detach),
        content: Text(t.audiobook_transcribe_model_custom_detach_hint),
        actions: <Widget>[
          FushiTextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          FushiFilledButton(
            key: ValueKey<String>('asr-models-detach-confirm-${row.pack.id}'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.audiobook_transcribe_model_custom_detach),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await saveAsrModelCatalog(
      asrModelCatalog.withoutCustomPack(row.pack.id),
    );
    if (!mounted) return;
    await row.cancelDownload();
    setState(() {
      _rows = <_PackRow>[
        for (final AsrModelPack pack in _listedPacks()) _PackRow(pack),
      ];
    });
    for (final _PackRow fresh in _rows) {
      unawaited(_refresh(fresh));
    }
  }

  Future<void> _confirmDelete(_PackRow row) async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => FushiAlertDialog(
        title: Text(t.asr_models_delete_confirm_title),
        content: Text(t.asr_models_delete_confirm_message),
        actions: <Widget>[
          FushiTextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          FushiFilledButton(
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
    // 多语言包（Omnilingual）把它服务的语言全列出来。
    final String language =
        row.pack.languages.map(asrLanguageLabel).join(' · ');
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

  Widget _actions(_PackRow row) {
    final AsrTranscribePlan? plan = row.plan;
    if (row.loading || plan == null) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: FushiCircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (row.downloading) {
      return FushiTextButton(
        key: ValueKey<String>('asr-models-cancel-${row.pack.id}'),
        onPressed: () => unawaited(_cancelDownload(row)),
        child: Text(t.dialog_cancel),
      );
    }
    final AsrModelStatus status = plan.modelStatus;
    // 手动接入的本地模型：它的「模型目录」就是用户自己的文件夹，`deleteAll()`
    // 会把用户的模型文件真删掉。所以这里给的是「移除接入」——只从目录里去掉这个
    // 包（连同指向它的选择），文件一个不碰。
    if (localAsrModelDirectory(row.pack) != null) {
      return FushiOutlinedButton.icon(
        key: ValueKey<String>('asr-models-detach-${row.pack.id}'),
        onPressed: row.deleting ? null : () => unawaited(_detach(row)),
        icon: const FushiIcon(FushiIcons.linkOff, size: 18),
        label: Text(t.audiobook_transcribe_model_custom_detach),
      );
    }
    final Widget delete = FushiOutlinedButton.icon(
      key: ValueKey<String>('asr-models-delete-${row.pack.id}'),
      onPressed: row.deleting ? null : () => unawaited(_confirmDelete(row)),
      icon: row.deleting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: FushiCircularProgressIndicator(strokeWidth: 2),
            )
          : const FushiIcon(FushiIcons.delete, size: 18),
      label: Text(t.asr_models_delete),
    );
    if (status.ready) return delete;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        FushiFilledButton.icon(
          key: ValueKey<String>('asr-models-download-${row.pack.id}'),
          onPressed: row.deleting ? null : () => _startDownload(row),
          icon: const FushiIcon(FushiIcons.download, size: 18),
          label: Text(t.asr_models_download),
        ),
        // 不全但磁盘上有残留（中断的 `.part`、另一变体的编码器）也得能清掉。
        if (status.hasAnyFiles) delete,
      ],
    );
  }

  /// 状态徽标（M3E tonal 色块）：已就绪 / 下载中 / 下载了一部分 / 未下载 /
  /// 查询失败。
  Widget _statusBadge(_PackRow row) {
    final AsrModelStatus? status = row.plan?.modelStatus;
    final (String text, IconData icon, FushiTagTone tone) = row.downloading
        ? (
            t.manga_panel_model_downloading,
            FushiIcons.downloading,
            FushiTagTone.accent,
          )
        : status == null
            ? (
                t.download_task_status_error,
                FushiIcons.error,
                FushiTagTone.error,
              )
            : status.ready
                ? (
                    t.manga_panel_model_ready,
                    FushiIcons.downloadDone,
                    FushiTagTone.success,
                  )
                : status.obtainedBytes > 0
                    ? (
                        t.asr_models_badge_partial,
                        FushiIcons.pending,
                        FushiTagTone.warning,
                      )
                    : (
                        t.manga_panel_model_missing,
                        FushiIcons.cloudDownload,
                        FushiTagTone.neutral,
                      );
    return FushiTag(
      key: ValueKey<String>('asr-models-status-${row.pack.id}'),
      text: text,
      icon: icon,
      tone: tone,
      dense: true,
    );
  }

  /// 一个模型包一张分段卡：行首形状图标（就绪 = tertiary 实心勾、其余
  /// secondary 语音）+ 名称 + 状态徽标；下一行语言 · 体积；下载中出波浪进度；
  /// 底部动作。
  Widget _row(BuildContext context, _PackRow row) {
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    final AsrModelStatus? status = row.plan?.modelStatus;
    final bool ready = status?.ready ?? false;
    final bool showStatusBadge = !row.loading || row.downloading;
    return Padding(
      key: ValueKey<String>('asr-models-row-${row.pack.id}'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              FushiListLeadingIcon(
                ready
                    ? FushiIcons.filled(FushiIcons.success)
                    : FushiIcons.voice,
                shape: row.downloading
                    ? FushiLeadingShape.cookie
                    : FushiLeadingShape.circle,
                tone: ready
                    ? FushiCardTone.tertiary
                    : row.downloading
                        ? FushiCardTone.primary
                        : FushiCardTone.secondary,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            row.pack.displayName,
                            style: type.titleMediumEmphasized,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (showStatusBadge) ...<Widget>[
                          const SizedBox(width: 8),
                          _statusBadge(row),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _subtitle(row),
                      style: type.bodyMedium.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          AnimatedSize(
            duration: motion.spatialDefault.duration,
            curve: motion.spatialDefault.curve,
            alignment: Alignment.topCenter,
            child: row.downloading
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        FushiLinearProgressIndicator(
                          value: row.downloadTotal > 0
                              ? (row.downloadReceived / row.downloadTotal)
                                  .clamp(0.0, 1.0)
                              : null,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          t.audiobook_transcribe_model_downloading(
                            name: row.downloadFile,
                            received:
                                FushiByteFormat.bytes(row.downloadReceived),
                            total: FushiByteFormat.bytes(row.downloadTotal),
                          ),
                          style: type.bodySmall.tabular.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 56),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: _actions(row),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 透明 Material：cupertino 桌面嵌入渲染下设置正文没有 Material 祖先，而本组
    // 含按钮墨水。
    return Material(
      type: MaterialType.transparency,
      child: FushiEntranceScope(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
            vertical: 8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 分段卡（首尾大圆角、行间 2）整张错峰进场。
              for (int i = 0; i < _rows.length; i++)
                FushiStaggeredEntrance(
                  key: ValueKey<String>('asr-models-entry-${_rows[i].pack.id}'),
                  index: i,
                  child: FushiGroupedListItem(
                    index: i,
                    count: _rows.length,
                    child: _row(context, _rows[i]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
