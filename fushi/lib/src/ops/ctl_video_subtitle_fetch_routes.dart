import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/download/download_confirmed_identity.dart'
    show DownloadConfirmedIdentityResolver;
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show VideoSubtitleBackfillReport;

import 'package:fushi/src/media/video/subtitle/library_video_subtitle_backfill.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_work_identity.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_video_support.dart'
    show CtlVideoCandidateCache;
import 'package:fushi/src/ops/op_context.dart';

/// 在线字幕（Jimaku / OpenSubtitles / SubDL）的控制通道路由（CLI：`fushi_cli video
/// sub-fetch` / `sub-search` / `sub-get`，见
/// `packages/fushi_cli/lib/src/commands/video_subtitle_fetch_commands.dart`）。
///
/// 三条都走刮削后自动补字幕的**同一个** [VideoSubtitleBackfillService]（同一个字幕
/// registry、同一份由已落库刮削结论构造的身份），不要求视频页开着：
/// - `subtitle-fetch`：与自动补完全同一条路（搜 → 拒收校验 → 下载 → 落 sidecar）；
/// - `subtitle-search`：只列候选与各来源的失败原因，候选号（`vs1`…）给 `subtitle-get`；
/// - `subtitle-get`：用户点名的那一条直接下载落 sidecar（不覆盖已有同名字幕）。
List<CtlRoute> buildVideoSubtitleFetchCtlRoutes(OpContext context) {
  AppModel appModel() => context.appModel;
  final CtlVideoSubtitleFetchHandlers handlers = CtlVideoSubtitleFetchHandlers(
    database: () => appModel().database,
    service: () => appModel().videoSubtitleBackfillService,
    seriesLanguage: (String key) => appModel().seriesSubtitleLanguage(key),
    videoModuleEnabled: () =>
        appModel().moduleVisibility.isEnabled(ModuleId.video),
  );
  return <CtlRoute>[
    CtlRoute.post(kCtlVideoSubtitleFetchPath, handlers.fetch),
    CtlRoute.post(kCtlVideoSubtitleSearchPath, handlers.search),
    CtlRoute.post(kCtlVideoSubtitleInstallPath, handlers.install),
  ];
}

const String kCtlVideoSubtitleFetchPath = '/api/admin/video/subtitle-fetch';
const String kCtlVideoSubtitleSearchPath = '/api/admin/video/subtitle-search';
const String kCtlVideoSubtitleInstallPath = '/api/admin/video/subtitle-get';

/// `subtitle-search` 暂存的一条候选：连同它所属的补字幕目标（下载要落到哪个视频旁）。
typedef CtlSubtitleSearchHit = ({
  SubtitleBackfillTarget target,
  VideoSubtitleCandidate candidate,
});

/// 路由处理器（依赖全部注入，测试不需要 AppModel）。
class CtlVideoSubtitleFetchHandlers {
  CtlVideoSubtitleFetchHandlers({
    required this.database,
    required this.service,
    required this.seriesLanguage,
    required this.videoModuleEnabled,
  });

  final FushiDatabase Function() database;
  final VideoSubtitleBackfillService? Function() service;
  final String? Function(String seriesKey) seriesLanguage;
  final bool Function() videoModuleEnabled;

  final CtlVideoCandidateCache<CtlSubtitleSearchHit> _hits =
      CtlVideoCandidateCache<CtlSubtitleSearchHit>('vs');

  void _requireVideoModule() {
    if (!videoModuleEnabled()) {
      throw const CtlFailure.rejected('「视频」模块已关闭（设置 › 功能模块）');
    }
  }

  /// 字幕运行时随下载管线起停；没起来或一个来源都没配时如实拒绝。
  VideoSubtitleBackfillService _requireService() {
    final VideoSubtitleBackfillService? current = service();
    if (current == null || current.registry.providers.isEmpty) {
      throw const CtlFailure.rejected(
        '没有可用的在线字幕来源（设置 › 视频 › 字幕：填 Jimaku key 或配 OpenSubtitles）',
      );
    }
    return current;
  }

  /// `subtitle-fetch`：与刮削后自动补字幕同一条路。
  Future<Object?> fetch(CtlCall call) async {
    _requireVideoModule();
    final String bookUid = call.requireString('bookUid');
    final VideoSubtitleBackfillReport? report =
        await backfillLibraryVideoSubtitle(
          database: database(),
          service: _requireService(),
          videoId: bookUid,
          confirmedIdentities: DownloadConfirmedIdentityResolver(database()),
          language: call.optString('language'),
          seriesLanguage: seriesLanguage,
        );
    if (report == null) throw CtlFailure.notFound('视频不存在：$bookUid');
    return <String, Object?>{
      'bookUid': bookUid,
      'outcome': report.outcome,
      if (report.installedPath != null) 'installedPath': report.installedPath,
      if (report.language != null) 'language': report.language,
      if (report.detail != null) 'detail': report.detail,
    };
  }

  Future<SubtitleBackfillTarget> _target(CtlCall call, String bookUid) async {
    final FushiDatabase db = database();
    final VideoBookRow? book = await db.getVideoBookByBookUid(bookUid);
    if (book == null) throw CtlFailure.notFound('视频不存在：$bookUid');
    final ({SubtitleBackfillTarget? target, String? reason}) built =
        await libraryVideoSubtitleTarget(
          db,
          book,
          confirmedIdentities: DownloadConfirmedIdentityResolver(db),
          explicitLanguage: call.optString('language'),
          seriesLanguage: seriesLanguage,
        );
    final SubtitleBackfillTarget? target = built.target;
    if (target == null) {
      throw CtlFailure.rejected(
        '拿不出这个视频的作品身份：${built.reason}（先 video scrape / video identify）',
      );
    }
    return target;
  }

  /// `subtitle-search`：列候选与来源失败，不下载。
  Future<Object?> search(CtlCall call) async {
    _requireVideoModule();
    final VideoSubtitleBackfillService backfill = _requireService();
    final String bookUid = call.requireString('bookUid');
    final SubtitleBackfillTarget target = await _target(call, bookUid);
    final ProviderBatchResult<VideoSubtitleCandidate> result;
    try {
      result = await backfill.search(
        target,
        query: call.optString('query'),
        episode: call.optInt('episode'),
      );
    } on Object catch (error) {
      throw CtlFailure.rejected('字幕搜索失败：$error');
    }
    return <String, Object?>{
      'bookUid': bookUid,
      'title': target.media.title,
      'candidates': <Map<String, Object?>>[
        for (final VideoSubtitleCandidate candidate in result.items)
          <String, Object?>{
            'id': _hits.put((target: target, candidate: candidate)),
            ...ctlSubtitleCandidateJson(candidate),
            // 与自动补同一道作品核对（BUG-3068）：标明「这条不是这部作品」，调用方
            // （AI 补字幕技能）据此不把已判错的候选拿给用户挑。
            ...ctlSubtitleWorkMismatchJson(target, candidate),
          },
      ],
      'failures': <Map<String, Object?>>[
        for (final ExternalProviderFailure failure in result.failures)
          ctlSubtitleFailureJson(failure),
      ],
    };
  }

  /// `subtitle-get <vsN>`：下载用户点名的候选并落 sidecar。
  Future<Object?> install(CtlCall call) async {
    _requireVideoModule();
    final VideoSubtitleBackfillService backfill = _requireService();
    final String id = call.requireString('id');
    final CtlSubtitleSearchHit? hit = _hits[id];
    if (hit == null) {
      throw CtlFailure.notFound('没有这个字幕候选：$id（先 video sub-search）');
    }
    final SubtitleBackfillResult result = await backfill.install(
      hit.target,
      hit.candidate,
    );
    if (result.outcome == SubtitleBackfillOutcome.failed) {
      throw CtlFailure.rejected('字幕下载失败：${result.detail}');
    }
    return <String, Object?>{
      'bookUid': hit.target.bookUid,
      'outcome': result.outcome.name,
      if (result.installedPath != null) 'installedPath': result.installedPath,
      if (result.language != null) 'language': result.language,
      if (result.detail != null) 'detail': result.detail,
    };
  }
}

/// 一条字幕候选的摘要。
Map<String, Object?> ctlSubtitleCandidateJson(
  VideoSubtitleCandidate candidate,
) => <String, Object?>{
  'provider': candidate.providerId,
  'fileName': candidate.fileName,
  'language': candidate.language,
  if (candidate.releaseName != null) 'release': candidate.releaseName,
  if (candidate.season != null) 'season': candidate.season,
  if (candidate.episode != null) 'episode': candidate.episode,
  if (candidate.fileSize != null) 'size': candidate.fileSize,
};

/// 候选与目标作品对不上时的 `{'mismatch': 原因}`；对得上为空表。判据就是自动补
/// 下载前用的 [checkSubtitleWork]，不另立一套。
Map<String, Object?> ctlSubtitleWorkMismatchJson(
  SubtitleBackfillTarget target,
  VideoSubtitleCandidate candidate,
) {
  final SubtitleWorkCheck check = checkSubtitleWork(target.media, candidate);
  return check.rejected
      ? <String, Object?>{'mismatch': check.detail}
      : const <String, Object?>{};
}

/// 一个来源的失败（限流 / 鉴权 / 连不上）。
Map<String, Object?> ctlSubtitleFailureJson(ExternalProviderFailure failure) =>
    <String, Object?>{
      'provider': failure.providerId,
      'operation': failure.operation,
      'kind': failure.kind.name,
      if (failure.statusCode != null) 'status': failure.statusCode,
      'message': failure.message,
    };
