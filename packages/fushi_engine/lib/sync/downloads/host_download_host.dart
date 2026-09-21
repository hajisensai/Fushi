/// 互联 host 的「代下载」能力（设计 §3.3：下载 = 改变 host 的库）。
///
/// 客户端交一条磁链，host 用自己的下载管线（qBittorrent / 内置引擎）下到自己的
/// 库里；完成后经既有 `/api/library/videos` + `/stream` 消费。这里只定义接口与
/// wire 形状；实现有两份：无头服务端 `ServerDownloadHost`（只收视频）与 app 当
/// host 的 `AppDownloadHost`（视频 + 发现页四个非视频域，完成后走 app 自己的
/// 发现导入执行器按域入库）。
library;

import 'package:fushi_core/fushi_core.dart';

/// `/api/downloads` POST 的 `discoveryKind` 可取值（`DiscoveryMediaKind.name`）。
/// 视频任务不带这个字段；host 在 `capability()['kinds']` 里宣告自己收哪些。
const Set<String> kHostDownloadDiscoveryKinds = <String>{
  'novel',
  'manga',
  'audiobook',
  'game',
};

abstract interface class HostDownloadHost {
  /// `/api/capabilities` 的 `downloads` 字段：`{supported, backend, kinds}`。
  /// `kinds` 是 `video` 加上 host 能按域入库的 [kHostDownloadDiscoveryKinds] 子集。
  Future<Map<String, Object?>> capability();

  Future<List<VideoDownloadJobRow>> listJobs();

  /// 返回 jobId。[mediaKind] = `movie` | `tv`；[discoveryKind] 非空时是非视频
  /// 内容（[kHostDownloadDiscoveryKinds]），此时 [mediaKind] 无意义。host 不收
  /// 该域时抛 [ArgumentError]（路由映射成 400）。
  Future<String> addMagnet({
    required String magnetUri,
    required String title,
    String mediaKind = 'movie',
    String? discoveryKind,
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
