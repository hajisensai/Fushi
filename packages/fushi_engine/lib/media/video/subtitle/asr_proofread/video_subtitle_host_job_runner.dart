/// `kind = video_subtitle`：在 host 上跑视频日语字幕管线（识别 → 专名表 → AI 校对 →
/// 写法统一 → 歌曲判定 → 拆分 → 导出；spec `2026-10-19-video-asr-llm-subtitle-pipeline`
/// 第 5 节）。app 当 host 与无头 fushi_server 共用这一个 runner，两边只注入装配。
///
/// 参数（三选一的输入 + 选项）：
/// - `videoId`：host 库里的视频（`video_books.book_uid`，经注入的 [resolveVideoPath]）；
/// - `collectionId`：整季——合集的全部视频成员按成员顺序排队，已有
///   `<视频名>.<后缀>.srt` 的集跳过；
/// - 都不给：用上传的输入（`input` 指名一个，否则全部上传的视频文件；可带 `title`
///   作作品名）。
/// - `proofread`（bool，默认 true）：AI 校对。要 host 上有给
///   [AiFeature.subtitleProofread] 指派的可用提供商；没有直接拒绝（400），不悄悄
///   退回不校对。
/// - `segmenter`：`auto` / `moss` / `window`（默认 auto）；`mossBackend`：`auto` /
///   `cuda` / `vulkan` / `cpu`（默认 auto）；`regenerateGlossary`（bool）；
///   `suffix`（默认 `ja`）。
///
/// 进度：`ctx.onProgress(总进度, '<阶段>: <消息>')`，阶段名即 [VideoSubtitleStage]。
/// 取消：[HostJobSubtitleCancelToken]。AI 请求失败（额度 / 网络 / 回复反复不合格）
/// 任务以「暂停：AI 请求失败（原因）」结束，管线缓存保留在 [pipelineJobsRoot]
/// 下——重新提交同一视频即从断点续（缓存按视频文件名 + 字节数认，与 host 任务 id
/// 无关）。
///
/// 产物：每集导出的 SRT（库视频还会按管线规则写在视频旁：`<视频名>.ja.srt`，已有
/// 非本管线写的同名字幕时改写 `.ja.asr.srt`）+ `summary.json`（每集状态、AI 用量）。
/// 视频已有别的 ASS 时另有套了它样式的 `.ja.ass`（summary 的 `styledOutput`，
/// 单集任务的 primaryOutput 也指向它）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/moss_provisioning.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_builder.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_drift_store.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_work_context_loader.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';
import 'package:path/path.dart' as p;

/// wire 上的 kind。
const String kVideoSubtitleJobKind = 'video_subtitle';

/// 每集结果 + 用量的产物名。
const String kVideoSubtitleSummaryOutput = 'summary.json';

/// 按偏好挑识别器（宿主把 [resolveVideoSubtitleRecognizer] 连同 ASR 服务工厂、
/// 进程启动器包成这个形状）。
typedef VideoSubtitleRecognizerResolver =
    Future<VideoSubtitleRecognizerChoice> Function(
      VideoSubtitleSegmenterMode mode,
      MossBackendPreference mossBackend,
    );

/// 任务以「暂停」结束（AI 请求失败、专名表校验没过）：缓存保留，处理后重新提交
/// 即续。`toString` 就是给用户看的那句（host job 的 `error` 字段取它）。
class VideoSubtitleJobPaused implements Exception {
  const VideoSubtitleJobPaused(this.message, {this.usage});

  final String message;

  /// 暂停前这次任务已经花掉的 AI 用量（也写进了 [message] 的尾巴：host job 只回传
  /// 错误文本）。
  final SubtitleAiUsageTally? usage;

  @override
  String toString() => message;
}

/// 「本次已调用 AI N 次…」的尾巴；用量未知（null）时为空串。
String videoSubtitleSpentSuffix(SubtitleAiUsageTally? usage) => usage == null
    ? ''
    : '；本次已调用 AI ${usage.calls} 次，输入 ${usage.inputTokens} / 输出 '
          '${usage.outputTokens} token'
          '${usage.hasUnknown ? '（${usage.callsWithoutUsage} 次没带用量）' : ''}';

/// 解析后的任务参数。
class VideoSubtitleJobParams {
  const VideoSubtitleJobParams({
    this.videoId,
    this.collectionId,
    this.input,
    this.title,
    this.proofread = true,
    this.segmenter = VideoSubtitleSegmenterMode.auto,
    this.mossBackend = MossBackendPreference.auto,
    this.regenerateGlossary = false,
    this.suffix = 'ja',
  });

  /// 参数表 → 结构；不合法抛 [FormatException]（→ 400）。
  factory VideoSubtitleJobParams.parse(Map<String, Object?> params) {
    String? text(String key) {
      final String v = '${params[key] ?? ''}'.trim();
      return v.isEmpty ? null : v;
    }

    bool flag(String key, bool fallback) {
      final Object? v = params[key];
      if (v == null) return fallback;
      if (v is bool) return v;
      final String s = '$v'.trim().toLowerCase();
      if (s == 'true' || s == '1') return true;
      if (s == 'false' || s == '0') return false;
      throw FormatException('$kVideoSubtitleJobKind: $key must be a boolean');
    }

    T pick<T extends Enum>(String key, List<T> values, T fallback) {
      final String? v = text(key);
      if (v == null) return fallback;
      for (final T e in values) {
        if (e.name == v) return e;
      }
      throw FormatException(
        '$kVideoSubtitleJobKind: $key must be one of '
        '${values.map((T e) => e.name).join('|')}',
      );
    }

    final String? videoId = text('videoId');
    final String? collectionText = text('collectionId');
    final int? collectionId = collectionText == null
        ? null
        : int.tryParse(collectionText);
    if (collectionText != null && collectionId == null) {
      throw const FormatException(
        '$kVideoSubtitleJobKind: collectionId must be an integer',
      );
    }
    if (videoId != null && collectionId != null) {
      throw const FormatException(
        '$kVideoSubtitleJobKind: give videoId or collectionId, not both',
      );
    }
    final String suffix = text('suffix') ?? 'ja';
    if (!RegExp(r'^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$').hasMatch(suffix)) {
      throw FormatException('$kVideoSubtitleJobKind: bad suffix "$suffix"');
    }
    return VideoSubtitleJobParams(
      videoId: videoId,
      collectionId: collectionId,
      input: text('input'),
      title: text('title'),
      proofread: flag('proofread', true),
      segmenter: pick(
        'segmenter',
        VideoSubtitleSegmenterMode.values,
        VideoSubtitleSegmenterMode.auto,
      ),
      mossBackend: pick(
        'mossBackend',
        MossBackendPreference.values,
        MossBackendPreference.auto,
      ),
      regenerateGlossary: flag('regenerateGlossary', false),
      suffix: suffix,
    );
  }

  final String? videoId;
  final int? collectionId;
  final String? input;
  final String? title;
  final bool proofread;
  final VideoSubtitleSegmenterMode segmenter;
  final MossBackendPreference mossBackend;
  final bool regenerateGlossary;
  final String suffix;
}

/// 管线阶段在任务总进度里占的区间（识别最重）。
const Map<VideoSubtitleStage, (double, double)> kVideoSubtitleStageSpans =
    <VideoSubtitleStage, (double, double)>{
      VideoSubtitleStage.recognize: (0, 0.6),
      VideoSubtitleStage.glossary: (0.6, 0.65),
      VideoSubtitleStage.proofread: (0.65, 0.9),
      VideoSubtitleStage.consistency: (0.9, 0.93),
      VideoSubtitleStage.songCheck: (0.93, 0.95),
      VideoSubtitleStage.split: (0.95, 0.98),
      VideoSubtitleStage.export: (0.98, 1),
    };

/// 阶段内进度 → 任务总进度。
double videoSubtitleOverallProgress(VideoSubtitleProgress progress) {
  final (double lo, double hi) = kVideoSubtitleStageSpans[progress.stage]!;
  return lo + (hi - lo) * progress.fraction.clamp(0, 1);
}

/// 视频字幕 host 任务。
class VideoSubtitleHostJobRunner implements HostJobRunner {
  VideoSubtitleHostJobRunner({
    required this.resolveRecognizer,
    required this.pipelineJobsRoot,
    this.database,
    this.resolveVideoPath,
    this.aiSettings,
    AiChatClient Function()? chatClientFactory,
    this.mossStatus,
    this.probeDurationMs,
    Duration mossStatusCacheTtl = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) : _chatClientFactory = chatClientFactory ?? AiChatClient.new,
       _mossStatusTtl = mossStatusCacheTtl,
       _clock = clock ?? DateTime.now;

  final VideoSubtitleRecognizerResolver resolveRecognizer;

  /// 管线缓存的根（[videoSubtitleJobsRootUnder]）：跨 host 任务存活，重提交即续。
  final Directory pipelineJobsRoot;

  /// host 的库：作品上下文（[SubtitleWorkContextLoader]）、专名表
  /// （[SubtitleGlossaryDriftStore]）、合集成员。null = 不支持 videoId 的作品上下文
  /// 与 collectionId（专名表退回任务目录旁的 JSON 文件）。
  final FushiDatabase Function()? database;

  /// `videoId` → 本机视频文件路径；null = 不支持 videoId。
  final Future<String?> Function(String videoId)? resolveVideoPath;

  /// host 的 AI 指派（每次现取）；null = 不支持 AI 校对。
  final AiSettingsSource Function()? aiSettings;
  final AiChatClient Function() _chatClientFactory;

  /// capability 里报 MOSS 就绪态用；null = 不报。
  final Future<MossProvisionStatus> Function(MossBackendPreference backend)?
  mossStatus;
  final Duration _mossStatusTtl;

  /// MOSS 状态缓存的时钟；测试注入。
  final DateTime Function() _clock;

  /// 视频时长探测（null = ffprobe）；测试注入。
  final Future<int?> Function(String videoPath)? probeDurationMs;
  (DateTime, MossProvisionStatus)? _mossStatusCache;

  @override
  String get kind => kVideoSubtitleJobKind;

  /// [AiFeature.subtitleProofread] 当前能用的提供商；null = 没指派 / 没配全。
  AiProviderConfig? proofreadProvider() {
    final AiSettingsSource? settings = aiSettings?.call();
    if (settings == null) return null;
    return settings.aiFeatureAssignments.resolve(
      AiFeature.subtitleProofread,
      settings.aiProviders,
    );
  }

  @override
  Future<Map<String, Object?>> capability() async {
    final Map<String, Object?> moss = <String, Object?>{};
    final Future<MossProvisionStatus> Function(MossBackendPreference)? probe =
        mossStatus;
    if (probe != null) {
      try {
        final (DateTime, MossProvisionStatus)? cached = _mossStatusCache;
        // 时间戳只在真探测时写：命中缓存也刷新时间戳的话，轮询间隔小于 TTL 时
        // 缓存永不过期，装好 MOSS 后对端会一直看到「未就绪」。
        final MossProvisionStatus status;
        if (cached != null && _clock().difference(cached.$1) < _mossStatusTtl) {
          status = cached.$2;
        } else {
          status = await probe(MossBackendPreference.auto);
          _mossStatusCache = (_clock(), status);
        }
        moss.addAll(<String, Object?>{
          'supported': status.supported,
          'ready': status.ready,
          if (status.decision.backend != null)
            'backend': status.decision.backend!.cliValue,
          if (status.decision.code != null)
            'unavailable': status.decision.code!.name,
          'remainingBytes': status.remainingBytes,
        });
      } on Object catch (e) {
        moss['error'] = '$e';
      }
    }
    return <String, Object?>{
      'supported': true,
      'acceptsVideoId': resolveVideoPath != null,
      'acceptsCollectionId': database != null,
      'proofreadAvailable': proofreadProvider() != null,
      'segmenters': <String>[
        for (final VideoSubtitleSegmenterMode m
            in VideoSubtitleSegmenterMode.values)
          m.name,
      ],
      'mossBackends': <String>[
        for (final MossBackendPreference b in MossBackendPreference.values)
          b.name,
      ],
      if (moss.isNotEmpty) 'moss': moss,
      'outputs': <String>[
        '<video>.<suffix>.srt',
        '<video>.<suffix>.ass',
        kVideoSubtitleSummaryOutput,
      ],
    };
  }

  @override
  void validateParams(Map<String, Object?> params) {
    final VideoSubtitleJobParams parsed = VideoSubtitleJobParams.parse(params);
    if (parsed.videoId != null && resolveVideoPath == null) {
      throw const FormatException(
        '$kVideoSubtitleJobKind: videoId not supported on this host',
      );
    }
    if (parsed.collectionId != null && database == null) {
      throw const FormatException(
        '$kVideoSubtitleJobKind: collectionId not supported on this host',
      );
    }
    if (parsed.proofread && proofreadProvider() == null) {
      throw const FormatException(
        '$kVideoSubtitleJobKind: proofread requested but no AI provider is '
        'assigned to subtitle proofreading on this host '
        '(assign one, or pass proofread=false)',
      );
    }
  }

  @override
  String contentTypeFor(String outputName) {
    if (outputName.endsWith('.srt')) {
      return 'application/x-subrip; charset=utf-8';
    }
    if (outputName.endsWith('.ass')) return 'text/x-ssa; charset=utf-8';
    if (outputName.endsWith('.json')) return 'application/json; charset=utf-8';
    return 'application/octet-stream';
  }

  @override
  Future<HostJobOutcome> run(HostJobContext ctx) async {
    final VideoSubtitleJobParams params = VideoSubtitleJobParams.parse(
      ctx.params,
    );
    final SubtitleCancelToken cancel = HostJobSubtitleCancelToken(ctx.cancel);
    final _Target target = await _resolveTarget(ctx, params);
    if (target.videos.isEmpty) {
      throw const FormatException(
        '$kVideoSubtitleJobKind: no video to process',
      );
    }

    VideoSubtitleAiConfig? ai;
    AiChatClient? client;
    WebKnowledgeClient? web;
    if (params.proofread) {
      final AiProviderConfig? provider = proofreadProvider();
      if (provider == null) {
        throw const VideoSubtitleJobPaused(
          '暂停：AI 请求失败（$kSubtitleAiNotConfigured）',
        );
      }
      client = _chatClientFactory();
      final List<WebKnowledgeSite> sites =
          aiSettings?.call().aiWebKnowledgeSites ?? const <WebKnowledgeSite>[];
      web = sites.isEmpty ? null : WebKnowledgeClient(sites: sites);
      final FushiDatabase? db = database?.call();
      ai = VideoSubtitleAiConfig(
        completer: AiChatTextCompleter(client: client, provider: provider),
        glossaryStore: db != null
            ? SubtitleGlossaryDriftStore(db)
            : SubtitleGlossaryFileStore(
                Directory(p.join(pipelineJobsRoot.path, 'glossaries')),
              ),
        webKnowledge: web,
        proofreadConcurrency: provider.batchConcurrency,
        regenerateGlossary: params.regenerateGlossary,
      );
    }

    try {
      ctx.onProgress(0, 'recognize: choosing recognizer');
      final VideoSubtitleRecognizerChoice choice;
      try {
        choice = await resolveRecognizer(params.segmenter, params.mossBackend);
      } on VideoSubtitleRecognizeFailure catch (e) {
        throw StateError(e.message);
      }
      final VideoSubtitlePipeline pipeline = VideoSubtitlePipeline(
        recognizer: choice.recognizer,
        jobsRoot: pipelineJobsRoot,
        ai: ai,
        subtitleSuffix: params.suffix,
        // 上传的视频在任务输入目录里：字幕直接写进产物目录；库视频写在视频旁。
        exportDir: target.uploaded ? ctx.outputsDir : null,
        probeDurationMs: probeDurationMs,
      );
      final VideoSubtitlePipelineResult result;
      try {
        result = await pipeline.run(
          videoPaths: target.videos,
          work: target.work,
          wholeSeason: target.wholeSeason,
          cancel: cancel,
          onProgress: (VideoSubtitleProgress pr) => ctx.onProgress(
            videoSubtitleOverallProgress(pr),
            '${pr.stage.name}: ${pr.message}'
            '${pr.videoPath == null ? '' : ' (${p.basename(pr.videoPath!)})'}',
          ),
        );
      } on SubtitlePipelineCancelled {
        throw const HostJobCancelledException();
      } on SubtitleAiRequestFailure catch (e) {
        throw VideoSubtitleJobPaused(
          '暂停：AI 请求失败（${e.reason}）${videoSubtitleSpentSuffix(e.usage)}',
          usage: e.usage,
        );
      } on SubtitleGlossaryValidationFailure catch (e) {
        throw VideoSubtitleJobPaused(
          '暂停：专名表校验没通过（$e）${videoSubtitleSpentSuffix(e.usage)}',
          usage: e.usage,
        );
      } on VideoSubtitleRecognizeFailure catch (e) {
        throw StateError(e.message);
      }
      return await _outcome(ctx, choice, result);
    } finally {
      client?.close();
      web?.close();
    }
  }

  Future<HostJobOutcome> _outcome(
    HostJobContext ctx,
    VideoSubtitleRecognizerChoice choice,
    VideoSubtitlePipelineResult result,
  ) async {
    await ctx.outputsDir.create(recursive: true);
    final Map<String, String> outputs = <String, String>{};
    final List<Map<String, Object?>> episodes = <Map<String, Object?>>[];
    String? firstSubtitle;

    /// 把 [path] 收进产物目录（重名补 ` (2)`），返回产物名。
    Future<String> collect(String path) async {
      String name = p.basename(path);
      int n = 2;
      while (outputs.containsKey(name)) {
        name = '${p.basenameWithoutExtension(path)} ($n)${p.extension(path)}';
        n++;
      }
      final File dest = ctx.output(name);
      if (!p.equals(p.absolute(path), p.absolute(dest.path))) {
        await File(path).copy(dest.path);
      }
      outputs[name] = name;
      return name;
    }

    for (final VideoSubtitleEpisodeResult e in result.episodes) {
      String? outputName;
      String? styledName;
      final String? path = e.outputPath;
      final String? styled = e.styledOutputPath;
      if (e.exported && path != null) {
        outputName = await collect(path);
        if (styled != null) styledName = await collect(styled);
        // 套了参考样式的 ASS 是这一集的首选产物（取回端优先加载它）。
        firstSubtitle ??= styledName ?? outputName;
      }
      episodes.add(<String, Object?>{
        'video': p.basename(e.videoPath),
        'status': e.status.name,
        if (e.outputPath != null) 'subtitlePath': e.outputPath,
        if (outputName != null) 'output': outputName,
        if (styled != null) 'styledSubtitlePath': styled,
        if (styledName != null) 'styledOutput': styledName,
        if (e.styleReference != null) 'styleReference': e.styleReference,
        if (e.styledError != null) 'styledError': e.styledError,
        if (e.reason != null) 'reason': e.reason,
        'cues': e.cueCount,
      });
    }
    final Map<String, Object?> summary = <String, Object?>{
      'recognizer': choice.recognizer.id,
      if (choice.mossBackend != null) 'mossBackend': choice.mossBackend!.name,
      if (choice.mossUnavailableReason != null)
        'mossUnavailable': <String, Object?>{
          'code': choice.mossUnavailableCode?.name,
          'reason': choice.mossUnavailableReason,
        },
      'glossaryRegenerated': result.glossaryRegenerated,
      if (result.glossaryIdentityUnverified)
        'glossaryIdentityWarning': <String, Object?>{
          'heard': result.glossaryHeardNames,
          'missing': result.glossaryMissingNames,
        },
      if (result.glossary != null)
        'glossaryEntries': result.glossary!.entries.length,
      'usage': result.usage.toJson(),
      'episodes': episodes,
    };
    await ctx
        .output(kVideoSubtitleSummaryOutput)
        .writeAsString(
          const JsonEncoder.withIndent('  ').convert(summary),
          flush: true,
        );
    outputs[kVideoSubtitleSummaryOutput] = kVideoSubtitleSummaryOutput;
    final int exported = result.episodes
        .where((VideoSubtitleEpisodeResult e) => e.exported)
        .length;
    return HostJobOutcome(
      outputs: outputs,
      primaryOutput: result.episodes.length == 1 && firstSubtitle != null
          ? firstSubtitle
          : kVideoSubtitleSummaryOutput,
      message:
          'exported $exported/${result.episodes.length}'
          '${result.usage.hasUnknown ? ' (usage partly unknown)' : ''}',
    );
  }

  Future<_Target> _resolveTarget(
    HostJobContext ctx,
    VideoSubtitleJobParams params,
  ) async {
    final FushiDatabase? db = database?.call();
    final SubtitleWorkContextLoader? loader = db == null
        ? null
        : SubtitleWorkContextLoader(db);
    final String? videoId = params.videoId;
    if (videoId != null) {
      final Future<String?> Function(String)? resolve = resolveVideoPath;
      if (resolve == null) {
        throw const FormatException(
          '$kVideoSubtitleJobKind: videoId not supported on this host',
        );
      }
      final String? path = await resolve(videoId);
      if (path == null) {
        throw FormatException(
          '$kVideoSubtitleJobKind: unknown videoId $videoId',
        );
      }
      final SubtitleWorkContext work =
          await loader?.forBook(videoId) ??
          _fallbackWork(path, params.title, useFolder: true);
      return _Target(videos: <String>[path], work: work);
    }
    final int? collectionId = params.collectionId;
    if (collectionId != null) {
      if (loader == null) {
        throw const FormatException(
          '$kVideoSubtitleJobKind: collectionId not supported on this host',
        );
      }
      final SubtitleWorkContext? work = await loader.forCollection(
        collectionId,
      );
      if (work == null) {
        throw FormatException(
          '$kVideoSubtitleJobKind: unknown collectionId $collectionId',
        );
      }
      final List<String> videos = <String>[
        for (final String v in await loader.collectionVideoPaths(collectionId))
          if (File(v).existsSync()) v,
      ];
      return _Target(videos: videos, work: work, wholeSeason: true);
    }
    final List<File> uploaded;
    final String? named = params.input;
    if (named != null) {
      final File f = ctx.input(named);
      if (!f.existsSync()) {
        throw FormatException(
          '$kVideoSubtitleJobKind: input "$named" not uploaded',
        );
      }
      uploaded = <File>[f];
    } else {
      uploaded =
          ctx.inputsDir.existsSync()
                ? ctx.inputsDir
                      .listSync()
                      .whereType<File>()
                      .where(
                        (File f) => kVideoExtensions.contains(
                          p.extension(f.path).toLowerCase(),
                        ),
                      )
                      .toList()
                : <File>[]
            ..sort((File a, File b) => a.path.compareTo(b.path));
    }
    if (uploaded.isEmpty) {
      throw const FormatException(
        '$kVideoSubtitleJobKind: no videoId / collectionId and no video uploaded',
      );
    }
    return _Target(
      videos: <String>[for (final File f in uploaded) f.path],
      // 上传目录每个任务都不同，不能当作品键：只认标题。
      work: _fallbackWork(uploaded.first.path, params.title, useFolder: false),
      wholeSeason: uploaded.length > 1,
      uploaded: true,
    );
  }

  /// 没有库内身份：作品名取 `title` 参数，否则视频所在目录名（上传的取文件名）。
  static SubtitleWorkContext _fallbackWork(
    String videoPath,
    String? title, {
    required bool useFolder,
  }) {
    final String folder = p.dirname(videoPath);
    final String name =
        title ??
        (useFolder
            ? p.basename(folder)
            : p.basenameWithoutExtension(videoPath));
    return SubtitleWorkContext(
      workKey: fallbackSubtitleWorkKey(
        folderPath: useFolder && title == null ? folder : null,
        title: name,
      ),
      title: name,
    );
  }
}

class _Target {
  const _Target({
    required this.videos,
    required this.work,
    this.wholeSeason = false,
    this.uploaded = false,
  });

  final List<String> videos;
  final SubtitleWorkContext work;
  final bool wholeSeason;
  final bool uploaded;
}
