/// 覆盖导入完成后的一次性提示（维护者 2026-11-16 拍板 pr3455 第 1 条「加」）。
///
/// 覆盖导入成功后，导入前的整份主库另存为覆盖前快照
/// （`BackupRestoreService.overwriteSnapshotPath`），保留
/// `BackupRestoreService.overwriteSnapshotRetention` 后在启动时自动删除。导入完成那一刻
/// app 马上重启，提示放不进导入遮罩；所以导入时落一个标记，重启后首页首帧消费它，
/// 告诉用户快照占多大、留到哪天、在哪里找回或提前删除。快照里没有当前库缺的东西
/// （例如全新安装导入推荐包，覆盖掉的是空库）时不提示。
library;

import 'package:fushi_engine/utils/misc/fushi_time_format.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/library_recovery_page.dart';
import 'package:fushi/src/storage/storage_usage_service.dart'
    show formatStorageBytes;
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 提示正文（纯函数，测试钉住）。入口路径的每一段都取界面上真实显示的标签
/// （设置 › 存储 › 恢复书库），改名时自动跟着变。
String overwriteSnapshotNoticeBody(OverwriteSnapshotPreview snapshot) =>
    t.backup_overwrite_snapshot_notice_body(
      size: formatStorageBytes(snapshot.sizeBytes),
      date: FushiTimeFormat.dayKey(snapshot.expiresAt),
      path: <String>[
        t.settings,
        t.settings_destination_storage,
        t.storage_recovery_title,
      ].join(' › '),
    );

/// 首页首帧调用：有待显示的提示就弹一次。标记在弹框之前已被消费
/// （`BackupRestoreService.takeOverwriteSnapshotNotice`），弹框期间杀进程不会再弹。
/// 读快照失败只记日志——提示只是告知，不能挡住启动。
Future<void> maybeShowOverwriteSnapshotNotice({
  required BuildContext context,
  required AppModel appModel,
}) async {
  final OverwriteSnapshotPreview? snapshot;
  try {
    snapshot = await BackupRestoreService.takeOverwriteSnapshotNotice(
      dbDirectory: appModel.databaseDirectory.path,
      liveDb: appModel.database,
    );
  } catch (e, st) {
    ErrorLogService.instance.log('maybeShowOverwriteSnapshotNotice', e, st);
    return;
  }
  if (snapshot == null || !context.mounted) return;
  await showOverwriteSnapshotNoticeDialog(
    context: context,
    appModel: appModel,
    snapshot: snapshot,
  );
}

/// 提示框本体：「知道了」，或直接打开「恢复书库」页。
Future<void> showOverwriteSnapshotNoticeDialog({
  required BuildContext context,
  required AppModel appModel,
  required OverwriteSnapshotPreview snapshot,
}) async {
  final bool? open = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      key: const ValueKey<String>('overwrite_snapshot_notice'),
      icon: const FushiIcon(FushiIcons.history),
      title: Text(t.backup_overwrite_snapshot_notice_title),
      content: Text(overwriteSnapshotNoticeBody(snapshot)),
      actions: <Widget>[
        FushiTextButton(
          key: const ValueKey<String>('overwrite_snapshot_notice_open'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(t.backup_overwrite_snapshot_notice_open),
        ),
        FushiTextButton(
          key: const ValueKey<String>('overwrite_snapshot_notice_ok'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(t.dialog_ok),
        ),
      ],
    ),
  );
  if (open != true || !context.mounted) return;
  await Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (BuildContext context) =>
          RestorePointsPage(appModel: appModel),
    ),
  );
}
