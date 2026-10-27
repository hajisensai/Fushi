/// video 域控制通道的纯函数部分（解析 / 短 id 暂存 / JSON 形状），与路由分开以便单测。
library;

import 'dart:async';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
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
    show
        SourceScrapeIssue,
        SourceScrapeReport,
        VideoSourceScrapeAiSuggestion,
        VideoSourceScrapeConfirmation,
        VideoSourceScrapeConfirmationCandidate,
        VideoSourceScrapeProgress,
        VideoSourceScrapeTaskController;

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

// ── 刮削待确认（app 内确认框与 CLI 共用同一个待决状态） ─────────────────────

/// 待确认项的短 id（`sc1`、`sc2`…）：按对象身份分配、同一项多次读到同一个 id。
///
/// CLI 作答时带回它，app 侧核对「答的还是不是这一项」——列出候选到作答之间，
/// app 内可能已经有人答了、批次已推进到下一部作品；不带 id 核对，序号就会落到
/// 下一部作品的候选上（写错身份）。
final Expando<String> _confirmationIds = Expando<String>(
  'ctlVideoConfirmation',
);
int _nextConfirmationId = 0;

String ctlVideoConfirmationId(VideoSourceScrapeConfirmation confirmation) =>
    _confirmationIds[confirmation] ??= 'sc${++_nextConfirmationId}';

/// 待确认项的 wire 形状：候选带 1 起的序号（`video confirm <序号>` 用它）。
Map<String, Object?> ctlVideoConfirmationJson(
  VideoSourceScrapeConfirmation confirmation,
) {
  final VideoSourceScrapeAiSuggestion? ai = confirmation.aiSuggestion;
  return <String, Object?>{
    'id': ctlVideoConfirmationId(confirmation),
    'work': confirmation.localWorkTitle,
    'sourceId': confirmation.sourceId,
    'source': confirmation.sourceLabel,
    'candidates': <Map<String, Object?>>[
      for (int i = 0; i < confirmation.candidates.length; i++)
        <String, Object?>{
          'index': i + 1,
          ...ctlVideoCandidateJson(
            confirmation.candidates[i].lookup,
            confirmation.candidates[i].work,
          ),
          if (ai != null && ai.candidateIndex == i) 'aiSuggested': true,
        },
    ],
    if (ai != null)
      'ai': <String, Object?>{
        'index': ai.candidateIndex + 1,
        'confidence': ai.confidencePercent,
        if (ai.reason.isNotEmpty) 'reason': ai.reason,
      },
  };
}

/// `video confirm` 的三种回答。
sealed class CtlVideoConfirmationAnswer {
  const CtlVideoConfirmationAnswer();

  /// 解析请求体：`action` = pick（`index`，1 起）| identity（`provider` +
  /// `externalId`，可选 `type`）| skip。
  factory CtlVideoConfirmationAnswer.parse(CtlCall call) {
    final String action = call.requireString('action').trim().toLowerCase();
    switch (action) {
      case 'pick':
        final int? index = call.optInt('index');
        if (index == null || index < 1) {
          throw const CtlFailure.badRequest('index 必须是 1 起的候选序号');
        }
        return CtlVideoPickCandidate(index);
      case 'identity':
        final VideoMetadataProviderKind provider = parseCtlVideoProvider(
          call.requireString('provider'),
        );
        return CtlVideoPickIdentity(
          ctlVideoIdentityQuery(
            provider,
            call.requireString('externalId'),
            mediaKind: parseCtlVideoMediaKind(call.optString('type')),
          ),
        );
      case 'skip':
        return const CtlVideoSkipConfirmation();
    }
    throw CtlFailure.badRequest('未知 action：$action（pick | identity | skip）');
  }
}

class CtlVideoPickCandidate extends CtlVideoConfirmationAnswer {
  const CtlVideoPickCandidate(this.index);

  /// 1 起的候选序号。
  final int index;
}

/// 手动指定身份：[query] 是 `anidb:123` / `tmdb:tv:456` 这类身份输入，与候选
/// 搜索框里手打的同一条解析（协调器按 id 直取，不按标题搜）。
class CtlVideoPickIdentity extends CtlVideoConfirmationAnswer {
  const CtlVideoPickIdentity(this.query);

  final String query;
}

class CtlVideoSkipConfirmation extends CtlVideoConfirmationAnswer {
  const CtlVideoSkipConfirmation();
}

/// 回答 [controller] 当前的待确认项。
///
/// 走的是 app 内确认框同一对入口：选候选 = [VideoSourceScrapeTaskController.confirmPending]
/// （确认框点候选卡）、跳过 = [VideoSourceScrapeTaskController.skipPendingConfirmation]
/// （确认框「跳过」）；手动指定身份先经 `searchManualCandidates` 按 id 直取作品，
/// 再当作选中的候选交回去，后续写库仍是批次内同一条确认路径。
///
/// [expectedId] 非空时核对仍是同一项（见 [ctlVideoConfirmationId]）；没有待确认 /
/// 已被 app 内抢先回答都是 409。[sourceById] 给手动指定身份取来源行。
Future<Map<String, Object?>> answerCtlVideoConfirmation(
  VideoSourceScrapeTaskController controller,
  CtlVideoConfirmationAnswer answer, {
  String? expectedId,
  required Future<SourceLibraryRow?> Function(int sourceId) sourceById,
}) async {
  final VideoSourceScrapeConfirmation confirmation = _requirePending(
    controller,
    expectedId,
  );
  final String id = ctlVideoConfirmationId(confirmation);
  switch (answer) {
    case CtlVideoSkipConfirmation():
      if (!controller.skipPendingConfirmation()) _alreadyAnswered(id);
      return <String, Object?>{
        'id': id,
        'work': confirmation.localWorkTitle,
        'answer': 'skip',
      };
    case CtlVideoPickCandidate(:final int index):
      if (index > confirmation.candidates.length) {
        throw CtlFailure.badRequest(
          '候选序号超出范围：$index（共 ${confirmation.candidates.length} 个）',
        );
      }
      final VideoSourceScrapeConfirmationCandidate picked =
          confirmation.candidates[index - 1];
      if (!controller.confirmPending(picked)) _alreadyAnswered(id);
      return _answered(id, confirmation, 'pick', picked);
    case CtlVideoPickIdentity(:final String query):
      if (!controller.supportsManualBinding) {
        throw const CtlFailure.unsupported('当前刮削实现不支持手动指定作品');
      }
      final List<VideoSourceScrapeConfirmationCandidate> found;
      try {
        found = await controller.searchManualCandidates(
          source: await sourceById(confirmation.sourceId),
          workTitle: confirmation.localWorkTitle,
          query: query,
        );
      } on FormatException catch (e) {
        throw CtlFailure.badRequest('作品 id 无效：${e.message}');
      }
      if (found.isEmpty) {
        throw CtlFailure.rejected('取不到 $query（资料源不可用 / 未配置凭据 / 查无此作品）');
      }
      // 联网取作品期间 app 内可能已经答了，或批次推进到了下一项：重新核对。
      _requirePending(controller, id);
      if (!controller.confirmPending(found.first)) _alreadyAnswered(id);
      return _answered(id, confirmation, 'identity', found.first);
  }
}

VideoSourceScrapeConfirmation _requirePending(
  VideoSourceScrapeTaskController controller,
  String? expectedId,
) {
  final VideoSourceScrapeConfirmation? pending = controller.pendingConfirmation;
  if (pending == null) {
    throw const CtlFailure.conflict('当前没有等待确认的刮削作品');
  }
  if (expectedId != null && ctlVideoConfirmationId(pending) != expectedId) {
    throw CtlFailure.conflict(
      '待确认项已变（现在是 ${ctlVideoConfirmationId(pending)}「'
      '${pending.localWorkTitle}」），先 video confirm 重新查看',
    );
  }
  return pending;
}

Never _alreadyAnswered(String id) =>
    throw CtlFailure.conflict('$id 已在 app 内被回答');

Map<String, Object?> _answered(
  String id,
  VideoSourceScrapeConfirmation confirmation,
  String answer,
  VideoSourceScrapeConfirmationCandidate picked,
) => <String, Object?>{
  'id': id,
  'work': confirmation.localWorkTitle,
  'answer': answer,
  'picked': ctlVideoCandidateJson(picked.lookup, picked.work),
};

/// 等 [controller] 出现待确认项，或批次结束（不再运行）。返回出现的待确认项；
/// 批次结束 / 超时返回 null。监听控制器自身的通知，不轮询。
Future<VideoSourceScrapeConfirmation?> waitForCtlVideoConfirmation(
  VideoSourceScrapeTaskController controller,
  Duration timeout,
) async {
  if (controller.pendingConfirmation != null || !controller.isRunning) {
    return controller.pendingConfirmation;
  }
  final Completer<void> changed = Completer<void>();
  void listener() {
    if (changed.isCompleted) return;
    if (controller.pendingConfirmation != null || !controller.isRunning) {
      changed.complete();
    }
  }

  controller.addListener(listener);
  try {
    await changed.future.timeout(timeout, onTimeout: () {});
  } finally {
    controller.removeListener(listener);
  }
  return controller.pendingConfirmation;
}
