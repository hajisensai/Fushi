/// 互联 host 的「代下载」能力（设计 §3.3：下载 = 改变 host 的库）。
///
/// 客户端交一条磁链（或一份 .torrent），host 用自己的下载管线（qBittorrent /
/// 内置引擎）下到自己的库里；完成后经既有 `/api/library/videos` + `/stream` 消费。
/// 这里只定义接口与 wire 形状；实现有两份：无头服务端 `ServerDownloadHost`（视频 +
/// 小说 / 漫画 / 有声书；没有游戏库，也接不了 PDF）与 app 当 host 的
/// `AppDownloadHost`（视频 + 发现页四个非视频域）。两边完成后都走引擎的
/// `DiscoveryImportExecutor` 按域入库，差别只在各自装配了哪些域原语。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart'
    show DiscoveryMediaKind;
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart'
    show VideoDownloadBackendTarget;
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadManualEnqueueRequest, VideoDownloadSubtitlePolicy;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataMediaKind;

/// `/api/downloads` POST 的 `discoveryKind` 可取值（`DiscoveryMediaKind.name`）。
/// 视频任务不带这个字段；host 在 `capability()['kinds']` 里宣告自己收哪些。
const Set<String> kHostDownloadDiscoveryKinds = <String>{
  'novel',
  'manga',
  'audiobook',
  'game',
};

/// 作品身份可直取的资料源（与刮削「可选主源」同一组）。
const Set<String> kHostDownloadMetadataProviders = <String>{
  'anidb',
  'mal',
  'tmdb',
};

abstract interface class HostDownloadHost {
  /// `/api/capabilities` 的 `downloads` 字段：`{supported, backend, kinds}`。
  /// `kinds` 是 `video` 加上 host 能按域入库的 [kHostDownloadDiscoveryKinds] 子集。
  Future<Map<String, Object?>> capability();

  Future<List<VideoDownloadJobRow>> listJobs();

  /// 投一条下载，返回 jobId。字段语义见 [HostDownloadAddRequest]。host 不收
  /// [HostDownloadAddRequest.discoveryKind] 那个域时抛 [ArgumentError]（路由映射成 400）。
  Future<String> add(HostDownloadAddRequest request);

  /// 任务的字幕行（`video_download_job_subtitles`）；任务不存在返回 null（路由 404）。
  Future<List<VideoDownloadJobSubtitleRow>?> listJobSubtitles(String jobId);

  Future<void> cancelJob(String jobId);

  Future<void> retryJob(String jobId);

  Future<void> deleteJob(String jobId);
}

/// `POST /api/downloads` 的请求（字段与校验见 [HostDownloadAddRequest.fromJson]）。
///
/// 老客户端只发 `magnet / title / mediaKind / discoveryKind`，其余字段缺省即旧行为。
class HostDownloadAddRequest {
  HostDownloadAddRequest({
    required this.title,
    this.magnetUri,
    this.metainfo,
    this.selectedFileIndexes,
    this.mediaKind = 'movie',
    this.discoveryKind,
    this.year,
    this.metadataProvider,
    this.externalId,
    this.subtitlePolicy,
  });

  /// 只有磁链的最简形状。
  HostDownloadAddRequest.magnet({
    required String this.magnetUri,
    required this.title,
    this.mediaKind = 'movie',
    this.discoveryKind,
  })  : metainfo = null,
        selectedFileIndexes = null,
        year = null,
        metadataProvider = null,
        externalId = null,
        subtitlePolicy = null;

  /// 解析并校验 wire JSON；不合法抛 [FormatException]（路由映射成 400，消息即原因）：
  ///
  /// * `magnet` 与 `torrent`（.torrent 文件字节的 base64）恰好给一个；
  /// * `files`（旧名 `fileIndexes` 照认）：只下载这些 metainfo 文件下标（要求
  ///   `torrent`，下标必须存在）；选中全部文件 = 整颗 torrent（管线
  ///   `enqueueManual` 统一降级，单文件种子传 `[0]` 同理）；
  /// * `year`：作品年份；
  /// * `metadataProvider` + `externalId`：成对给出，`anidb` | `mal` | `tmdb` + 正整数
  ///   id；入库后按这个身份直接刮削，不再按标题搜。只用于视频任务；
  /// * `subtitlePolicy`：`none` | `bestEffort` | `required`（缺省 none）。
  factory HostDownloadAddRequest.fromJson(Map<Object?, Object?> json) {
    String? str(String key) {
      final Object? v = json[key];
      if (v == null) return null;
      final String t = v.toString().trim();
      return t.isEmpty ? null : t;
    }

    final String? magnet = str('magnet');
    final String? torrent = str('torrent');
    if (magnet == null && torrent == null) {
      throw const FormatException('Missing magnet');
    }
    if (magnet != null && torrent != null) {
      throw const FormatException(
        'give either magnet or torrent, not both',
      );
    }
    final String? title = str('title');
    if (title == null) throw const FormatException('Missing title');
    InspectedTorrentMetainfo? metainfo;
    if (torrent != null) {
      final Uint8List bytes;
      try {
        bytes = base64Decode(torrent);
      } on FormatException {
        throw const FormatException(
          'torrent must be the base64 of a .torrent file',
        );
      }
      metainfo = inspectTorrentMetainfo(bytes);
    }
    final String mediaKind = str('mediaKind') ?? 'movie';
    if (mediaKind != 'movie' && mediaKind != 'tv') {
      throw const FormatException('mediaKind must be movie or tv');
    }
    final String? discoveryKind = str('discoveryKind');
    if (discoveryKind != null &&
        !kHostDownloadDiscoveryKinds.contains(discoveryKind)) {
      throw FormatException(
        'discoveryKind must be one of ${kHostDownloadDiscoveryKinds.join(', ')}',
      );
    }
    // `fileIndexes` 是 #2015 先上线的同义字段名（develop 预发布版的对端可能在发），
    // 照样认；两个都给时不猜哪个算数。
    if (json['files'] != null && json['fileIndexes'] != null) {
      throw const FormatException(
        'give either files or fileIndexes (legacy alias), not both',
      );
    }
    final Set<int>? files = _parseFileIndexes(
      json['files'] ?? json['fileIndexes'],
      metainfo,
    );
    final int? year = _parseYear(json['year']);
    final String? provider = str('metadataProvider')?.toLowerCase();
    final String? rawExternalId = str('externalId');
    if ((provider == null) != (rawExternalId == null)) {
      throw const FormatException(
        'metadataProvider and externalId must be given together',
      );
    }
    String? externalId;
    if (provider != null) {
      if (!kHostDownloadMetadataProviders.contains(provider)) {
        throw FormatException(
          'metadataProvider must be one of '
          '${kHostDownloadMetadataProviders.join(', ')}',
        );
      }
      final int? id = int.tryParse(rawExternalId!);
      if (id == null || id <= 0) {
        throw FormatException(
          'externalId must be a positive integer: $rawExternalId',
        );
      }
      externalId = '$id';
    }
    if (discoveryKind != null && (provider != null || year != null)) {
      throw const FormatException(
        'year / metadataProvider only apply to video tasks (no discoveryKind)',
      );
    }
    return HostDownloadAddRequest(
      title: title,
      magnetUri: magnet,
      metainfo: metainfo,
      selectedFileIndexes: files,
      mediaKind: mediaKind,
      discoveryKind: discoveryKind,
      year: year,
      metadataProvider: provider,
      externalId: externalId,
      subtitlePolicy: _parseSubtitlePolicy(str('subtitlePolicy')),
    );
  }

  final String title;
  final String? magnetUri;
  final InspectedTorrentMetainfo? metainfo;

  /// null = 整颗 torrent。
  final Set<int>? selectedFileIndexes;

  /// `movie` | `tv`；[discoveryKind] 非空时无意义。
  final String mediaKind;

  /// 非视频内容（[kHostDownloadDiscoveryKinds]）；null = 视频任务。
  final String? discoveryKind;
  final int? year;
  final String? metadataProvider;
  final String? externalId;

  /// null = 管线缺省（none）。
  final VideoDownloadSubtitlePolicy? subtitlePolicy;

  /// 交给 `VideoDownloadPipelineService.enqueueManual` 的请求（两个 host 实现共用）。
  VideoDownloadManualEnqueueRequest toEnqueueRequest({
    required VideoDownloadBackendTarget backendTarget,
    required DiscoveryMediaKind? discoveryKind,
    required int? targetSourceId,
  }) =>
      VideoDownloadManualEnqueueRequest(
        title: title,
        backendTarget: backendTarget,
        magnetUri: magnetUri,
        metainfo: metainfo,
        selectedFileIndexes: selectedFileIndexes,
        metadataProvider: metadataProvider,
        externalId: externalId,
        year: year,
        discoveryKind: discoveryKind,
        mediaKind: mediaKind == 'tv'
            ? VideoMetadataMediaKind.tv
            : VideoMetadataMediaKind.movie,
        targetSourceId: targetSourceId,
        subtitlePolicy: subtitlePolicy ?? VideoDownloadSubtitlePolicy.none,
      );
}

Set<int>? _parseFileIndexes(Object? raw, InspectedTorrentMetainfo? metainfo) {
  if (raw == null) return null;
  if (raw is! List || raw.isEmpty) {
    throw const FormatException(
      'files must be a non-empty list of file indexes',
    );
  }
  if (metainfo == null) {
    throw const FormatException(
      'files requires torrent (a magnet carries no file list)',
    );
  }
  final int count = metainfo.files.length;
  if (count == 0) {
    throw const FormatException(
      'this torrent exposes no stable file indexes (pure v2); download it whole',
    );
  }
  final Set<int> indexes = <int>{};
  for (final Object? value in raw) {
    final int? index = value is int ? value : null;
    if (index == null || index < 0 || index >= count) {
      throw FormatException(
        'file index $value is out of range 0..${count - 1}',
      );
    }
    indexes.add(index);
  }
  return indexes;
}

int? _parseYear(Object? raw) {
  if (raw == null) return null;
  final int? year = raw is int ? raw : int.tryParse('$raw'.trim());
  if (year == null || year < 1850 || year > 2200) {
    throw FormatException('year is not a plausible year: $raw');
  }
  return year;
}

VideoDownloadSubtitlePolicy? _parseSubtitlePolicy(String? name) {
  if (name == null) return null;
  final VideoDownloadSubtitlePolicy? policy =
      VideoDownloadSubtitlePolicy.values.asNameMap()[name];
  if (policy == null) {
    throw FormatException(
      'subtitlePolicy must be one of '
      '${VideoDownloadSubtitlePolicy.values.map((VideoDownloadSubtitlePolicy p) => p.name).join(', ')}',
    );
  }
  return policy;
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
      if (row.year != null) 'year': row.year,
      if (row.metadataProvider != null)
        'metadataProvider': row.metadataProvider,
      if (row.externalId != null) 'externalId': row.externalId,
      if (row.lastError != null) 'lastError': row.lastError,
      'createdAt': row.createdAt,
      'updatedAt': row.updatedAt,
      if (row.completedAt != null) 'completedAt': row.completedAt,
    };

/// `video_download_job_subtitles` 一行的 wire 形状
/// （`GET /api/downloads/<id>/subtitles`）。
Map<String, Object?> videoDownloadJobSubtitleToWire(
  VideoDownloadJobSubtitleRow row,
) =>
    <String, Object?>{
      'subtitleId': row.subtitleId,
      'provider': row.provider,
      'status': row.status,
      if (row.language != null) 'language': row.language,
      if (row.season != null) 'season': row.season,
      if (row.episode != null) 'episode': row.episode,
      if (row.originalFileName != null)
        'originalFileName': row.originalFileName,
      if (row.finalPath != null) 'finalPath': row.finalPath,
      if (row.error != null) 'error': row.error,
      'createdAt': row.createdAt,
      'updatedAt': row.updatedAt,
    };
