/// Anki 媒体去重的共享弹窗：设置页的手动路径与启动自动处理路径**共用同一份**
/// 干跑清单 / 结果报告 UI。
///
/// 抽出来的根因：自动处理开关加回来之后，「自动干跑 → 提示 → 用户确认才真删」
/// 必须复用手动路径那个逐条列出「删哪些文件、各占多少空间、保留哪一份」的
/// 确认弹窗。两份 UI 会漂移，漂移的那一份迟早变成「自动路径绕过确认」。
library;

import 'package:flutter/material.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

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

/// 真跑之后的结果报告。
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
  await showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(t.anki_dedup_report_title),
      content: Text(body),
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
