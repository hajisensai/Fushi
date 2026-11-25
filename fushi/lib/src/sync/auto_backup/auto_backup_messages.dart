/// 自动备份状态里错误码的界面文案（设置页告警行、失败提示共用）。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_status.dart';

/// [AutoBackupStatus.lastError] → 给用户看的原因：认识的错误码换成本地化文案，其余原样。
String autoBackupErrorText(String? error) => switch (error) {
  null => '',
  kAutoBackupErrorInterrupted => t.auto_backup_error_interrupted,
  kAutoBackupErrorFolderUnavailable => t.auto_backup_error_folder_unavailable,
  final String other => other,
};
