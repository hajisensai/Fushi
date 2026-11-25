import 'dart:async';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/storage/storage_usage_service.dart'
    show formatStorageBytes;
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 已有一次「检查数据库」在跑（界面与控制通道共用同一把锁）。
class DatabaseCheckAlreadyRunningException implements Exception {
  const DatabaseCheckAlreadyRunningException();

  @override
  String toString() =>
      'DatabaseCheckAlreadyRunningException: '
      'a database check is already running';
}

Future<DatabaseCheckReport>? _inFlight;

/// 是否正有一次「检查数据库」在跑。
bool get isAppDatabaseCheckRunning => _inFlight != null;

/// 对本机主库跑一遍「检查数据库」（反馈 s2fdTTmLyh）。备份落在主库旁边，名字由
/// [databaseCheckBackupFileName] 给出（存储页「数据库备份快照」能列出 / 删除）。
/// 同一时刻只允许一次：已在跑时抛 [DatabaseCheckAlreadyRunningException]。
Future<DatabaseCheckReport> runAppDatabaseCheck(
  final AppModel appModel, {
  final void Function(DatabaseCheckPhase phase)? onPhase,
}) {
  if (_inFlight != null) {
    return Future<DatabaseCheckReport>.error(
      const DatabaseCheckAlreadyRunningException(),
    );
  }
  final String dir = appModel.databaseDirectory.path;
  final Future<DatabaseCheckReport> run = runDatabaseCheck(
    appModel.database,
    dbPath: p.join(dir, fushiDatabaseFileName),
    backupPath: p.join(
      dir,
      databaseCheckBackupFileName(DateTime.now().millisecondsSinceEpoch),
    ),
    onPhase: onPhase,
  );
  _inFlight = run;
  return run.whenComplete(() => _inFlight = null);
}

/// 阶段的界面文案。
String databaseCheckPhaseLabel(final DatabaseCheckPhase phase) =>
    switch (phase) {
      DatabaseCheckPhase.integrity => t.storage_db_check_phase_integrity,
      DatabaseCheckPhase.backup => t.storage_db_check_phase_backup,
      DatabaseCheckPhase.repair => t.storage_db_check_phase_repair,
      DatabaseCheckPhase.compact => t.storage_db_check_phase_compact,
      DatabaseCheckPhase.verify => t.storage_db_check_phase_verify,
    };

/// 结果对话框里的逐行说明（顺序即显示顺序）。纯函数，便于测试。
List<String> databaseCheckReportLines(final DatabaseCheckReport report) {
  final int found = report.problemsFound.length;
  final int remaining = report.problemsRemaining.length;
  final String? failedPhase = report.failedPhase == null
      ? null
      : databaseCheckPhaseLabel(report.failedPhase!);
  return <String>[
    if (remaining > 0)
      t.storage_db_check_integrity_bad(n: remaining)
    else if (found > 0)
      t.storage_db_check_integrity_fixed(n: found)
    else
      t.storage_db_check_integrity_ok,
    // 问题原文只列前几条：够看出病情，又不把对话框撑爆。
    for (final String problem in report.problemsRemaining.take(5)) '· $problem',
    if (report.repairedRows > 0)
      t.storage_db_check_repaired_rows(n: report.repairedRows)
    else if (report.failure == null && remaining == 0)
      t.storage_db_check_no_repairs,
    t.storage_db_check_size(
      before: formatStorageBytes(report.sizeBeforeBytes),
      after: formatStorageBytes(report.sizeAfterBytes),
    ),
    if (failedPhase != null)
      t.storage_db_check_failed(
        phase: failedPhase,
        reason: report.failure ?? '',
      ),
    if (report.rolledBack) t.storage_db_check_rolled_back,
    if (report.backupPath != null)
      t.storage_db_check_backup_kept(
        size: formatStorageBytes(report.backupBytes ?? 0),
        path: report.backupPath!,
      ),
  ];
}

/// 设置 → 存储 →「检查数据库」：确认 → 进度对话框（逐阶段）→ 结果对话框。
Future<void> checkDatabaseFromSettings(final SettingsContext c) async {
  final BuildContext context = c.context;
  if (isAppDatabaseCheckRunning) {
    FushiToast.show(
      msg: t.storage_db_check_busy,
      severity: ToastSeverity.warning,
    );
    return;
  }
  final bool confirmed = await showFushiConfirmDialog(
    context: context,
    title: t.storage_db_check_title,
    message: t.storage_db_check_confirm_body,
    confirmLabel: t.storage_db_check_confirm_action,
    icon: FushiIcons.verified,
  );
  if (!confirmed || !context.mounted) return;

  final int total = DatabaseCheckPhase.values.length;
  final FushiProgressDialogHandle progress = showFushiProgressDialog(
    context: context,
    title: t.storage_db_check_running,
    initialProgress: 0,
  );
  final DatabaseCheckReport report;
  try {
    report = await runAppDatabaseCheck(
      c.appModel,
      onPhase: (DatabaseCheckPhase phase) {
        progress.progress.value = phase.index / total;
        progress.message.value = t.storage_db_check_step(
          current: phase.index + 1,
          total: total,
          phase: databaseCheckPhaseLabel(phase),
        );
      },
    );
  } on DatabaseCheckAlreadyRunningException {
    progress.close();
    FushiToast.show(
      msg: t.storage_db_check_busy,
      severity: ToastSeverity.warning,
    );
    return;
  }
  progress.progress.value = 1;
  progress.close();
  await progress.done;
  if (!context.mounted) return;
  await showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        DatabaseCheckResultDialog(report: report),
  );
}

/// 控制通道（`fushi_cli config run storage.db_check --yes`）：无交互跑一遍，回结构化
/// 报告。
Future<Object?> checkDatabaseForCli(final SettingsContext c) async =>
    (await runAppDatabaseCheck(c.appModel)).toJson();

/// 「检查数据库」结果对话框：逐行说明错峰进场；留有备份时给「删除备份」。
class DatabaseCheckResultDialog extends StatelessWidget {
  const DatabaseCheckResultDialog({required this.report, super.key});

  final DatabaseCheckReport report;

  @override
  Widget build(BuildContext context) {
    final List<String> lines = databaseCheckReportLines(report);
    final String? backupPath = report.backupPath;
    return FushiAlertDialog(
      icon: FushiDialogHeroIcon(
        icon: report.healthy ? FushiIcons.verified : FushiIcons.warning,
        tone: report.healthy
            ? FushiHeroTone.primary
            : FushiHeroTone.destructive,
      ),
      title: Text(
        report.healthy
            ? t.storage_db_check_result_ok_title
            : t.storage_db_check_result_problem_title,
      ),
      scrollable: true,
      content: FushiEntranceScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int i = 0; i < lines.length; i++)
              FushiStaggeredEntrance(
                index: i,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: SelectableText(lines[i]),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        if (backupPath != null)
          FushiDialogAction(
            label: t.storage_db_check_delete_backup,
            kind: FushiDialogActionKind.destructive,
            onPressed: () =>
                unawaited(_deleteBackupAndClose(context, backupPath)),
          ),
        FushiDialogAction(
          label: backupPath != null
              ? t.storage_db_check_keep_backup
              : t.dialog_ok,
          kind: FushiDialogActionKind.primary,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  static Future<void> _deleteBackupAndClose(
    final BuildContext context,
    final String backupPath,
  ) async {
    final NavigatorState navigator = Navigator.of(context);
    try {
      await File(backupPath).delete();
    } on FileSystemException catch (e) {
      // 删不掉（被占用 / 无权限）原样告诉用户；备份仍在存储页「数据库备份快照」里。
      FushiToast.show(
        msg: t.storage_entry_delete_failed(
          reason: e.osError?.message ?? e.message,
        ),
        severity: ToastSeverity.error,
      );
    }
    navigator.pop();
  }
}
