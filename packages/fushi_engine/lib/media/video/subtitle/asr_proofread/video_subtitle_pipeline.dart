/// 视频日语字幕管线的编排（spec `2026-10-19-video-asr-llm-subtitle-pipeline` 第 3、5 节；
/// 整体顺序移植自基准 `subtitle_series.py`，导出规则移植自 `export_final.py`）。
///
/// 单集与整季同一入口 [VideoSubtitlePipeline.run]（整季 = 多个视频共享一个作品
/// 上下文）：
///
/// ```
/// 识别全部集 → S0 专名表（每作品一次）→ 每集 S3 校对 → S4 写法统一
///   → 短视频 S5 歌曲判定 → S5 长条拆分（注入点）→ 导出 <视频名>.<后缀>.srt
/// ```
///
/// AI 关闭（[VideoSubtitlePipeline.ai] 为 null）时跳过 S0/S3/S4/歌曲判定，只做
/// 识别 + 拆分 + 导出。
///
/// 任务目录 `<jobsRoot>/<videoSubtitleJobId(视频)>/` 里落各阶段产物：
/// `drafts.<识别器 id>.json`、`proofread/<批>.json`、`consistency.json`、
/// `final.json`、`state.json`；**已落盘的阶段视为完成**，续跑直接复用。AI 请求
/// 失败抛 [SubtitleAiRequestFailure]，缓存保留，重跑即续。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_asr_subtitles/asr_subtitles.dart'
    show SubtitleCue, SubtitleFormat, renderSubtitles;
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_clip_classifier.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_consistency_pass.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_builder.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_proofreader.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
import 'package:path/path.dart' as p;

/// 管线阶段（进度回调与断点重置用）。
enum VideoSubtitleStage {
  recognize,
  glossary,
  proofread,
  consistency,
  songCheck,
  split,
  export,
}

/// 一次进度回报。[fraction] 是**该阶段内**的 0~1（整季时按集数折算）。
class VideoSubtitleProgress {
  const VideoSubtitleProgress({
    required this.stage,
    required this.fraction,
    required this.message,
    this.videoPath,
    this.episodeIndex,
    this.episodeCount,
  });

  final VideoSubtitleStage stage;
  final double fraction;
  final String message;

  /// 当前在处理的视频（作品级阶段 S0 / 歌曲判定为 null）。
  final String? videoPath;
  final int? episodeIndex;
  final int? episodeCount;

  @override
  String toString() =>
      'VideoSubtitleProgress(${stage.name} '
      '${(fraction * 100).toStringAsFixed(0)}% $message)';
}

/// 长条拆分注入点（S5；上游 `asr_subtitles` 的拆分 API 接入前为 null = 不拆）。
/// 只许改时间切分与文字分配，不许增删正文。
typedef SubtitleDisplaySplitter =
    List<SubtitleDraftCue> Function(List<SubtitleDraftCue> cues);

/// 一集的最终去向。
enum VideoSubtitleEpisodeStatus {
  /// 写了 `<视频名>.<后缀>.srt`。
  exported,

  /// 同名字幕已存在（不是本管线写的），改写了 `<视频名>.<后缀>.asr.srt`。
  exportedAsAsr,

  /// 整季模式：这一集已有 `<视频名>.<后缀>.srt`，没识别。
  skippedExistingSubtitle,

  /// 同名字幕与 `.asr.srt` 都已存在且都不是本管线写的：不覆盖，跳过。
  skippedBothExist,

  /// 短视频被判为纯歌曲（NC OP/ED、MV）。
  skippedSong,

  /// 不足 3 行，或 ≥60% 的行是 `♪` 歌词：当作歌曲 / 片段，不导出。
  skippedNoDialogue,
}

/// 一集的结果。
class VideoSubtitleEpisodeResult {
  const VideoSubtitleEpisodeResult({
    required this.videoPath,
    required this.status,
    this.outputPath,
    this.reason,
    this.cueCount = 0,
  });

  final String videoPath;
  final VideoSubtitleEpisodeStatus status;

  /// 写出的字幕路径（导出时）。
  final String? outputPath;

  /// 跳过的原因（英文短句，排查用；UI 按 [status] 出文案）。
  final String? reason;
  final int cueCount;

  bool get exported =>
      status == VideoSubtitleEpisodeStatus.exported ||
      status == VideoSubtitleEpisodeStatus.exportedAsAsr;
}

/// 一次管线运行的结果。
class VideoSubtitlePipelineResult {
  const VideoSubtitlePipelineResult({
    required this.episodes,
    required this.usage,
    this.glossary,
    this.glossaryRegenerated = false,
  });

  final List<VideoSubtitleEpisodeResult> episodes;

  /// 累计 AI 用量：本次调用的 + 各阶段缓存里记着的当时用量（续跑后也是整任务的
  /// 总账）。专名表只计本次真生成的那一次（存储契约不存用量）。
  final SubtitleAiUsageTally usage;

  /// 本次用的专名表（AI 关闭 / 无需校对时为 null）。
  final SubtitleGlossary? glossary;
  final bool glossaryRegenerated;
}

/// AI 校对的装配：null = AI 关闭。
class VideoSubtitleAiConfig {
  const VideoSubtitleAiConfig({
    required this.completer,
    required this.glossaryStore,
    this.webKnowledge,
    this.proofreadConcurrency = 4,
    this.regenerateGlossary = false,
  });

  final AiTextCompleter completer;
  final SubtitleGlossaryStore glossaryStore;
  final WebKnowledgeClient? webKnowledge;

  /// S3 同时在途的批数（提供商 rpm 由 `AiChatClient` 限频器把关）。
  final int proofreadConcurrency;

  /// 资料没变也重新生成专名表（用户点「重新生成」）。
  final bool regenerateGlossary;
}

/// 任务目录名：`sha1(视频文件名 + '|' + 字节数)`（文件不存在按 0 字节）。
String videoSubtitleJobId(String videoPath) {
  final File f = File(videoPath);
  final int bytes = f.existsSync() ? f.lengthSync() : 0;
  return sha1
      .convert(utf8.encode('${p.basename(videoPath)}|$bytes'))
      .toString();
}

/// 各阶段产物的文件名。
abstract final class VideoSubtitleJobFiles {
  static String drafts(String recognizerId) => 'drafts.$recognizerId.json';
  static const String proofreadDir = 'proofread';
  static const String consistency = 'consistency.json';
  static const String finalCues = 'final.json';
  static const String state = 'state.json';

  /// 整个 [VideoSubtitlePipeline.jobsRoot] 共用的歌曲判定缓存（按任务 id）。
  static const String clipKinds = 'clip_kinds.json';
}

/// 让某一集从 [stage] 起重跑：删掉该阶段及之后的产物（例如用户改了专名表后只重跑
/// S4：`resetVideoSubtitleJobFrom(dir, VideoSubtitleStage.consistency)`）。
Future<void> resetVideoSubtitleJobFrom(
  Directory jobDir,
  VideoSubtitleStage stage, {
  String? recognizerId,
}) async {
  Future<void> rm(String name) async {
    final FileSystemEntity e =
        FileSystemEntity.isDirectorySync(p.join(jobDir.path, name))
        ? Directory(p.join(jobDir.path, name))
        : File(p.join(jobDir.path, name));
    if (e.existsSync()) await e.delete(recursive: true);
  }

  final int from = stage.index;
  if (from <= VideoSubtitleStage.recognize.index && recognizerId != null) {
    await rm(VideoSubtitleJobFiles.drafts(recognizerId));
  }
  if (from <= VideoSubtitleStage.proofread.index) {
    await rm(VideoSubtitleJobFiles.proofreadDir);
  }
  if (from <= VideoSubtitleStage.consistency.index) {
    await rm(VideoSubtitleJobFiles.consistency);
  }
  if (from <= VideoSubtitleStage.split.index) {
    await rm(VideoSubtitleJobFiles.finalCues);
  }
}

/// 管线写字幕时在 `state.json` 里记下的作者标记。
const String kVideoSubtitlePipelineWriter = 'fushi-video-subtitle-pipeline';

/// 视频字幕管线。
class VideoSubtitlePipeline {
  VideoSubtitlePipeline({
    required this.recognizer,
    required this.jobsRoot,
    this.ai,
    this.displaySplitter,
    this.subtitleSuffix = 'ja',
    Future<int?> Function(String videoPath)? probeDurationMs,
    DateTime Function()? clock,
  }) : _probeDurationMs = probeDurationMs ?? probeVideoDurationMs,
       _clock = clock ?? DateTime.now;

  final VideoSubtitleRecognizer recognizer;

  /// 任务目录的根（调用方给，如 `<数据根>/asr_jobs/video_subtitles`）。
  final Directory jobsRoot;
  final VideoSubtitleAiConfig? ai;
  final SubtitleDisplaySplitter? displaySplitter;

  /// 输出文件后缀：`<视频名>.<后缀>.srt`。
  final String subtitleSuffix;
  final Future<int?> Function(String videoPath) _probeDurationMs;
  final DateTime Function() _clock;

  /// 目标字幕路径 `<目录>/<视频名>.<后缀>.srt`。
  String subtitlePathFor(String videoPath) => p.join(
    p.dirname(videoPath),
    '${p.basenameWithoutExtension(videoPath)}.$subtitleSuffix.srt',
  );

  /// 同名字幕已存在时的退路 `<视频名>.<后缀>.asr.srt`。
  String asrSubtitlePathFor(String videoPath) => p.join(
    p.dirname(videoPath),
    '${p.basenameWithoutExtension(videoPath)}.$subtitleSuffix.asr.srt',
  );

  Directory jobDirFor(String videoPath) =>
      Directory(p.join(jobsRoot.path, videoSubtitleJobId(videoPath)));

  /// 跑 [videoPaths]（单集传一个；整季传全部并置 [wholeSeason]）。
  ///
  /// 整季模式下已有 `<视频名>.<后缀>.srt` 的集直接跳过（不识别）。取消抛
  /// [SubtitlePipelineCancelled]；AI 请求失败抛 [SubtitleAiRequestFailure]；专名表
  /// 校验两次重做仍不过抛 [SubtitleGlossaryValidationFailure]。三者都保留已落盘
  /// 的产物，重跑即续。
  Future<VideoSubtitlePipelineResult> run({
    required List<String> videoPaths,
    required SubtitleWorkContext work,
    bool wholeSeason = false,
    void Function(VideoSubtitleProgress progress)? onProgress,
    SubtitleCancelToken cancel = const SubtitleNeverCancel(),
  }) async {
    void report(
      VideoSubtitleStage stage,
      double fraction,
      String message, {
      String? videoPath,
      int? index,
    }) => onProgress?.call(
      VideoSubtitleProgress(
        stage: stage,
        fraction: fraction.clamp(0, 1).toDouble(),
        message: message,
        videoPath: videoPath,
        episodeIndex: index,
        episodeCount: index == null ? null : videoPaths.length,
      ),
    );

    final SubtitleAiUsageTally usage = SubtitleAiUsageTally();
    final List<VideoSubtitleEpisodeResult?> results =
        List<VideoSubtitleEpisodeResult?>.filled(videoPaths.length, null);
    final List<_Episode> episodes = <_Episode>[];

    // 1. 识别全部集（整季模式先剔除已有字幕的集）。
    for (int i = 0; i < videoPaths.length; i++) {
      throwIfSubtitleCancelled(cancel);
      final String video = videoPaths[i];
      if (wholeSeason && File(subtitlePathFor(video)).existsSync()) {
        results[i] = VideoSubtitleEpisodeResult(
          videoPath: video,
          status: VideoSubtitleEpisodeStatus.skippedExistingSubtitle,
          outputPath: subtitlePathFor(video),
          reason: 'subtitle already exists',
        );
        continue;
      }
      final Directory dir = jobDirFor(video);
      await dir.create(recursive: true);
      final _JobState state = _JobState.load(dir);
      final File draftsFile = File(
        p.join(dir.path, VideoSubtitleJobFiles.drafts(recognizer.id)),
      );
      List<SubtitleDraftCue>? drafts = _readCues(draftsFile);
      if (drafts == null) {
        drafts = await recognizer.recognize(
          videoPath: video,
          workDir: dir,
          cancel: cancel,
          onProgress: (double f, String message) => report(
            VideoSubtitleStage.recognize,
            (i + f) / videoPaths.length,
            message,
            videoPath: video,
            index: i,
          ),
        );
        await writeSubtitleJobFileAtomic(
          draftsFile,
          encodeSubtitleDraftCues(drafts),
        );
      }
      final int durationMs =
          state.durationMs ??
          await _probeDurationMs(video) ??
          (drafts.isEmpty ? 0 : drafts.last.endMs);
      state
        ..videoPath = video
        ..recognizerId = recognizer.id
        ..durationMs = durationMs;
      await state.save(dir);
      report(
        VideoSubtitleStage.recognize,
        (i + 1) / videoPaths.length,
        'recognized',
        videoPath: video,
        index: i,
      );
      episodes.add(
        _Episode(
          index: i,
          video: video,
          dir: dir,
          drafts: drafts,
          state: state,
        ),
      );
    }

    final VideoSubtitleAiConfig? aiConfig = ai;
    SubtitleGlossary? glossary;
    bool glossaryRegenerated = false;

    // 已有 final.json 的集不再校对；它们记着的用量照样进总账。
    final List<_Episode> pending = <_Episode>[];
    for (final _Episode e in episodes) {
      final _FinalCues? done = _readFinal(e.finalFile);
      if (done == null) {
        pending.add(e);
      } else {
        e.finalCues = done.cues;
        usage.addTally(done.usage);
      }
    }

    // 2. S0 专名表（每作品一次；ASR 文本只作身份确认，先长后短取样）。
    if (aiConfig != null && pending.isNotEmpty) {
      throwIfSubtitleCancelled(cancel);
      report(VideoSubtitleStage.glossary, 0, 'building glossary');
      final List<_Episode> ordered = <_Episode>[
        ...episodes.where((_Episode e) => !e.isShort),
        ...episodes.where((_Episode e) => e.isShort),
      ];
      final SubtitleGlossary? existing = await aiConfig.glossaryStore.load(
        work.workKey,
      );
      final SubtitleGlossaryBuildResult built =
          await SubtitleGlossaryBuilder(
            completer: aiConfig.completer,
            webKnowledge: aiConfig.webKnowledge,
            clock: _clock,
          ).build(
            context: work,
            episodeTexts: <List<String>>[
              for (final _Episode e in ordered)
                <String>[for (final SubtitleDraftCue c in e.drafts) c.text],
            ],
            existing: existing,
            force: aiConfig.regenerateGlossary,
            cancel: cancel,
          );
      usage.addTally(built.usage);
      glossary = built.glossary;
      glossaryRegenerated = built.regenerated;
      if (built.regenerated) {
        await aiConfig.glossaryStore.save(work.workKey, built.glossary);
      }
      report(VideoSubtitleStage.glossary, 1, 'glossary ready');
    }

    // 3. 每集 S3 → S4（AI 关闭时识别稿原样往下走）。
    for (int k = 0; k < pending.length; k++) {
      throwIfSubtitleCancelled(cancel);
      final _Episode e = pending[k];
      if (aiConfig == null || glossary == null) {
        e.workingCues = e.drafts;
        continue;
      }
      final SubtitleProofreadResult proofread =
          await SubtitleProofreader(
            completer: aiConfig.completer,
            concurrency: aiConfig.proofreadConcurrency,
          ).proofread(
            cues: e.drafts,
            title: work.japaneseTitle,
            glossary: glossary,
            cacheDir: Directory(
              p.join(e.dir.path, VideoSubtitleJobFiles.proofreadDir),
            ),
            cancel: cancel,
            onProgress: (int done, int total) => report(
              VideoSubtitleStage.proofread,
              (k + done / total) / pending.length,
              'proofreading $done/$total',
              videoPath: e.video,
              index: e.index,
            ),
          );
      e.usage.addTally(proofread.usage);
      throwIfSubtitleCancelled(cancel);
      report(
        VideoSubtitleStage.consistency,
        k / pending.length,
        'unifying spellings',
        videoPath: e.video,
        index: e.index,
      );
      final SubtitleConsistencyResult consistent =
          await SubtitleConsistencyPass(completer: aiConfig.completer).run(
            cues: proofread.cues,
            title: work.japaneseTitle,
            glossary: glossary,
            cacheFile: File(
              p.join(e.dir.path, VideoSubtitleJobFiles.consistency),
            ),
            cancel: cancel,
          );
      e.usage.addTally(consistent.usage);
      e.workingCues = consistent.cues;
    }

    // 4. 短视频整段判 song / dialogue / mixed（一次请求判完；缓存按任务 id）。
    Map<String, SubtitleClipKind> kinds = <String, SubtitleClipKind>{};
    final List<_Episode> shorts = <_Episode>[
      for (final _Episode e in episodes)
        if (e.isShort) e,
    ];
    if (aiConfig != null && shorts.isNotEmpty) {
      throwIfSubtitleCancelled(cancel);
      report(VideoSubtitleStage.songCheck, 0, 'classifying short clips');
      await jobsRoot.create(recursive: true);
      final SubtitleClipClassification classified =
          await SubtitleClipClassifier(completer: aiConfig.completer).classify(
            clips: <String, List<String>>{
              for (final _Episode e in shorts)
                e.jobId: <String>[
                  for (final SubtitleDraftCue c
                      in e.finalCues ?? e.workingCues ?? e.drafts)
                    c.text,
                ],
            },
            title: work.japaneseTitle,
            cacheFile: File(
              p.join(jobsRoot.path, VideoSubtitleJobFiles.clipKinds),
            ),
            cancel: cancel,
          );
      kinds = classified.kinds;
      usage.addTally(classified.usage);
      report(VideoSubtitleStage.songCheck, 1, 'classified');
    }

    // 5. 拆分 → final.json → 导出。
    for (int k = 0; k < episodes.length; k++) {
      throwIfSubtitleCancelled(cancel);
      final _Episode e = episodes[k];
      if (e.finalCues == null) {
        report(
          VideoSubtitleStage.split,
          k / episodes.length,
          'splitting',
          videoPath: e.video,
          index: e.index,
        );
        final List<SubtitleDraftCue> working = e.workingCues ?? e.drafts;
        e.finalCues = displaySplitter?.call(working) ?? working;
        await writeSubtitleJobFileAtomic(
          e.finalFile,
          const JsonEncoder.withIndent(' ').convert(<String, Object?>{
            'cues': <Map<String, Object?>>[
              for (final SubtitleDraftCue c in e.finalCues!) c.toJson(),
            ],
            'usage': e.usage.toJson(),
          }),
        );
        usage.addTally(e.usage);
      }
      report(
        VideoSubtitleStage.export,
        k / episodes.length,
        'exporting',
        videoPath: e.video,
        index: e.index,
      );
      results[e.index] = kinds[e.jobId] == SubtitleClipKind.song
          ? VideoSubtitleEpisodeResult(
              videoPath: e.video,
              status: VideoSubtitleEpisodeStatus.skippedSong,
              reason: 'short clip classified as song',
            )
          : await _export(e);
    }
    report(VideoSubtitleStage.export, 1, 'done');

    return VideoSubtitlePipelineResult(
      episodes: <VideoSubtitleEpisodeResult>[
        for (final VideoSubtitleEpisodeResult? r in results) r!,
      ],
      usage: usage,
      glossary: glossary,
      glossaryRegenerated: glossaryRegenerated,
    );
  }

  /// 导出规则（同 `export_final.py`）：不足 3 行或 ≥60% 是 `♪` 不导出；目标已存在
  /// 且不是本管线写的就改写 `.asr.srt`；那个也存在且不是本管线写的就跳过。
  Future<VideoSubtitleEpisodeResult> _export(_Episode e) async {
    final List<SubtitleDraftCue> cues = List<SubtitleDraftCue>.of(e.finalCues!)
      ..sort(
        (SubtitleDraftCue a, SubtitleDraftCue b) =>
            a.startMs.compareTo(b.startMs),
      );
    final int lyrics = cues
        .where((SubtitleDraftCue c) => c.text.startsWith('♪'))
        .length;
    if (cues.length < 3 || lyrics >= 0.6 * cues.length) {
      return VideoSubtitleEpisodeResult(
        videoPath: e.video,
        status: VideoSubtitleEpisodeStatus.skippedNoDialogue,
        reason: '${cues.length} lines, $lyrics lyric lines',
        cueCount: cues.length,
      );
    }
    final String srt = renderSubtitles(<SubtitleCue>[
      for (int i = 0; i < cues.length; i++)
        SubtitleCue(
          index: i + 1,
          startMs: cues[i].startMs,
          // 同基准：每条至少显示 0.3 s。
          endMs: cues[i].endMs < cues[i].startMs + 300
              ? cues[i].startMs + 300
              : cues[i].endMs,
          text: cues[i].text,
        ),
    ], SubtitleFormat.srt);
    final String target = subtitlePathFor(e.video);
    final String fallback = asrSubtitlePathFor(e.video);
    final String? path = !File(target).existsSync() || e.state.wrote(target)
        ? target
        : !File(fallback).existsSync() || e.state.wrote(fallback)
        ? fallback
        : null;
    if (path == null) {
      return VideoSubtitleEpisodeResult(
        videoPath: e.video,
        status: VideoSubtitleEpisodeStatus.skippedBothExist,
        reason:
            'both ${p.basename(target)} and ${p.basename(fallback)} '
            'exist and were not written by this pipeline',
        cueCount: cues.length,
      );
    }
    final List<int> bytes = utf8.encode(srt);
    await writeSubtitleJobFileAtomic(File(path), srt);
    e.state.exports[path] = sha1.convert(bytes).toString();
    await e.state.save(e.dir);
    return VideoSubtitleEpisodeResult(
      videoPath: e.video,
      status: path == target
          ? VideoSubtitleEpisodeStatus.exported
          : VideoSubtitleEpisodeStatus.exportedAsAsr,
      outputPath: path,
      cueCount: cues.length,
    );
  }

  static List<SubtitleDraftCue>? _readCues(File f) {
    if (!f.existsSync()) return null;
    try {
      return decodeSubtitleDraftCues(f.readAsStringSync());
    } on FormatException {
      return null;
    }
  }

  static _FinalCues? _readFinal(File f) {
    if (!f.existsSync()) return null;
    try {
      final Object? decoded = jsonDecode(f.readAsStringSync());
      if (decoded is! Map) return null;
      final Object? u = decoded['usage'];
      return _FinalCues(
        cues: decodeSubtitleDraftCues(f.readAsStringSync()),
        usage: u is Map
            ? SubtitleAiUsageTally.fromJson(u.cast<String, Object?>())
            : SubtitleAiUsageTally(),
      );
    } on FormatException {
      return null;
    }
  }
}

class _FinalCues {
  const _FinalCues({required this.cues, required this.usage});

  final List<SubtitleDraftCue> cues;
  final SubtitleAiUsageTally usage;
}

/// 管线内部的一集。
class _Episode {
  _Episode({
    required this.index,
    required this.video,
    required this.dir,
    required this.drafts,
    required this.state,
  });

  final int index;
  final String video;
  final Directory dir;
  final List<SubtitleDraftCue> drafts;
  final _JobState state;

  /// S3/S4 之后、拆分之前。
  List<SubtitleDraftCue>? workingCues;

  /// 拆分之后（= `final.json`）。
  List<SubtitleDraftCue>? finalCues;

  /// 这一集 S3 + S4 的用量（写进 `final.json`）。
  final SubtitleAiUsageTally usage = SubtitleAiUsageTally();

  File get finalFile => File(p.join(dir.path, VideoSubtitleJobFiles.finalCues));

  /// 任务 id（= 任务目录名），也是歌曲判定缓存的键。
  String get jobId => p.basename(dir.path);

  bool get isShort =>
      (state.durationMs ?? 0) > 0 && state.durationMs! < kSubtitleShortClipMs;
}

/// `state.json`：视频路径、识别器、时长，以及本管线写过哪些字幕（路径 → 内容 sha1，
/// 用来认「这个已存在的字幕是不是我写的」）。
class _JobState {
  _JobState();

  factory _JobState.load(Directory dir) {
    final File f = File(p.join(dir.path, VideoSubtitleJobFiles.state));
    final _JobState s = _JobState();
    if (!f.existsSync()) return s;
    try {
      final Object? decoded = jsonDecode(f.readAsStringSync());
      if (decoded is! Map) return s;
      s
        ..videoPath = decoded['videoPath'] as String?
        ..recognizerId = decoded['recognizer'] as String?
        ..durationMs = (decoded['durationMs'] as num?)?.round();
      final Object? exports = decoded['exports'];
      if (exports is Map) {
        exports.forEach((Object? k, Object? v) {
          if (k is String && v is String) s.exports[k] = v;
        });
      }
    } on FormatException {
      return _JobState();
    }
    return s;
  }

  String? videoPath;
  String? recognizerId;
  int? durationMs;
  final Map<String, String> exports = <String, String>{};

  /// [path] 现在的内容是不是本管线上次写进去的那份。
  bool wrote(String path) {
    final String? recorded = exports[path];
    final File f = File(path);
    if (recorded == null || !f.existsSync()) return false;
    return sha1.convert(f.readAsBytesSync()).toString() == recorded;
  }

  Future<void> save(Directory dir) => writeSubtitleJobFileAtomic(
    File(p.join(dir.path, VideoSubtitleJobFiles.state)),
    const JsonEncoder.withIndent(' ').convert(<String, Object?>{
      'writer': kVideoSubtitlePipelineWriter,
      'videoPath': videoPath,
      'recognizer': recognizerId,
      'durationMs': durationMs,
      'exports': exports,
    }),
  );
}

// ---------------------------------------------------------------------------
// 费用预估
// ---------------------------------------------------------------------------

/// S3 输入 token / 提示词字符。标定：基准《sin 七つの大罪》43 段 134 批，按本仓
/// [buildProofreadBatchPrompt] 的格式重建提示词共 889,857 字符，实计 1,587,877
/// 输入 token（未缓存 + 缓存写入 + 缓存读取），1.78。基准走的是 Claude CLI，每次
/// 调用还带 CLI 自己的系统提示，所以 API 直连时这个系数偏高——预估宁可偏贵。
const double kSubtitleProofreadInputTokensPerChar = 1.78;

/// S3 输出 token / 回复字符（同一次实跑：重建回复 87,068 字符，实计 124,189 输出
/// token，1.43）。回复按 `"<id>": "<正文>", ` 估。
const double kSubtitleProofreadOutputTokensPerChar = 1.43;

/// 费用预估结果（只含 S3；S0 每作品一次、S4 只送可疑行，量级都远小于 S3）。
class SubtitleProofreadCostEstimate {
  const SubtitleProofreadCostEstimate({
    required this.batches,
    required this.promptChars,
    required this.inputTokens,
    required this.outputTokens,
  });

  final int batches;
  final int promptChars;

  /// 全部输入 token（未区分缓存：缓存命中率取决于提供商与是否开了提示缓存）。
  final int inputTokens;
  final int outputTokens;
}

/// 按待校对的字幕稿估 S3 的输入 / 输出 token：逐批重建真实提示词量字符，再乘标定
/// 系数。[glossary] 为 null 时按 [assumedGlossaryEntries] 条、每条 40 字估专名表。
SubtitleProofreadCostEstimate estimateSubtitleProofreadCost({
  required List<List<SubtitleDraftCue>> episodes,
  String title = '',
  SubtitleGlossary? glossary,
  int assumedGlossaryEntries = 40,
  int batchSize = 30,
}) {
  final String glossaryText = glossary == null
      ? List<String>.filled(assumedGlossaryEntries, '人' * 40).join('\n')
      : formatGlossaryForProofread(glossary);
  int batches = 0;
  int promptChars = 0;
  int replyChars = 0;
  for (final List<SubtitleDraftCue> cues in episodes) {
    for (int lo = 0; lo < cues.length; lo += batchSize) {
      final int hi = lo + batchSize > cues.length
          ? cues.length
          : lo + batchSize;
      batches++;
      promptChars += buildProofreadBatchPrompt(
        cues: cues,
        lo: lo,
        hi: hi,
        title: title,
        glossaryText: glossaryText,
      ).runes.length;
      for (int i = lo; i < hi; i++) {
        replyChars += '$i'.length + 8 + cues[i].text.runes.length;
      }
    }
  }
  return SubtitleProofreadCostEstimate(
    batches: batches,
    promptChars: promptChars,
    inputTokens: (promptChars * kSubtitleProofreadInputTokensPerChar).round(),
    outputTokens: (replyChars * kSubtitleProofreadOutputTokensPerChar).round(),
  );
}
