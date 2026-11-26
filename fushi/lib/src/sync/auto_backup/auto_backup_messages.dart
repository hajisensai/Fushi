/// 自动备份状态里错误码的界面文案（设置页告警行、失败提示、还原点页的副本操作共用）。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_controller.dart'
    show AutoBackupBusyException, autoBackupMirrorErrorCode;
import 'package:fushi/src/sync/auto_backup/auto_backup_status.dart';
import 'package:fushi/src/sync/auto_backup/backup_folder_mirror.dart';

/// 给用户看的原因。[error] 是状态里的错误码（[AutoBackupStatus.lastError] /
/// [AutoBackupMirrorStatus.error]）或副本操作抛出的异常：认识的错误码换成本地化文案，其余字符串原样；
/// 异常先经 [autoBackupMirrorErrorCode] 归成错误码（平台原文不上界面），正忙给「已有备份在跑」。
String autoBackupErrorText(Object? error) => switch (error) {
  null => '',
  final String code => _codeText(code),
  AutoBackupBusyException() => t.auto_backup_now_busy,
  final Object other => _codeText(autoBackupMirrorErrorCode(other)),
};

String _codeText(String code) => switch (code) {
  kAutoBackupErrorInterrupted => t.auto_backup_error_interrupted,
  kAutoBackupErrorFolderUnavailable => t.auto_backup_error_folder_unavailable,
  kBackupMirrorErrorNotFound => t.auto_backup_error_copy_not_found,
  kBackupMirrorErrorLocalIo => t.auto_backup_error_copy_local_io,
  kBackupMirrorErrorUnsupported => t.auto_backup_error_copy_unsupported,
  kBackupMirrorErrorRenamed => t.auto_backup_error_copy_renamed,
  kBackupMirrorErrorLoading => t.auto_backup_error_copy_loading,
  kBackupMirrorErrorFailed => t.auto_backup_error_copy_failed,
  kBackupMirrorErrorCloudAuth => t.auto_backup_error_cloud_auth,
  kBackupMirrorErrorCloudUnreachable => t.auto_backup_error_cloud_unreachable,
  kBackupMirrorErrorCloudQuota => t.auto_backup_error_cloud_quota,
  kBackupMirrorErrorCloudFailed => t.auto_backup_error_cloud_failed,
  kBackupMirrorErrorCloudNoService => t.auto_backup_cloud_no_service,
  kBackupMirrorErrorServerNoServer => t.auto_backup_server_no_server,
  final String other => other,
};
