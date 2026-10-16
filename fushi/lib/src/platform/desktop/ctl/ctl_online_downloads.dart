/// online 域下载任务的应答形状（纯函数，便于单测）。
///
/// 在线源的两类下载不在下载中心的磁链 / 直链表里（那张表归 data 域的 `dl`）：
///
/// - 漫画章节 / mokuro 卷：`MangaDownloadService` 的任务表（`manga_download_jobs`，
///   下载页「漫画」分区）；
/// - 视频源剧集：app 级 [InterconnectDownloadManager] 的任务（下载页「扩展源」分区，
///   与互联设备 / 媒体服务器拉取共用这个管理器，`origin` 区分）。
library;

import 'package:fushi_core/fushi_core.dart'
    show LocalFileDeleteFailure, MangaDownloadJobRow;
import 'package:fushi_engine/media/video/video_book_repository.dart'
    show VideoBookDeleteFailure;

import 'package:fushi/src/media/video/video_library_delete.dart'
    show VideoLibraryDeleteResult;
import 'package:fushi/src/sync/interconnect_download_manager.dart';

/// 删成品失败时给 CLI 的原因：库行删除失败 + 文件删除失败逐条列出。
String describeCtlVideoDeleteFailure(VideoLibraryDeleteResult? result) {
  if (result == null) return '未知原因';
  final List<String> reasons = <String>[
    for (final VideoBookDeleteFailure f in result.failed)
      '库行 ${f.bookUid}: ${f.error}',
    for (final LocalFileDeleteFailure f in result.localFiles.failures) '$f',
  ];
  return reasons.isEmpty ? '未知原因' : reasons.join('；');
}

/// 一条漫画下载任务。
Map<String, Object?> ctlMangaDownloadJobJson(MangaDownloadJobRow row) =>
    <String, Object?>{
      'id': row.jobId,
      'kind': row.kind,
      'bookKey': row.bookKey,
      'chapterKey': row.chapterKey,
      'runtime': row.runtime,
      'title': row.title,
      'chapter': row.chapterTitle,
      'status': row.status,
      'pagesDone': row.pagesDone,
      'pagesTotal': row.pagesTotal,
      'attempts': row.attemptCount,
      if (row.lastError != null) 'error': row.lastError,
      'autoOcr': row.autoOcr,
      'createdAt': row.createdAt,
      'updatedAt': row.updatedAt,
      if (row.completedAt != null) 'completedAt': row.completedAt,
    };

/// 一条剧集（互联下载管理器）任务；[canPause] / [canRestart] 是下载页按钮同一判据。
Map<String, Object?> ctlEpisodeDownloadTaskJson(
  InterconnectDownloadTask task, {
  required bool canPause,
  required bool canRestart,
}) => <String, Object?>{
  'id': task.id,
  'title': task.title,
  'status': task.status.name,
  'kind': task.kind.name,
  'origin': task.origin.name,
  'progress': task.progress,
  if (task.receivedBytes != null) 'receivedBytes': task.receivedBytes,
  if (task.totalBytes != null) 'totalBytes': task.totalBytes,
  if (task.startedAt != null) 'startedAt': task.startedAt,
  if (task.error != null) 'error': task.error,
  if (task.destPath != null) 'destPath': task.destPath,
  'canPause': canPause,
  'canResume': canRestart,
};
