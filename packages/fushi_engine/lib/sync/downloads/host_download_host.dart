/// 互联 host 的「代下载」能力（设计 §3.3：下载 = 改变 host 的库）。
///
/// 客户端交一条磁链，host 用自己的下载管线（qBittorrent / 内置引擎）下到自己的
/// 库里；完成后经既有 `/api/library/videos` + `/stream` 消费。这里只定义接口与
/// wire 形状，实现在无头服务端（`packages/fushi_server`）——app 若日后也想当
/// 代下载 host，同样实现这个接口即可。
library;

import 'package:fushi_core/fushi_core.dart';

abstract interface class HostDownloadHost {
  /// `/api/capabilities` 的 `downloads` 字段。
  Future<Map<String, Object?>> capability();

  Future<List<VideoDownloadJobRow>> listJobs();

  /// 返回 jobId。[mediaKind] = `movie` | `tv`。
  Future<String> addMagnet({
    required String magnetUri,
    required String title,
    String mediaKind = 'movie',
  });

  Future<void> cancelJob(String jobId);

  Future<void> retryJob(String jobId);

  Future<void> deleteJob(String jobId);
}

/// 与 app 下载中心同一套字段名（`VideoDownloadJobLifecycle` / `VideoDownloadJobStage`
/// 的字符串值原样上线）。
Map<String, Object?> videoDownloadJobToWire(VideoDownloadJobRow row) =>
    <String, Object?>{
      'jobId': row.jobId,
      'title': row.title,
      'lifecycle': row.lifecycle,
      'stage': row.stage,
      'stageProgress': row.stageProgress,
      'priority': row.priority,
      'torrentHash': row.torrentHash,
      'mediaKind': row.mediaKind,
      if (row.lastError != null) 'lastError': row.lastError,
      'createdAt': row.createdAt,
      'updatedAt': row.updatedAt,
      if (row.completedAt != null) 'completedAt': row.completedAt,
    };
