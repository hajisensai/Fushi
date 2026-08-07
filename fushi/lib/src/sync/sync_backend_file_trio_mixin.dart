import 'package:fushi/src/sync/ttu_models.dart';

/// 共享 [SyncBackend] 家族 7 个后端（ftp/sftp/webdav/dropbox/onedrive/
/// hibiki_client + GoogleDriveHandler）的 progress/statistics/audioBook **读取**
/// 三件套。原本每个后端逐字重复三个 get* 方法，唯一区别是取回已解码 JSON 用的传输
/// 原语。此处把三个 get* 实现一次，各后端只保留一个 [readJsonById] 原语。
///
/// 只合并**读取**：写入三件套（updateProgressFile/updateStatsFile/
/// updateAudioBookFile）在各后端真实分叉——上传/删除**次序**不同（webdav/ftp/
/// dropbox/onedrive 是 upload-then-delete，HBK-AUDIT-048；sftp/hibiki_client 是
/// delete-then-upload），加锁前置也不同（ftp 走 `_opLock.withLock`、sftp 走
/// `_guarded` 且删除要 SFTP 连接句柄、GoogleDriveHandler 是合并单调用
/// `_uploadJson(fileId:)`）。弥合这些差异需要 3 个以上钩子会看不懂，故写入侧保留
/// 各后端 override，绝不在此悄悄统一次序。
///
/// 无 `on` 约束，因此非 [SyncBackend] 子类的 [GoogleDriveHandler] 也能 mix in。
mixin SyncBackendFileTrioMixin {
  /// 取回 [fileId] 指向的已解码 JSON（`Map` 或 `List`）。各后端用自己的下载原语实现
  /// （webdav/hibiki_client=`_ops!.downloadJson`、ftp/sftp/gdrive=`_downloadJson`、
  /// dropbox=`_downloadFileJson`、onedrive=`_downloadItemJson`）。
  Future<Object?> readJsonById(String fileId);

  Future<TtuProgress> getProgressFile(String fileId) async {
    final json = await readJsonById(fileId);
    return TtuProgress.fromJson(json as Map<String, dynamic>);
  }

  Future<List<TtuStatistics>> getStatsFile(String fileId) async {
    final json = await readJsonById(fileId);
    return (json as List)
        .cast<Map<String, dynamic>>()
        .map(TtuStatistics.fromJson)
        .toList();
  }

  Future<TtuAudioBook> getAudioBookFile(String fileId) async {
    final json = await readJsonById(fileId);
    return TtuAudioBook.fromJson(json as Map<String, dynamic>);
  }
}
