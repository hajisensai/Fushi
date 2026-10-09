/// video 域控制通道的纯函数部分（解析 / 短 id 暂存 / JSON 形状），与路由分开以便单测。
library;

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart'
    show VideoDiscoveryCategory;
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadSubtitlePolicy;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataMediaKind, VideoMetadataProviderKind, VideoMetadataWork;
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart'
    show VideoMetadataLookup;
import 'package:fushi_engine/media/video/metadata/video_scrape_pending_note.dart'
    show VideoScrapePendingNote;
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart'
    show kSelectableVideoMetadataProviders;
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart'
    show SourceScrapeIssue, SourceScrapeReport, VideoSourceScrapeProgress;

/// 计划器作品单元的稳定键（`VideoSourceScrapeWork.stableKey`）：`book:<uid>` 或
/// `collection:<id>`。CLI 的「作品 id」就是它——待确认队列、自动补刮、库页
/// 「重新刮削」都按它认作品，未刮出身份的作品也有。
sealed class CtlVideoWorkId {
  const CtlVideoWorkId();

  /// 解析 `book:<uid>` / `collection:<id>`；格式不对抛 400。
  factory CtlVideoWorkId.parse(String raw) {
    final String value = raw.trim();
    if (value.startsWith('book:') && value.length > 'book:'.length) {
      return CtlVideoBookWorkId(value.substring('book:'.length));
    }
    if (value.startsWith('collection:')) {
      final int? id = int.tryParse(value.substring('collection:'.length));
      if (id != null && id > 0) return CtlVideoCollectionWorkId(id);
    }
    throw CtlFailure.badRequest(
      '作品 id 格式不对：$raw（book:<uid> 或 collection:<id>，见 video works）',
    );
  }

  String get stableKey;
}

class CtlVideoBookWorkId extends CtlVideoWorkId {
  const CtlVideoBookWorkId(this.bookUid);

  final String bookUid;

  @override
  String get stableKey => 'book:$bookUid';
}

class CtlVideoCollectionWorkId extends CtlVideoWorkId {
  const CtlVideoCollectionWorkId(this.collectionId);

  final int collectionId;

  @override
  String get stableKey => 'collection:$collectionId';
}

/// `video scrape <target>`：纯数字 = 来源库（扫描根）id，其余按作品 id 解析。
sealed class CtlVideoScrapeTarget {
  const CtlVideoScrapeTarget();

  factory CtlVideoScrapeTarget.parse(String raw) {
    final int? sourceId = int.tryParse(raw.trim());
    if (sourceId != null) {
      if (sourceId <= 0) throw CtlFailure.badRequest('来源 id 必须为正整数：$raw');
      return CtlVideoSourceTarget(sourceId);
    }
    return CtlVideoWorkTarget(CtlVideoWorkId.parse(raw));
  }
}

class CtlVideoSourceTarget extends CtlVideoScrapeTarget {
  const CtlVideoSourceTarget(this.sourceId);

  final int sourceId;
}

class CtlVideoWorkTarget extends CtlVideoScrapeTarget {
  const CtlVideoWorkTarget(this.workId);

  final CtlVideoWorkId workId;
}

/// 手动指定 / 候选过滤可用的资料源：只收刮削白名单（AniDB / MAL / TMDB），
/// 历史 provider（Bangumi / AniList / Douban…）一律拒绝。
VideoMetadataProviderKind parseCtlVideoProvider(String raw) {
  final String name = raw.trim().toLowerCase();
  for (final VideoMetadataProviderKind kind
      in kSelectableVideoMetadataProviders) {
    if (kind.name == name) return kind;
  }
  throw CtlFailure.badRequest(
    '不支持的资料源：$raw（${kSelectableVideoMetadataProviders.map((VideoMetadataProviderKind k) => k.name).join(' | ')}）',
  );
}

/// `tv` / `movie` → 媒体形态；null = 交给协调器按作品形态推断。
VideoMetadataMediaKind? parseCtlVideoMediaKind(String? raw) {
  if (raw == null) return null;
  switch (raw.trim().toLowerCase()) {
    case 'tv':
      return VideoMetadataMediaKind.tv;
    case 'movie':
      return VideoMetadataMediaKind.movie;
  }
  throw CtlFailure.badRequest('未知类型：$raw（tv | movie）');
}

/// 手动指定身份 → 喂给 `searchManualCandidates` 的身份输入（与候选搜索框里手打
/// `anidb:123` / `tmdb:tv:456` 同一条解析：`parseExplicitVideoMetadataIds`）。
/// 协调器据此按 id 直取作品、校验白名单与正整数，不按标题搜。
String ctlVideoIdentityQuery(
  VideoMetadataProviderKind provider,
  String externalId, {
  VideoMetadataMediaKind? mediaKind,
}) {
  final String id = externalId.trim();
  if (!RegExp(r'^[0-9]+$').hasMatch(id) || (int.tryParse(id) ?? 0) <= 0) {
    throw CtlFailure.badRequest('作品 id 必须是正整数：$externalId');
  }
  if (!kSelectableVideoMetadataProviders.contains(provider)) {
    throw CtlFailure.badRequest('不支持的资料源：${provider.name}');
  }
  return mediaKind == null
      ? '${provider.name}:$id'
      : '${provider.name}:${mediaKind.name}:$id';
}

/// 发现分类：anime | tv | movie；null / all = 不限。
VideoDiscoveryCategory? parseCtlVideoDiscoveryCategory(String? raw) {
  if (raw == null) return null;
  final String name = raw.trim().toLowerCase();
  if (name.isEmpty || name == 'all') return null;
  for (final VideoDiscoveryCategory category in VideoDiscoveryCategory.values) {
    if (category.name == name) return category;
  }
  throw CtlFailure.badRequest('未知分类：$raw（anime | tv | movie | all）');
}

/// 字幕策略：缺省 bestEffort（与资源搜索页的默认值同一个）。
VideoDownloadSubtitlePolicy parseCtlVideoSubtitlePolicy(String? raw) {
  if (raw == null) return VideoDownloadSubtitlePolicy.bestEffort;
  final String name = raw.trim().toLowerCase();
  for (final VideoDownloadSubtitlePolicy policy
      in VideoDownloadSubtitlePolicy.values) {
    if (policy.name.toLowerCase() == name) return policy;
  }
  throw CtlFailure.badRequest('未知字幕策略：$raw（none | bestEffort | required）');
}

/// 发现作品 / 资源候选按短 id（`<prefix>1`、`<prefix>2`…）暂存，后续命令取回原对象。
///
/// 发现条目与资源候选都没有跨进程稳定的短身份，而下载必须拿到搜索时的原对象，
/// 所以由 app 进程持有，按插入顺序保留最近 [capacity] 条。
class CtlVideoCandidateCache<T> {
  CtlVideoCandidateCache(this.prefix, {this.capacity = 500});

  final String prefix;
  final int capacity;
  final Map<String, T> _byId = <String, T>{};
  int _next = 0;

  String put(T value) {
    final String id = '$prefix${++_next}';
    _byId[id] = value;
    while (_byId.length > capacity) {
      _byId.remove(_byId.keys.first);
    }
    return id;
  }

  T? operator [](String id) => _byId[id.trim()];

  int get length => _byId.length;
}

Map<String, Object?> ctlVideoLookupJson(
  VideoMetadataLookup lookup,
) => <String, Object?>{
  'provider': lookup.provider.name,
  'externalId': lookup.externalId,
  'mediaKind': lookup.mediaKind.name,
  if (lookup.episodeGroupId != null) 'episodeGroupId': lookup.episodeGroupId,
};

/// 候选作品的摘要（不含原始 payload）。
Map<String, Object?> ctlVideoCandidateJson(
  VideoMetadataLookup lookup,
  VideoMetadataWork work,
) => <String, Object?>{
  'identity': '${lookup.provider.name}:${lookup.externalId}',
  ...ctlVideoLookupJson(lookup),
  'title': work.title,
  'originalTitle': work.originalTitle,
  'year': work.year,
  'kind': work.kind.name,
  'episodes': work.episodeCount,
};

Map<String, Object?> ctlVideoPendingNoteJson(VideoScrapePendingNote note) =>
    <String, Object?>{
      'cause': note.cause.wire,
      'ai': note.aiOutcome.wire,
      'candidates': note.candidateCount,
      'reason': note.reason,
    };

Map<String, Object?> _issueJson(SourceScrapeIssue issue) => <String, Object?>{
  'work': issue.workTitle,
  'message': issue.message,
  if (issue.workKey != null) 'workId': issue.workKey,
};

/// 刮削报告的 wire 形状（计数 + 警告 / 错误原文）。
Map<String, Object?> ctlVideoReportJson(SourceScrapeReport report) =>
    <String, Object?>{
      'sourceIds': report.sourceIds,
      'totalWorks': report.totalWorks,
      'succeededWorks': report.succeededWorks,
      'failedWorks': report.failedWorks,
      'pendingConfirmations': report.pendingConfirmations,
      'nfoWritten': report.nfoWritten,
      'imagesWritten': report.imagesWritten,
      'cancelled': report.cancelled,
      'warnings': report.warnings.map(_issueJson).toList(),
      'errors': report.errors.map(_issueJson).toList(),
    };

Map<String, Object?> ctlVideoProgressJson(VideoSourceScrapeProgress progress) =>
    <String, Object?>{
      'phase': progress.phase.name,
      'running': progress.isRunning,
      'sourceId': progress.sourceId,
      'source': progress.sourceLabel,
      'work': progress.currentWorkTitle,
      'current': progress.current,
      'total': progress.total,
      'message': progress.message,
    };
