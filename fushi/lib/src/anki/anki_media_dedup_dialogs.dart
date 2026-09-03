/// Anki 媒体去重的共享弹窗：设置页的手动路径与启动自动处理路径**共用同一份**
/// 干跑清单 / 结果报告 / 进度对话框 UI。
///
/// 抽出来的根因：自动处理开关加回来之后，「自动干跑 → 提示 → 用户确认才真删」
/// 必须复用手动路径那个逐条列出「删哪些文件、各占多少空间、保留哪一份」的
/// 确认弹窗。两份 UI 会漂移，漂移的那一份迟早变成「自动路径绕过确认」。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fushi/src/anki/anki_media_dedup_runner.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 带模态进度对话框跑一轮去重（BUG-1263）。
///
/// 扫描与真删都是分钟级长任务（每个副本至少两次全库检索 + 逐条改写，全部
/// 串行打到 Anki 主线程）；这里统一给出「阶段 + 计数 + 当前文件 + 已释放
/// 空间」的进度与取消入口。设置页手动路径与首页自动确认路径共用本函数，
/// 防两份进度 UI 漂移。
///
/// 取消在副本边界干净生效，返回报告的 `cancelled == true` 时数字只覆盖已
/// 完成部分。异常原样上抛（怎么提示由调用方定），上抛前保证进度弹窗已关。
Future<AnkiMediaDedupReport?> runAnkiMediaDedupWithProgress(
  BuildContext context,
  AnkiMediaDedupRunner runner, {
  required bool dryRun,
}) async {
  final ValueNotifier<AnkiMediaDedupProgress?> progress =
      ValueNotifier<AnkiMediaDedupProgress?>(null);
  final ValueNotifier<bool> cancelRequested = ValueNotifier<bool>(false);
  BuildContext? dialogContext;
  bool dialogClosed = false;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) {
      dialogContext = ctx;
      return PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(t.anki_dedup_progress_title),
          content: SizedBox(
            width: 420,
            child: _AnkiMediaDedupProgressBody(
              progress: progress,
              dryRun: dryRun,
            ),
          ),
          actions: [
            // 后端不支持中途叫停（整轮在主机进程里跑）时**不画**取消按钮：
            // 一个点了没反应的取消按钮比没有更糟，用户会以为已经停了。
            if (runner.supportsProgress)
              ValueListenableBuilder<bool>(
                valueListenable: cancelRequested,
                builder:
                    (BuildContext context, bool requested, Widget? child) =>
                        TextButton(
                  onPressed:
                      requested ? null : () => cancelRequested.value = true,
                  child: Text(
                      requested ? t.anki_dedup_cancelling : t.dialog_cancel),
                ),
              ),
          ],
        ),
      );
    },
  ).then((void _) => dialogClosed = true));
  try {
    return await runner.runNow(
      dryRun: dryRun,
      onProgress: (AnkiMediaDedupProgress p) => progress.value = p,
      shouldCancel: () => cancelRequested.value,
    );
  } finally {
    // 弹窗路由是同步入栈的，但 builder 要到下一帧才跑：任务瞬间结束（后端
    // 不支持 → null）时 dialogContext 可能还是 null，等一帧再关，绝不留下
    // 一个关不掉的模态遮罩。
    if (!dialogClosed && dialogContext == null) {
      await WidgetsBinding.instance.endOfFrame;
    }
    final BuildContext? ctx = dialogContext;
    if (!dialogClosed && ctx != null && ctx.mounted) {
      Navigator.of(ctx).pop();
    }
  }
}

/// 进度弹窗正文：阶段行 + 进度条 + 当前文件 + （真删时）已释放空间。
class _AnkiMediaDedupProgressBody extends StatelessWidget {
  const _AnkiMediaDedupProgressBody({
    required this.progress,
    required this.dryRun,
  });

  final ValueListenable<AnkiMediaDedupProgress?> progress;
  final bool dryRun;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AnkiMediaDedupProgress?>(
      valueListenable: progress,
      builder:
          (BuildContext context, AnkiMediaDedupProgress? p, Widget? child) {
        // scanning 阶段总量未知，走不定型进度条。
        final double? value = (p != null &&
                p.stage != AnkiMediaDedupStage.scanning &&
                p.total > 0)
            ? p.done / p.total
            : null;
        final String line;
        if (p == null || p.stage == AnkiMediaDedupStage.scanning) {
          line = t.anki_dedup_progress_scanning(count: '${p?.done ?? 0}');
        } else if (p.stage == AnkiMediaDedupStage.hashing) {
          line = t.anki_dedup_progress_hashing(
              done: '${p.done}', total: '${p.total}');
        } else {
          line = t.anki_dedup_progress_resolving(
              done: '${p.done}', total: '${p.total}');
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: value),
            const SizedBox(height: 12),
            Text(line),
            if (p?.currentFile != null) ...[
              const SizedBox(height: 4),
              Text(
                p!.currentFile!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (!dryRun && (p?.bytesFreed ?? 0) > 0) ...[
              const SizedBox(height: 4),
              Text(t.anki_dedup_progress_freed(
                  size: formatAnkiMediaDedupBytes(p!.bytesFreed))),
            ],
          ],
        );
      },
    );
  }
}

/// 干跑清单弹窗。[offerDelete] = 提供「删除这些文件」确认按钮（返回 true 才
/// 执行真删）；false 时只是只读报告。没有可删的东西时不给删除按钮。
Future<bool> showAnkiMediaDedupPlanDialog(
  BuildContext context,
  AnkiMediaDedupReport plan, {
  required bool offerDelete,
}) async {
  if (plan.deletions.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t.anki_dedup_plan_title),
        content: Text(t.anki_dedup_report_clean),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t.dialog_ok),
          ),
        ],
      ),
    );
    return false;
  }
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(t.anki_dedup_plan_title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.anki_dedup_plan_intro(
                count: '${plan.duplicatesRemoved}',
                size: formatAnkiMediaDedupBytes(plan.bytesSaved),
              )),
              const SizedBox(height: 12),
              for (final MediaDedupDeletion d in plan.deletions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(t.anki_dedup_plan_entry(
                    file: d.filename,
                    size: formatAnkiMediaDedupBytes(d.bytes),
                    canonical: d.canonical,
                  )),
                ),
              const SizedBox(height: 12),
              Text(offerDelete
                  ? t.anki_dedup_plan_journal
                  : t.anki_dedup_report_dry_note),
              if (offerDelete) ...[
                const SizedBox(height: 8),
                // BUG-1263：AnkiConnect 在 Anki 主线程执行，真删期间 Anki
                // 会被串行请求占满——提前告知，避免用户以为 Anki 坏了。
                Text(t.anki_dedup_plan_busy_note),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (!offerDelete)
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.dialog_ok),
          ),
        if (offerDelete) ...[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.anki_dedup_plan_delete),
          ),
        ],
      ],
    ),
  );
  return ok == true;
}

/// 真跑之后的结果报告。取消的轮在正文最前面说明「数字只覆盖已完成部分」。
Future<void> showAnkiMediaDedupReportDialog(
  BuildContext context,
  AnkiMediaDedupReport result,
) async {
  final String body = result.groupCount == 0
      ? t.anki_dedup_report_clean
      : t.anki_dedup_report_body(
          groups: '${result.groupCount}',
          removed: '${result.duplicatesRemoved}',
          size: formatAnkiMediaDedupBytes(result.bytesSaved),
          notes: '${result.notesRewritten}',
          models: '${result.modelsRewritten}',
          skipped: '${result.skipped}',
        );
  final String full = result.cancelled
      ? '${t.anki_dedup_report_cancelled_note}\n\n$body'
      : body;
  await showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(t.anki_dedup_report_title),
      content: Text(full),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_ok),
        ),
      ],
    ),
  );
}

/// 字节数 → 人类可读（B / KB / MB）。
String formatAnkiMediaDedupBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}
