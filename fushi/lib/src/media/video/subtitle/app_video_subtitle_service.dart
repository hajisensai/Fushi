/// app 层「生成日语字幕」的唯一编排（spec `2026-10-19-video-asr-llm-subtitle-pipeline`
/// 第 2、3、5、6 节 app 部分）。
///
/// 视频页面板、合集页「整季生成」、专名表编辑页与桌面 CLI（`fushi_cli video
/// subtitle-gen` / `subtitle-glossary`）**都调这一个服务**，不在 UI 与 ctl 里各写一套：
///
/// - 目标解析：一个视频条目（含播放列表各集）或一个合集 → 本机可处理的视频文件 +
///   作品上下文（[SubtitleWorkContextLoader]，没刮削时按目录 / 标题兜底）；
/// - 任务：[start] 起一个 [AppVideoSubtitleJob]（进程内同一时刻只跑一个——识别要占满
///   GPU / CPU），同时在 [videoRemoteJobs] 登记一个镜像，CLI 用 `video job <id>`
///   查进度 / 取消；
/// - 失败语义照管线：AI 请求失败 = 暂停（缓存保留，[start] 同一目标即续）、专名表
///   校验不过 = 把候选表交给用户改、取消 = 已落盘的阶段保留；
/// - 产物登记：导出的 `<视频名>.ja.srt` / `.ja.asr.srt` 在该条目**还没有字幕选择**时
///   写进 `video_books.subtitleSource`（用户自己选过的字幕 / 显式关闭不覆盖）。播放页
///   当前那集由页面自己切过去。视频已有别的 ASS 字幕（外挂或内嵌）时管线另出一份
///   套了它样式 / 位置的 `.ja.ass`，登记的是这份。
///
/// AI 边界（CLAUDE.md「AI 功能」硬边界）：没指派提供商时一个请求都不发（[start] 直接
/// 拒绝，UI 引导去「设置 › 模型 › LLM」）；只发 ASR 文本与专名表，不发音频 / 画面。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio_core.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart'
    show
        FushiDatabase,
        MediaCollectionItemRow,
        MediaCollectionRow,
        VideoBookRow;
import 'package:fushi_engine/media/video/video_member_file.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_builder.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_drift_store.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_work_context_loader.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
import 'package:fushi_engine/media/video/video_local_files.dart'
    show isLocalVideoFilePath, localVideoFileCandidates;
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart' show t;
import 'package:fushi/src/asr_host/asr_host.dart'
    show resolveAppVideoSubtitleRecognizer;
import 'package:fushi/src/media/video/subtitle/video_subtitle_model_ports.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 挑识别器（生产实现是 `asr_host.dart` 的 [resolveAppVideoSubtitleRecognizer]）。
typedef AppVideoSubtitleRecognizerResolver =
    Future<VideoSubtitleRecognizerChoice> Function({
      required VideoSubtitleSegmenterMode mode,
      MossBackendPreference mossBackend,
    });

/// 按提供商建 AI 出口（生产实现 [AiChatTextCompleter]）。返回的 `close` 在任务结束
/// 时调用（释放 HTTP 连接）。
typedef AppVideoSubtitleCompleterFactory =
    ({AiTextCompleter completer, void Function() close}) Function(
      AiProviderConfig provider,
    );

/// 读视频时长（毫秒；读不出 null）。
typedef AppVideoSubtitleDurationProbe = Future<int?> Function(String videoPath);

/// 服务从设置里要的两样东西（生产实现读 `PreferencesRepository`，测试注入 fake）。
abstract interface class AppVideoSubtitleSettings {
  /// 「字幕校对」功能当前指派的提供商；null = 没指派 / AI 模块关闭。
  AiProviderConfig? get proofreadProvider;

  /// 专名表生成时抓百科页用的站点（空 = 只用刮削数据）。
  List<WebKnowledgeSite> get webKnowledgeSites;
}

/// 生产实现：现读偏好仓（指派 / 站点改了下一次调用即生效）。
class PrefsVideoSubtitleSettings implements AppVideoSubtitleSettings {
  const PrefsVideoSubtitleSettings(this.prefs);

  final PreferencesRepository prefs;

  @override
  AiProviderConfig? get proofreadProvider =>
      prefs.resolveAiFeatureProvider(AiFeature.subtitleProofread);

  @override
  List<WebKnowledgeSite> get webKnowledgeSites => prefs.aiWebKnowledgeSites;
}

/// UI 与 ctl 取服务的唯一入口（同一个库共用一个实例，任务表跨页面存活）。
AppVideoSubtitleService appVideoSubtitleService(AppModel appModel) =>
    AppVideoSubtitleService.shared(
      database: appModel.database,
      settings: PrefsVideoSubtitleSettings(appModel.prefsRepo),
    );

/// 一集。
@immutable
class AppVideoSubtitleEpisode {
  const AppVideoSubtitleEpisode({
    required this.bookUid,
    required this.videoPath,
    required this.title,
    this.registersSubtitleSource = true,
    this.replacesSubtitleSelection = false,
  });

  final String bookUid;
  final String videoPath;
  final String title;

  /// 导出后能否把字幕登记到这一行的 `subtitleSource`：播放列表里的子集共用一行，
  /// 那一行的字幕选择不属于其中某一集，不登记。
  final bool registersSubtitleSource;

  /// 登记时是否**替换**这一行已有的字幕选择。视频页对当前这一集点「生成日语字幕」
  /// 是用户明确要用生成的字幕：转录要好几分钟，用户常常先退出播放页，任务结束时页面
  /// 已不在、页面那条「结束后切成当前字幕」走不到，产物只能靠这里登记；若照整季 /
  /// CLI 的口径「已有选择不覆盖」，条目原本选着内嵌轨或下载字幕时，生成的字幕重进
  /// 播放页也不会被用上（用户反馈 DEStBY5I66）。整季与 CLI 仍不覆盖。
  final bool replacesSubtitleSelection;
}

/// 本机处理不了的一集（远端 / 文件不存在）。
enum AppVideoSubtitleUnavailableReason { remote, missingFile }

@immutable
class AppVideoSubtitleUnavailable {
  const AppVideoSubtitleUnavailable({
    required this.bookUid,
    required this.title,
    required this.reason,
  });

  final String bookUid;
  final String title;
  final AppVideoSubtitleUnavailableReason reason;
}

/// 一次生成的目标：单集（视频页 / CLI 的 bookUid）或整季（合集）。
@immutable
class AppVideoSubtitleTarget {
  const AppVideoSubtitleTarget({
    required this.title,
    required this.work,
    required this.episodes,
    this.unavailable = const <AppVideoSubtitleUnavailable>[],
    this.collectionId,
    this.bookUid,
  });

  final String title;
  final SubtitleWorkContext work;
  final List<AppVideoSubtitleEpisode> episodes;
  final List<AppVideoSubtitleUnavailable> unavailable;

  /// 整季目标的合集 id（单集为 null）。
  final int? collectionId;

  /// 单集目标的条目（整季为 null）。
  final String? bookUid;

  /// 整季：已有 `<视频名>.ja.srt` 的集由管线直接跳过。
  bool get wholeSeason => collectionId != null;

  /// 进程内去重键（同一目标只能有一个任务）。
  String get key => collectionId != null
      ? 'collection:$collectionId'
      : 'book:$bookUid:${episodes.map((AppVideoSubtitleEpisode e) => e.videoPath).join('|')}';

  List<String> get videoPaths => <String>[
    for (final AppVideoSubtitleEpisode e in episodes) e.videoPath,
  ];

  /// 作品身份没有刮削数据：UI 提示「建议先刮削」。
  bool get missingScrapedData => !work.hasScrapedData;
}

/// 一次生成的选项。
@immutable
class AppVideoSubtitleOptions {
  const AppVideoSubtitleOptions({
    this.proofread = false,
    this.segmenter = VideoSubtitleSegmenterMode.auto,
    this.mossBackend = MossBackendPreference.auto,
    this.regenerateGlossary = false,
  });

  final bool proofread;
  final VideoSubtitleSegmenterMode segmenter;
  final MossBackendPreference mossBackend;
  final bool regenerateGlossary;

  Map<String, Object?> toJson() => <String, Object?>{
    'proofread': proofread,
    'segmenter': segmenter.name,
    'mossBackend': mossBackend.name,
    if (regenerateGlossary) 'regenerateGlossary': true,
  };
}

/// [start] 拒绝起任务的原因。
enum AppVideoSubtitleStartProblem {
  /// 已有任务在跑（[AppVideoSubtitleStartRefused.activeJob]）。
  busy,

  /// 开了 AI 校对却没指派「字幕校对」的提供商：一个请求都不发。
  noProvider,

  /// 目标里没有本机可处理的视频文件。
  noLocalEpisodes,

  /// 「只重跑写法统一」：还没有任何一集跑过校对。
  nothingToRerun,
}

class AppVideoSubtitleStartRefused implements Exception {
  const AppVideoSubtitleStartRefused(this.problem, {this.activeJob});

  final AppVideoSubtitleStartProblem problem;
  final AppVideoSubtitleJob? activeJob;

  @override
  String toString() => 'AppVideoSubtitleStartRefused(${problem.name})';
}

/// 找不到要生成的目标（条目 / 合集不存在）。
class AppVideoSubtitleTargetNotFound implements Exception {
  const AppVideoSubtitleTargetNotFound(this.what);

  final String what;

  @override
  String toString() => 'AppVideoSubtitleTargetNotFound($what)';
}

/// 任务状态。[running] 以外都是终态；[pausedAiFailure] / [glossaryInvalid] 是
/// 「停下等用户」：缓存都在，处理后对同一目标 [AppVideoSubtitleService.start] 即续。
enum AppVideoSubtitleJobStatus {
  running,
  succeeded,
  cancelled,
  pausedAiFailure,
  glossaryInvalid,
  failed,
}

/// 一集在任务里的进度。
class AppVideoSubtitleEpisodeProgress {
  AppVideoSubtitleEpisodeProgress(this.episode);

  final AppVideoSubtitleEpisode episode;

  /// 最近一次进度属于这一集时的阶段；null = 还没轮到。
  VideoSubtitleStage? stage;

  /// 管线的最终去向（任务成功后才有）。
  VideoSubtitleEpisodeResult? result;
}

/// 一次生成任务（UI 监听它重建；CLI 经 [mirror] 查看）。
class AppVideoSubtitleJob extends ChangeNotifier {
  AppVideoSubtitleJob._({
    required this.target,
    required this.options,
    required this.consistencyOnly,
  }) : episodes = <AppVideoSubtitleEpisodeProgress>[
         for (final AppVideoSubtitleEpisode e in target.episodes)
           AppVideoSubtitleEpisodeProgress(e),
       ];

  final AppVideoSubtitleTarget target;
  final AppVideoSubtitleOptions options;

  /// 「只重跑写法统一」（改了专名表之后）。
  final bool consistencyOnly;

  final List<AppVideoSubtitleEpisodeProgress> episodes;
  final SubtitleCancelSource _cancel = SubtitleCancelSource();
  final Completer<void> _done = Completer<void>();

  /// `video job` 能看到的镜像（CLI 的进度 / 取消都走它）。
  late final VideoRemoteJob mirror;

  AppVideoSubtitleJobStatus status = AppVideoSubtitleJobStatus.running;
  VideoSubtitleProgress? progress;
  VideoSubtitlePipelineResult? result;

  /// [AppVideoSubtitleJobStatus.pausedAiFailure] 的原因（脱敏短码）。
  SubtitleAiRequestFailure? aiFailure;

  /// [AppVideoSubtitleJobStatus.glossaryInvalid] 的详情（含候选表）。
  SubtitleGlossaryValidationFailure? glossaryFailure;

  /// [AppVideoSubtitleJobStatus.failed] 的原因（给人看的英文短句）。
  String? errorMessage;

  /// 想用 MOSS（auto）却没用上的原因；用了 MOSS 或选了滑窗为 null。
  VideoSubtitleMossProblem? mossProblem;

  /// 实际用的识别器 id（`drafts.<id>.json`）。
  String? recognizerId;

  /// 已登记进 `video_books.subtitleSource` 的条目。
  final List<String> registeredBookUids = <String>[];

  bool get isRunning => status == AppVideoSubtitleJobStatus.running;
  bool get cancelRequested => _cancel.isCancelled;
  Future<void> get done => _done.future;

  void cancel() {
    if (!isRunning) return;
    _cancel.cancel();
    notifyListeners();
  }

  void _onProgress(VideoSubtitleProgress p) {
    if (!isRunning) return;
    progress = p;
    final int? i = p.episodeIndex;
    if (i != null && i >= 0 && i < episodes.length) episodes[i].stage = p.stage;
    mirror.update(
      phase: p.stage.name,
      fraction: p.fraction,
      detail: i == null
          ? p.message
          : '${i + 1}/${episodes.length} ${episodes[i].episode.title}: ${p.message}',
    );
    notifyListeners();
  }

  void _finish(AppVideoSubtitleJobStatus next) {
    status = next;
    switch (next) {
      case AppVideoSubtitleJobStatus.succeeded:
        mirror.succeed(resultJson());
      case AppVideoSubtitleJobStatus.cancelled:
        mirror.fail('cancelled', 'cancelled');
      case AppVideoSubtitleJobStatus.pausedAiFailure:
        mirror.fail(
          'ai_failure',
          'paused: AI request failed (${aiFailure?.reason}); rerun to resume',
        );
      case AppVideoSubtitleJobStatus.glossaryInvalid:
        mirror.fail(
          'glossary_invalid',
          'glossary validation failed (${glossaryFailure?.problem.name}); '
              'edit it with video subtitle-glossary --set, then rerun',
        );
      case AppVideoSubtitleJobStatus.failed:
        mirror.fail('failed', errorMessage ?? 'failed');
      case AppVideoSubtitleJobStatus.running:
        break;
    }
    if (!_done.isCompleted) _done.complete();
    notifyListeners();
  }

  /// 给 CLI 的结果（成功时）。
  Map<String, Object?> resultJson() {
    final VideoSubtitlePipelineResult? r = result;
    return <String, Object?>{
      'target': target.collectionId != null
          ? 'collection:${target.collectionId}'
          : 'book:${target.bookUid}',
      'workKey': target.work.workKey,
      'options': options.toJson(),
      if (recognizerId != null) 'recognizer': recognizerId,
      if (mossProblem != null) ...<String, Object?>{
        'mossUnavailableReason': mossProblem!.reason,
        if (mossProblem!.code != null)
          'mossUnavailableCode': mossProblem!.code!.name,
      },
      if (r != null) ...<String, Object?>{
        'episodes': <Map<String, Object?>>[
          for (final VideoSubtitleEpisodeResult e in r.episodes)
            <String, Object?>{
              'videoPath': e.videoPath,
              'status': e.status.name,
              if (e.outputPath != null) 'output': e.outputPath,
              if (e.reason != null) 'reason': e.reason,
              'cues': e.cueCount,
            },
        ],
        'usage': r.usage.toJson(),
        if (r.glossary != null) 'glossaryEntries': r.glossary!.entries.length,
        if (r.glossaryRegenerated) 'glossaryRegenerated': true,
      },
      if (target.unavailable.isNotEmpty)
        'unavailable': <Map<String, Object?>>[
          for (final AppVideoSubtitleUnavailable u in target.unavailable)
            <String, Object?>{
              'bookUid': u.bookUid,
              'title': u.title,
              'reason': u.reason.name,
            },
        ],
      if (registeredBookUids.isNotEmpty) 'registered': registeredBookUids,
    };
  }
}

/// 费用预估的依据。
enum AppVideoSubtitleEstimateBasis {
  /// 全部按已识别的字幕稿（缓存里有 `drafts.*.json`）。
  drafts,

  /// 至少一集还没识别：按时长粗估（每分钟 [kVideoSubtitleEstimateCuesPerMinute] 句）。
  duration,

  /// 没有要校对的集（都已完成或都跳过）。
  nothing,
}

/// 费用预估。
@immutable
class AppVideoSubtitleCostEstimate {
  const AppVideoSubtitleCostEstimate({
    required this.basis,
    required this.episodes,
    required this.cost,
    this.unknownDurationEpisodes = 0,
  });

  final AppVideoSubtitleEstimateBasis basis;

  /// 计入预估的集数。
  final int episodes;
  final SubtitleProofreadCostEstimate cost;

  /// 时长读不出、没计入的集数（预估偏低）。
  final int unknownDurationEpisodes;
}

/// 按时长粗估时每分钟的字幕句数与每句字数。标定：基准《sin 七つの大罪》
/// 约 5.5 小时 134 批（≈4000 句 → ≈12 句/分钟）；回复 87,068 字符扣掉每句约
/// 11 字的 `"<id>": "", ` 骨架，正文 ≈12 字/句。
const int kVideoSubtitleEstimateCuesPerMinute = 12;
const int kVideoSubtitleEstimateCharsPerCue = 12;

/// 视频字幕任务目录的根（`<数据根>/asr_jobs/video_subtitles`）。布局只在引擎的
/// [videoSubtitleJobsRootUnder] 写一次（host 任务与服务端 CLI 共用）。
Future<Directory> defaultVideoSubtitleJobsRoot() async =>
    videoSubtitleJobsRootUnder(await AppPaths.supportRootDirectory());

({AiTextCompleter completer, void Function() close}) _defaultCompleter(
  AiProviderConfig provider,
) {
  final AiChatClient client = AiChatClient();
  return (
    completer: AiChatTextCompleter(client: client, provider: provider),
    close: client.close,
  );
}

Future<VideoSubtitleRecognizerChoice> _defaultResolver({
  required VideoSubtitleSegmenterMode mode,
  MossBackendPreference mossBackend = MossBackendPreference.auto,
}) => resolveAppVideoSubtitleRecognizer(mode: mode, mossBackend: mossBackend);

/// app 层视频字幕服务。
class AppVideoSubtitleService {
  AppVideoSubtitleService({
    required this.database,
    required this.settings,
    AppVideoSubtitleRecognizerResolver? recognizerResolver,
    AppVideoSubtitleCompleterFactory? completerFactory,
    Future<Directory> Function()? jobsRoot,
    AppVideoSubtitleDurationProbe? probeDurationMs,
    SubtitleGlossaryStore? glossaryStore,
    this.mossPort = const AppVideoSubtitleMossPort(),
    this.asrModelPort = const AppVideoSubtitleAsrModelPort(),
    VideoRemoteJobRegistry? jobRegistry,
    WebKnowledgeClient Function(List<WebKnowledgeSite> sites)? webKnowledge,
    int Function()? nowMs,
  }) : _resolveRecognizer = recognizerResolver ?? _defaultResolver,
       _completerFactory = completerFactory ?? _defaultCompleter,
       _jobsRoot = jobsRoot ?? defaultVideoSubtitleJobsRoot,
       _probeDurationMs = probeDurationMs ?? probeVideoDurationMs,
       glossaryStore = glossaryStore ?? SubtitleGlossaryDriftStore(database),
       _jobRegistry = jobRegistry ?? videoRemoteJobs,
       _webKnowledge =
           webKnowledge ??
           ((List<WebKnowledgeSite> sites) => WebKnowledgeClient(sites: sites)),
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 进程级实例（按库实例缓存：Profile 切换换库时重建）。
  static AppVideoSubtitleService? _shared;

  /// UI / ctl 共用的实例：同一个库只建一次，任务表跨页面存活。
  static AppVideoSubtitleService shared({
    required FushiDatabase database,
    required AppVideoSubtitleSettings settings,
  }) {
    final AppVideoSubtitleService? existing = _shared;
    if (existing != null && identical(existing.database, database)) {
      return existing;
    }
    return _shared = AppVideoSubtitleService(
      database: database,
      settings: settings,
    );
  }

  final FushiDatabase database;
  final AppVideoSubtitleSettings settings;
  final SubtitleGlossaryStore glossaryStore;
  final VideoSubtitleMossPort mossPort;
  final VideoSubtitleAsrModelPort asrModelPort;
  final AppVideoSubtitleRecognizerResolver _resolveRecognizer;
  final AppVideoSubtitleCompleterFactory _completerFactory;
  final Future<Directory> Function() _jobsRoot;
  final AppVideoSubtitleDurationProbe _probeDurationMs;
  final VideoRemoteJobRegistry _jobRegistry;
  final WebKnowledgeClient Function(List<WebKnowledgeSite> sites) _webKnowledge;
  final int Function() _nowMs;

  AppVideoSubtitleSettings get _settings => settings;

  AppVideoSubtitleJob? _active;
  final Map<String, AppVideoSubtitleJob> _latestByTarget =
      <String, AppVideoSubtitleJob>{};

  /// 正在跑的任务（进程内至多一个）。
  AppVideoSubtitleJob? get activeJob => _active;

  /// 某目标最近一次任务（含已结束的），面板重开时据此恢复状态。
  AppVideoSubtitleJob? latestJobFor(AppVideoSubtitleTarget target) =>
      _latestByTarget[target.key];

  /// 「字幕校对」当前指派的提供商。
  AiProviderConfig? get proofreadProvider => _settings.proofreadProvider;

  // ── 目标解析 ────────────────────────────────────────────────────────────

  /// 一个视频条目（`video_books.book_uid`）：本体 + 播放列表各集。[videoPath] 非空
  /// 时只取这一集（视频页的当前集）。
  Future<AppVideoSubtitleTarget> resolveBook(
    String bookUid, {
    String? videoPath,
  }) async {
    final VideoBookRow? row = await database.getVideoBookByBookUid(bookUid);
    if (row == null) throw AppVideoSubtitleTargetNotFound('book $bookUid');
    final List<AppVideoSubtitleEpisode> episodes = <AppVideoSubtitleEpisode>[];
    final List<AppVideoSubtitleUnavailable> unavailable =
        <AppVideoSubtitleUnavailable>[];
    await _collectEpisodes(
      row,
      episodes,
      unavailable,
      onlyPath: videoPath,
      replaceSelection: videoPath != null,
    );
    // 播放页的当前路径可能是重定位后的（盘符换了 / 数据根搬了），与库里记的写法
    // 对不上：文件确实在就照样处理这一集，只是不替这一行登记字幕选择（页面自己选）。
    if (videoPath != null &&
        episodes.isEmpty &&
        isLocalVideoFilePath(videoPath) &&
        await videoPathFileExists(videoPath)) {
      unavailable.clear();
      episodes.add(
        AppVideoSubtitleEpisode(
          bookUid: bookUid,
          videoPath: videoPath,
          title: row.title,
          registersSubtitleSource: false,
        ),
      );
    }
    final SubtitleWorkContext work =
        await SubtitleWorkContextLoader(database).forBook(bookUid) ??
        _fallbackWork(
          title: row.title,
          videoPath: episodes.isEmpty
              ? row.videoPath
              : episodes.first.videoPath,
        );
    return AppVideoSubtitleTarget(
      title: row.title,
      work: work,
      episodes: episodes,
      unavailable: unavailable,
      bookUid: bookUid,
    );
  }

  /// 一个合集的全部视频成员（按合集顺序）。
  Future<AppVideoSubtitleTarget> resolveCollection(int collectionId) async {
    final MediaCollectionRow? collection = await database
        .getMediaCollectionById(collectionId);
    if (collection == null) {
      throw AppVideoSubtitleTargetNotFound('collection $collectionId');
    }
    final List<AppVideoSubtitleEpisode> episodes = <AppVideoSubtitleEpisode>[];
    final List<AppVideoSubtitleUnavailable> unavailable =
        <AppVideoSubtitleUnavailable>[];
    for (final MediaCollectionItemRow item in await database.getCollectionItems(
      collectionId,
    )) {
      if (item.mediaType != 'video') continue;
      final VideoBookRow? row = await database.getVideoBookByBookUid(
        item.entryKey,
      );
      if (row == null) continue;
      await _collectEpisodes(row, episodes, unavailable);
    }
    final SubtitleWorkContext work =
        await SubtitleWorkContextLoader(database).forCollection(collectionId) ??
        _fallbackWork(
          title: collection.name,
          videoPath: episodes.isEmpty ? null : episodes.first.videoPath,
        );
    return AppVideoSubtitleTarget(
      title: collection.name,
      work: work,
      episodes: episodes,
      unavailable: unavailable,
      collectionId: collectionId,
    );
  }

  /// 视频文件存在性一律 async 判：视频常在网络盘（rclone / SMB）上，这条服务跑在
  /// UI isolate，同步 stat 冷目录要数秒、整个界面一起冻结（BUG-3756）。
  Future<void> _collectEpisodes(
    VideoBookRow row,
    List<AppVideoSubtitleEpisode> out,
    List<AppVideoSubtitleUnavailable> unavailable, {
    String? onlyPath,
    bool replaceSelection = false,
  }) async {
    final List<String> candidates = localVideoFileCandidates(
      videoPath: row.videoPath,
      playlistJson: row.playlistJson,
    );
    if (candidates.isEmpty) {
      unavailable.add(
        AppVideoSubtitleUnavailable(
          bookUid: row.bookUid,
          title: row.title,
          reason: isLocalVideoFilePath(row.videoPath)
              ? AppVideoSubtitleUnavailableReason.missingFile
              : AppVideoSubtitleUnavailableReason.remote,
        ),
      );
      return;
    }
    final bool playlist = candidates.length > 1;
    for (final String path in candidates) {
      if (onlyPath != null && !p.equals(path, onlyPath)) continue;
      if (!await File(path).exists()) {
        unavailable.add(
          AppVideoSubtitleUnavailable(
            bookUid: row.bookUid,
            title: playlist ? p.basenameWithoutExtension(path) : row.title,
            reason: AppVideoSubtitleUnavailableReason.missingFile,
          ),
        );
        continue;
      }
      out.add(
        AppVideoSubtitleEpisode(
          bookUid: row.bookUid,
          videoPath: path,
          title: playlist ? p.basenameWithoutExtension(path) : row.title,
          registersSubtitleSource: p.equals(path, row.videoPath) && !playlist,
          replacesSubtitleSelection: replaceSelection,
        ),
      );
    }
  }

  SubtitleWorkContext _fallbackWork({
    required String title,
    required String? videoPath,
  }) => SubtitleWorkContext(
    workKey: fallbackSubtitleWorkKey(
      folderPath: videoPath == null ? null : p.dirname(videoPath),
      title: title.trim().isEmpty ? 'untitled' : title,
    ),
    title: title,
  );

  // ── 识别模型 / MOSS ─────────────────────────────────────────────────────

  /// 按 [mode] / [mossBackend] 预先挑一次识别器（面板显示「MOSS 为什么用不上」）。
  /// 返回 null 原因 = 会用 MOSS 或选了滑窗；显式选 MOSS 而不可用时返回原因。
  Future<VideoSubtitleMossProblem?> previewMossProblem({
    required VideoSubtitleSegmenterMode mode,
    required MossBackendPreference mossBackend,
  }) async {
    if (mode == VideoSubtitleSegmenterMode.window) return null;
    try {
      final VideoSubtitleRecognizerChoice choice = await _resolveRecognizer(
        mode: mode,
        mossBackend: mossBackend,
      );
      final String? reason = choice.mossUnavailableReason;
      return reason == null
          ? null
          : VideoSubtitleMossProblem(
              code: choice.mossUnavailableCode,
              reason: reason,
            );
    } on VideoSubtitleRecognizeFailure catch (failure) {
      return VideoSubtitleMossProblem(reason: failure.message);
    }
  }

  // ── 专名表 ──────────────────────────────────────────────────────────────

  Future<SubtitleGlossary?> loadGlossary(SubtitleWorkContext work) =>
      glossaryStore.load(work.workKey);

  /// 保存用户编辑后的表。与 [previous] 不同（新增 / 改过）的条目标 `userEdited`，
  /// 重新生成时原样保留；`userEditedAt` 记本次时刻。
  ///
  /// 指纹：沿用原表的；原表不存在（手填 / 改的是校验没过的候选表）时取当前资料的
  /// 指纹——用户认可的表在资料变化前一直被复用，不会下一次运行就被 AI 重新生成盖掉。
  Future<SubtitleGlossary> saveGlossary(
    SubtitleWorkContext work,
    List<SubtitleGlossaryEntry> entries, {
    SubtitleGlossary? previous,
  }) async {
    final Map<String, SubtitleGlossaryEntry> before =
        <String, SubtitleGlossaryEntry>{
          for (final SubtitleGlossaryEntry e
              in previous?.entries ?? const <SubtitleGlossaryEntry>[])
            e.ja: e,
        };
    final List<SubtitleGlossaryEntry> marked = <SubtitleGlossaryEntry>[
      for (final SubtitleGlossaryEntry e in entries)
        if (e.ja.trim().isNotEmpty)
          _sameEntry(before[e.ja.trim()], e)
              ? e
              : e.copyWith(ja: e.ja.trim(), userEdited: true),
    ];
    final String fingerprint = (previous?.sourceFingerprint.isNotEmpty ?? false)
        ? previous!.sourceFingerprint
        : subtitleGlossaryFingerprint(
            work,
            webSiteIds: <String>[
              for (final WebKnowledgeSite s in _settings.webKnowledgeSites)
                s.id,
            ],
          );
    final SubtitleGlossary saved = SubtitleGlossary(
      entries: marked,
      sourceFingerprint: fingerprint,
      generatedAt: previous?.generatedAt,
      userEditedAt: _nowMs(),
    );
    await glossaryStore.save(work.workKey, saved);
    return saved;
  }

  static bool _sameEntry(SubtitleGlossaryEntry? a, SubtitleGlossaryEntry b) =>
      a != null &&
      a.ja == b.ja &&
      a.reading == b.reading &&
      a.kind == b.kind &&
      a.note == b.note &&
      a.userEdited == b.userEdited &&
      listEquals(a.misrecognitions, b.misrecognitions);

  /// 只重新生成专名表（编辑页「重新生成」）：ASR 文本取已识别的字幕稿（没有就只凭
  /// 资料）。用户编辑过的条目保留。没指派提供商抛 [AppVideoSubtitleStartRefused]。
  Future<SubtitleGlossary> regenerateGlossary(
    AppVideoSubtitleTarget target, {
    SubtitleCancelToken cancel = const SubtitleNeverCancel(),
  }) async {
    final AiProviderConfig? provider = _settings.proofreadProvider;
    if (provider == null) {
      throw const AppVideoSubtitleStartRefused(
        AppVideoSubtitleStartProblem.noProvider,
      );
    }
    final ({AiTextCompleter completer, void Function() close}) ai =
        _completerFactory(provider);
    final List<WebKnowledgeSite> sites = _settings.webKnowledgeSites;
    final WebKnowledgeClient? web = sites.isEmpty ? null : _webKnowledge(sites);
    try {
      final Directory root = await _jobsRoot();
      final List<List<String>> texts = <List<String>>[
        for (final AppVideoSubtitleEpisode e in target.episodes)
          if (_cachedDrafts(root, e.videoPath)
              case final List<SubtitleDraftCue> drafts)
            <String>[for (final SubtitleDraftCue c in drafts) c.text],
      ];
      final SubtitleGlossaryBuildResult built =
          await SubtitleGlossaryBuilder(
            completer: ai.completer,
            webKnowledge: web,
          ).build(
            context: target.work,
            episodeTexts: texts,
            existing: await glossaryStore.load(target.work.workKey),
            force: true,
            cancel: cancel,
          );
      await glossaryStore.save(target.work.workKey, built.glossary);
      return built.glossary;
    } finally {
      ai.close();
      web?.close();
    }
  }

  // ── 费用预估 ────────────────────────────────────────────────────────────

  /// 预估 S3 校对的 token（S0 / S4 量级远小于 S3，不计）。已完成（`final.json`）
  /// 与整季里已有字幕的集不计；识别过的集按字幕稿逐批重建提示词，没识别的按时长
  /// 粗估（[knownDurationsMs] 优先，其余现探测）。
  Future<AppVideoSubtitleCostEstimate> estimateCost(
    AppVideoSubtitleTarget target, {
    Map<String, int> knownDurationsMs = const <String, int>{},
  }) async {
    final Directory root = await _jobsRoot();
    final List<List<SubtitleDraftCue>> lists = <List<SubtitleDraftCue>>[];
    bool anyByDuration = false;
    int unknown = 0;
    for (final AppVideoSubtitleEpisode e in target.episodes) {
      // 视频旁的字幕在网络盘上时同步 stat 会冻结 UI isolate（BUG-3756）。
      if (target.wholeSeason &&
          await File(_subtitlePathFor(e.videoPath)).exists()) {
        continue;
      }
      final Directory dir = Directory(
        p.join(root.path, videoSubtitleJobId(e.videoPath)),
      );
      if (File(
        p.join(dir.path, VideoSubtitleJobFiles.finalCues),
      ).existsSync()) {
        continue;
      }
      final List<SubtitleDraftCue>? drafts = _cachedDrafts(root, e.videoPath);
      if (drafts != null) {
        lists.add(drafts);
        continue;
      }
      final int? durationMs =
          knownDurationsMs[e.videoPath] ?? await _probeDurationMs(e.videoPath);
      if (durationMs == null || durationMs <= 0) {
        unknown++;
        continue;
      }
      anyByDuration = true;
      final int cues =
          (durationMs / 60000 * kVideoSubtitleEstimateCuesPerMinute).ceil();
      final String text = '人' * kVideoSubtitleEstimateCharsPerCue;
      lists.add(<SubtitleDraftCue>[
        for (int i = 0; i < cues; i++)
          SubtitleDraftCue(
            startMs: i * 1000,
            endMs: i * 1000 + 900,
            text: text,
          ),
      ]);
    }
    final SubtitleGlossary? glossary = await glossaryStore.load(
      target.work.workKey,
    );
    return AppVideoSubtitleCostEstimate(
      basis: lists.isEmpty
          ? AppVideoSubtitleEstimateBasis.nothing
          : anyByDuration
          ? AppVideoSubtitleEstimateBasis.duration
          : AppVideoSubtitleEstimateBasis.drafts,
      episodes: lists.length,
      unknownDurationEpisodes: unknown,
      cost: estimateSubtitleProofreadCost(
        episodes: lists,
        title: target.work.japaneseTitle,
        glossary: glossary == null || glossary.isEmpty ? null : glossary,
      ),
    );
  }

  String _subtitlePathFor(String videoPath) => p.join(
    p.dirname(videoPath),
    '${p.basenameWithoutExtension(videoPath)}.ja.srt',
  );

  /// 任务目录里任一识别器的字幕稿（先按 `state.json` 记的识别器，再按文件名找）。
  List<SubtitleDraftCue>? _cachedDrafts(Directory root, String videoPath) {
    final Directory dir = Directory(
      p.join(root.path, videoSubtitleJobId(videoPath)),
    );
    if (!dir.existsSync()) return null;
    final List<File> files = <File>[
      for (final FileSystemEntity f in dir.listSync())
        if (f is File &&
            p.basename(f.path).startsWith('drafts.') &&
            f.path.endsWith('.json'))
          f,
    ];
    for (final File f in files) {
      try {
        return decodeSubtitleDraftCues(f.readAsStringSync());
      } on FormatException {
        continue;
      }
    }
    return null;
  }

  // ── 任务 ────────────────────────────────────────────────────────────────

  /// 起一个生成任务并立即返回（[AppVideoSubtitleJob.done] 等结束）。同一目标上次
  /// 停下（AI 失败 / 专名表校验 / 取消）时再调就是「继续」：管线从缓存续跑。
  AppVideoSubtitleJob start(
    AppVideoSubtitleTarget target,
    AppVideoSubtitleOptions options,
  ) => _launch(target, options, consistencyOnly: false);

  /// 改了专名表后「只重跑写法统一」：对已经跑过校对的集删掉 S4 及之后的产物，再按
  /// 原识别器（以免重新识别）跑一次。一集都没校对过抛
  /// [AppVideoSubtitleStartProblem.nothingToRerun]。
  Future<AppVideoSubtitleJob> startConsistencyRerun(
    AppVideoSubtitleTarget target,
  ) async {
    final Directory root = await _jobsRoot();
    final bool anyProofread = target.episodes.any(
      (AppVideoSubtitleEpisode e) => Directory(
        p.join(
          root.path,
          videoSubtitleJobId(e.videoPath),
          VideoSubtitleJobFiles.proofreadDir,
        ),
      ).existsSync(),
    );
    if (!anyProofread) {
      throw const AppVideoSubtitleStartRefused(
        AppVideoSubtitleStartProblem.nothingToRerun,
      );
    }
    return _launch(
      target,
      const AppVideoSubtitleOptions(proofread: true),
      consistencyOnly: true,
    );
  }

  AppVideoSubtitleJob _launch(
    AppVideoSubtitleTarget target,
    AppVideoSubtitleOptions options, {
    required bool consistencyOnly,
  }) {
    final AppVideoSubtitleJob? active = _active;
    if (active != null && active.isRunning) {
      throw AppVideoSubtitleStartRefused(
        AppVideoSubtitleStartProblem.busy,
        activeJob: active,
      );
    }
    if (target.episodes.isEmpty) {
      throw const AppVideoSubtitleStartRefused(
        AppVideoSubtitleStartProblem.noLocalEpisodes,
      );
    }
    final AiProviderConfig? provider = options.proofread
        ? _settings.proofreadProvider
        : null;
    if (options.proofread && provider == null) {
      throw const AppVideoSubtitleStartRefused(
        AppVideoSubtitleStartProblem.noProvider,
      );
    }
    final AppVideoSubtitleJob job = AppVideoSubtitleJob._(
      target: target,
      options: options,
      consistencyOnly: consistencyOnly,
    );
    job.mirror = _jobRegistry.register(
      VideoRemoteJob(
        kind: VideoRemoteJobKind.subtitleGenerate,
        bookUid: target.bookUid ?? 'collection:${target.collectionId}',
      ),
    )..onCancel = job.cancel;
    _active = job;
    _latestByTarget[target.key] = job;
    unawaited(_run(job, provider));
    return job;
  }

  Future<void> _run(AppVideoSubtitleJob job, AiProviderConfig? provider) async {
    ({AiTextCompleter completer, void Function() close})? ai;
    WebKnowledgeClient? web;
    try {
      final Directory root = await _jobsRoot();
      final AppVideoSubtitleTarget target = job.target;
      List<String> videoPaths = target.videoPaths;
      VideoSubtitleSegmenterMode mode = job.options.segmenter;
      if (job.consistencyOnly) {
        final List<String> rerun = <String>[];
        String? recognizerId;
        for (final String video in videoPaths) {
          final Directory dir = Directory(
            p.join(root.path, videoSubtitleJobId(video)),
          );
          final bool proofread = Directory(
            p.join(dir.path, VideoSubtitleJobFiles.proofreadDir),
          ).existsSync();
          if (!proofread) continue;
          await resetVideoSubtitleJobFrom(dir, VideoSubtitleStage.consistency);
          rerun.add(video);
          recognizerId ??= _recordedRecognizer(dir);
        }
        if (rerun.isEmpty) {
          job.errorMessage = t.video_subtitle_ai_nothing_to_rerun;
          job._finish(AppVideoSubtitleJobStatus.failed);
          return;
        }
        videoPaths = rerun;
        // 沿用跑校对时的识别器：换识别器会找不到 `drafts.<id>.json`、整集重新识别。
        mode = recognizerId == null || recognizerId == kSlidingRecognizerId
            ? VideoSubtitleSegmenterMode.window
            : VideoSubtitleSegmenterMode.moss;
      }
      throwIfSubtitleCancelled(job._cancel);
      final VideoSubtitleRecognizerChoice choice = await _resolveRecognizer(
        mode: mode,
        mossBackend: job.options.mossBackend,
      );
      final String? mossReason = choice.mossUnavailableReason;
      job
        ..recognizerId = choice.recognizer.id
        ..mossProblem = mossReason == null
            ? null
            : VideoSubtitleMossProblem(
                code: choice.mossUnavailableCode,
                reason: mossReason,
              );
      VideoSubtitleAiConfig? aiConfig;
      if (provider != null) {
        ai = _completerFactory(provider);
        final List<WebKnowledgeSite> sites = _settings.webKnowledgeSites;
        web = sites.isEmpty ? null : _webKnowledge(sites);
        aiConfig = VideoSubtitleAiConfig(
          completer: ai.completer,
          glossaryStore: glossaryStore,
          webKnowledge: web,
          regenerateGlossary: job.options.regenerateGlossary,
        );
      }
      final VideoSubtitlePipeline pipeline = VideoSubtitlePipeline(
        recognizer: choice.recognizer,
        jobsRoot: root,
        ai: aiConfig,
        probeDurationMs: _probeDurationMs,
      );
      final VideoSubtitlePipelineResult result = await pipeline.run(
        videoPaths: videoPaths,
        work: target.work,
        wholeSeason: target.wholeSeason && !job.consistencyOnly,
        onProgress: job._onProgress,
        cancel: job._cancel,
      );
      job.result = result;
      for (final VideoSubtitleEpisodeResult r in result.episodes) {
        for (final AppVideoSubtitleEpisodeProgress e in job.episodes) {
          if (e.episode.videoPath == r.videoPath) e.result = r;
        }
        final String? styledError = r.styledError;
        if (styledError != null) {
          // ASS 是可选阶段：失败不影响 SRT，但要进错误日志可查。
          ErrorLogService.instance.log(
            'video.subtitlePipeline.styledAss',
            '${r.videoPath}: $styledError',
          );
        }
        // 有按参考样式导出的 ASS 就登记它（颜色 / 位置才显示得出来）。
        final String? output = r.styledOutputPath ?? r.outputPath;
        if (!r.exported || output == null) continue;
        final AppVideoSubtitleEpisode? episode = target.episodes
            .where((AppVideoSubtitleEpisode e) => e.videoPath == r.videoPath)
            .firstOrNull;
        if (episode == null || !episode.registersSubtitleSource) continue;
        if (await _registerSubtitleSource(
          episode.bookUid,
          output,
          replace: episode.replacesSubtitleSelection,
          supersedes: <String>{
            // 带样式的 ASS 取代同次导出的 SRT；
            if (r.styledOutputPath != null && r.outputPath != null)
              r.outputPath!,
            // 本轮删掉的旧 ASS（参考没了 / ASS 阶段失败 / 落点换了）：库里还选着
            // 它就切到本轮产物，不然播放器继续找一个已不存在的过期字幕。
            ...r.removedOutputPaths,
          },
        )) {
          job.registeredBookUids.add(episode.bookUid);
        }
      }
      job._finish(AppVideoSubtitleJobStatus.succeeded);
    } on SubtitlePipelineCancelled {
      job._finish(AppVideoSubtitleJobStatus.cancelled);
    } on SubtitleAiRequestFailure catch (failure) {
      job.aiFailure = failure;
      job._finish(AppVideoSubtitleJobStatus.pausedAiFailure);
    } on SubtitleGlossaryValidationFailure catch (failure) {
      job.glossaryFailure = failure;
      job._finish(AppVideoSubtitleJobStatus.glossaryInvalid);
    } on VideoSubtitleRecognizeFailure catch (failure) {
      job.errorMessage = failure.message;
      job._finish(AppVideoSubtitleJobStatus.failed);
    } catch (error, stack) {
      ErrorLogService.instance.log('video.subtitlePipeline', error, stack);
      job.errorMessage = '$error';
      job._finish(AppVideoSubtitleJobStatus.failed);
    } finally {
      ai?.close();
      web?.close();
      if (identical(_active, job)) _active = null;
    }
  }

  /// 滑窗识别器的 id（`SlidingWindowVideoSubtitleRecognizer.id`）。
  static const String kSlidingRecognizerId = 'sliding_mixed';

  static String? _recordedRecognizer(Directory dir) {
    final File state = File(p.join(dir.path, VideoSubtitleJobFiles.state));
    if (!state.existsSync()) return null;
    try {
      final Object? decoded = jsonDecode(state.readAsStringSync());
      final Object? id = decoded is Map ? decoded['recognizer'] : null;
      return id is String && id.isNotEmpty ? id : null;
    } on FormatException {
      return null;
    }
  }

  /// 条目还没有字幕选择（null / 空）时把 [output] 登记成它的外挂字幕。用户选过的
  /// 字幕与显式关闭（`off:` 哨兵）都不覆盖——除非 [replace]（视频页单集入口，见
  /// [AppVideoSubtitleEpisode.replacesSubtitleSelection]）。替换时连同库里缓存的旧
  /// 字幕 cue 一起清掉（与播放页选字幕同一事务写法）：单视频重进时先读 cue 缓存，
  /// 留着旧源的 cue，外挂档案解析失败时会把旧字幕当成新选择显示出来。返回是否写了。
  ///
  /// [supersedes]：被 [output] 取代的本管线产物——同次导出的 SRT（有带样式的 ASS
  /// 时），以及本轮删掉的旧 ASS。条目当前选的正是其中之一（上一次生成登记的）时，
  /// 换成 [output] 不算覆盖用户的选择。
  Future<bool> _registerSubtitleSource(
    String bookUid,
    String output, {
    bool replace = false,
    Set<String> supersedes = const <String>{},
  }) async {
    final VideoBookRow? row = await database.getVideoBookByBookUid(bookUid);
    if (row == null) return false;
    final String? current = row.subtitleSource;
    final VideoBookRepository repo = VideoBookRepository(database);
    if (replace || (current != null && supersedes.contains(current))) {
      if (current == output) return false;
      await repo.saveSubtitleSelection(
        bookUid: bookUid,
        subtitleSource: output,
        cues: const <AudioCue>[],
      );
      return true;
    }
    if (current != null && current.trim().isNotEmpty) return false;
    await repo.updateSubtitleSource(bookUid, output);
    return true;
  }
}
