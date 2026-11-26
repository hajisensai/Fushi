/// 更新前还原点没保存成功时的一次性提示（设计
/// `docs/specs/2026-11-25-auto-backup-restore-points.md` 第一层「Never blocks startup」）。
///
/// 快照在开库时、迁移之前做，失败只记进 `restore_points/last_snapshot_status.<库>.json`、
/// 不挡启动；首页首帧读它，没提示过的失败弹一次。标记在弹框之前就标成已提示，
/// 弹框期间杀进程不会再弹。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 取出（并标成已提示）还没提示过的快照失败；没有返回 null。读写失败只记日志。
RestorePointSnapshotStatus? takeRestorePointFailureNotice(String dbDirectory) {
  try {
    final RestorePointStore store = RestorePointStore(dbDirectory);
    final List<RestorePointSnapshotStatus> failures = store
        .unacknowledgedFailures();
    if (failures.isEmpty) return null;
    for (final RestorePointSnapshotStatus s in failures) {
      store.acknowledgeLastStatus(s.database);
    }
    return failures.first;
  } catch (e, st) {
    ErrorLogService.instance.log('takeRestorePointFailureNotice', e, st);
    return null;
  }
}

/// 首页首帧调用：有没提示过的快照失败就弹一次。[databaseDirectory] = 活库目录（由首页传入，
/// 本文件不 import AppModel，不进 import 大环）。
Future<void> maybeShowRestorePointFailureNotice({
  required BuildContext context,
  required String databaseDirectory,
}) async {
  final RestorePointSnapshotStatus? failure = takeRestorePointFailureNotice(
    databaseDirectory,
  );
  if (failure == null || !context.mounted) return;
  await showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      key: const ValueKey<String>('restore_point_failure_notice'),
      icon: const FushiIcon(FushiIcons.history),
      title: Text(t.db_restore_point_snapshot_failed_title),
      content: Text(
        t.db_restore_point_snapshot_failed_body(
          error: failure.error == kNotEnoughSpaceError
              ? t.auto_backup_error_not_enough_space
              : failure.error ?? '?',
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          key: const ValueKey<String>('restore_point_failure_notice_ok'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(t.dialog_ok),
        ),
      ],
    ),
  );
}
