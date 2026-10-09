/// 互联 host 的「代下载」能力（设计 §3.3：下载 = 改变 host 的库）。
///
/// 客户端交一条磁链，host 用自己的下载管线（qBittorrent / 内置引擎）下到自己的
/// 库里；完成后经既有 `/api/library/videos` + `/stream` 消费。这里只定义接口与
/// wire 形状；实现有两份：无头服务端 `ServerDownloadHost`（视频 + 小说 / 漫画 /
/// 有声书；没有游戏库，也接不了 PDF）与 app 当 host 的 `AppDownloadHost`（视频 +
/// 发现页四个非视频域）。两边完成后都走引擎的 `DiscoveryImportExecutor` 按域入库，
/// 差别只在各自装配了哪些域原语。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart'
    show InspectedTorrentMetainfo;

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

  /// 交一份 `.torrent`（[metainfo]），只下其中 [fileIndexes] 那几个文件；null =
  /// 整个种子。磁链拿不到文件清单，「合集包里只要其中几部」只能走这里——否则只能
  /// 整包下完再删（158 GiB 的 25 部剧场版合集，只缺其中 14 部）。其余同 [addMagnet]；
  /// index 不在种子文件清单里时抛 [ArgumentError]（路由映射成 400）。
  Future<String> addTorrent({
    required InspectedTorrentMetainfo metainfo,
    Set<int>? fileIndexes,
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
