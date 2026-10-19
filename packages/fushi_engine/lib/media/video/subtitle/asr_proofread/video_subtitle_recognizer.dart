/// 识别阶段（S1 分段 + S2 识别稿）的抽象与现有滑窗实现。
///
/// MOSS 分段 + 按分段识别的实现另行接入（spec 第 3 节 S1/S2），同样实现
/// [VideoSubtitleRecognizer]；[VideoSubtitleRecognizer.id] 进缓存文件名
/// （`drafts.<id>.json`），换识别器不会误用别的识别器的稿。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_asr_subtitles/asr_subtitles.dart'
    show SubtitleCue, parseSrt;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
import 'package:path/path.dart' as p;

/// 识别器进度：0~1 + 文本。
typedef VideoSubtitleRecognizeProgress =
    void Function(double fraction, String message);

/// 识别阶段：视频 → 带时间轴的日语字幕稿。
abstract interface class VideoSubtitleRecognizer {
  /// 稳定 id（进缓存键 `drafts.<id>.json`）；只用 `[a-z0-9_]`。
  String get id;

  /// 识别 [videoPath]。[workDir] 是这一集的任务目录，实现可在里面放中间产物
  /// （抽出的音轨等）以便续跑。取消时抛 [SubtitlePipelineCancelled]。
  Future<List<SubtitleDraftCue>> recognize({
    required String videoPath,
    required Directory workDir,
    required VideoSubtitleRecognizeProgress onProgress,
    required SubtitleCancelToken cancel,
  });
}

/// 识别失败（模型没下载、抽音轨失败、转录没出结果）。
class VideoSubtitleRecognizeFailure implements Exception {
  const VideoSubtitleRecognizeFailure(this.message);

  final String message;

  @override
  String toString() => 'VideoSubtitleRecognizeFailure: $message';
}

/// 抽音轨的卡死判据：已处理媒体时间这么久不推进就强杀。
const Duration kVideoSubtitleAudioStallTimeout = Duration(minutes: 2);

/// 不支持观察式运行的后端（测试替身 / 未知后端）的总时限。
const Duration kVideoSubtitleAudioTimeout = Duration(hours: 1);

/// 抽出的 16 kHz 单声道音轨在任务目录里的文件名：`audio_<任务目录名>.ja.wav`。
///
/// **文件名必须因视频而异**：上游转录服务的任务 id 只哈希「音频文件名 + 字节数 +
/// 模型包」，而 16 kHz 单声道 s16 WAV 的字节数只由时长决定——都叫同一个名字时，
/// 采样数相同的两个视频（NC OP/ED、逐帧等长的各集）会共用上游任务目录、拿回对方的
/// 转录稿。任务目录名本身就是 `videoSubtitleJobId`（视频文件名 + 字节数的 SHA-1）。
String videoSubtitleAudioFileName(Directory workDir) =>
    'audio_${p.basename(workDir.path)}.ja.wav';

/// 从探测结果里挑日语音轨：有 `jpn` / `ja` 标签的取第一条，否则取第一条音轨；
/// 没有音轨返回 null。返回的是**全局流序号**（`-map 0:<index>`）。
int? pickJapaneseAudioStream(List<AudioTrackFacts> tracks) {
  if (tracks.isEmpty) return null;
  for (final AudioTrackFacts t in tracks) {
    final String? lang = t.language?.toLowerCase();
    if (lang == 'jpn' || lang == 'ja') return t.index;
  }
  return tracks.first.index;
}

/// 抽音轨的 ffmpeg 参数（同基准 `common.py` 的 `extract_audio`）。
List<String> videoSubtitleAudioExtractArgs({
  required String videoPath,
  required int streamIndex,
  required String outputPath,
}) => <String>[
  '-y',
  '-v',
  'error',
  '-i',
  videoPath,
  '-map',
  '0:$streamIndex',
  '-ac',
  '1',
  '-ar',
  '16000',
  '-af',
  'aresample=async=1:first_pts=0',
  '-c:a',
  'pcm_s16le',
  '-f',
  'wav',
  outputPath,
];

/// 抽 [videoPath] 的日语音轨到 `<workDir>/`[videoSubtitleAudioFileName]；已有就直接用。
///
/// ffmpeg 走引擎的后端装配点（[resolveFfmpegBackend]：子进程登记表、`FUSHI_FFMPEG`
/// 覆盖、移动端 ffmpeg-kit），不裸起进程；测试用 `setFfmpegBackendForTesting` 换后端。
Future<File> extractVideoSubtitleAudio({
  required String videoPath,
  required Directory workDir,
  required SubtitleCancelToken cancel,
  void Function(Duration processed)? onProcessed,
}) async {
  final File out = File(
    p.join(workDir.path, videoSubtitleAudioFileName(workDir)),
  );
  if (out.existsSync() && out.lengthSync() > 44) return out;
  final FfmpegBackend backend = resolveFfmpegBackend();
  final VideoProbeFacts facts = await probeVideoFacts(videoPath);
  final int? stream = pickJapaneseAudioStream(facts.audioTracks);
  if (stream == null) {
    throw VideoSubtitleRecognizeFailure(
      facts.isUnavailable
          ? 'ffprobe unavailable for $videoPath'
          : 'no audio track in $videoPath',
    );
  }
  await workDir.create(recursive: true);
  final File part = File('${out.path}.part');
  final Completer<void> cancelled = Completer<void>();
  cancel.onCancel(() {
    if (!cancelled.isCompleted) cancelled.complete();
  });
  final List<String> args = videoSubtitleAudioExtractArgs(
    videoPath: videoPath,
    streamIndex: stream,
    outputPath: part.path,
  );
  final FfmpegRunResult result = switch (backend) {
    final FfmpegWatchedRunner watched => await watched.runWatched(
      args,
      FfmpegWatch(
        stallTimeout: kVideoSubtitleAudioStallTimeout,
        onProgress: onProcessed,
        cancel: cancelled.future,
      ),
    ),
    _ => await backend.run(args, kVideoSubtitleAudioTimeout),
  };
  throwIfSubtitleCancelled(cancel);
  if (result.returnCode != 0 || !part.existsSync() || part.lengthSync() <= 44) {
    if (part.existsSync()) part.deleteSync();
    final List<String> lines = result.output.trim().split('\n');
    throw VideoSubtitleRecognizeFailure(
      'audio extraction failed (exit ${result.returnCode}): ${lines.last}',
    );
  }
  if (out.existsSync()) out.deleteSync();
  part.renameSync(out.path);
  return out;
}

/// 现有滑窗识别：抽日语音轨 → 上游 `AsrTranscriptionService`（`mixedAudio`：
/// Parakeet + 15 s/3 s 滑窗）跑 plan → start → run → 读回 `transcript.srt` 与
/// `transcript.tokens.jsonl`。
///
/// 转录任务目录由上游服务管（按音频文件名 + 字节数 + 模型包派生），中途暂停 /
/// 进程重启后再调同一音频即从断点续。
class SlidingWindowVideoSubtitleRecognizer implements VideoSubtitleRecognizer {
  SlidingWindowVideoSubtitleRecognizer({
    required this.serviceFactory,
    this.preference = asr.AsrAccelerationPreference.auto,
  });

  /// 与 `AsrHostJobRunner.serviceFactory` 同形：按素材建服务。本识别器只用
  /// [asr.AsrAudioProfile.mixedAudio]。
  final asr.AsrTranscriptionService Function(asr.AsrAudioProfile profile)
  serviceFactory;
  final asr.AsrAccelerationPreference preference;

  @override
  String get id => 'sliding_mixed';

  @override
  Future<List<SubtitleDraftCue>> recognize({
    required String videoPath,
    required Directory workDir,
    required VideoSubtitleRecognizeProgress onProgress,
    required SubtitleCancelToken cancel,
  }) async {
    onProgress(0, 'extracting audio');
    final File audio = await extractVideoSubtitleAudio(
      videoPath: videoPath,
      workDir: workDir,
      cancel: cancel,
    );
    throwIfSubtitleCancelled(cancel);
    final asr.AsrTranscriptionService service = serviceFactory(
      asr.AsrAudioProfile.mixedAudio,
    );
    const asr.AsrLanguage language = asr.AsrLanguage.japanese;
    final asr.AsrTranscribePlan plan = await service.plan(
      language: language,
      preference: preference,
    );
    if (!plan.modelReady) {
      throw const VideoSubtitleRecognizeFailure(
        'asr models for ja (mixedAudio) are not downloaded',
      );
    }
    onProgress(0, 'loading model');
    final asr.AsrRunningTranscription running = await service.start(
      audioPaths: <String>[audio.path],
      language: language,
      variant: plan.variant,
      preference: preference,
    );
    cancel.onCancel(running.requestPause);
    asr.AsrTranscribeResult? result;
    try {
      await for (final asr.AsrTranscribeEvent e in running.run()) {
        switch (e) {
          case asr.AsrTranscribeProgressEvent(
            progress: final asr.AsrTranscribeProgress pr,
          ):
            onProgress(pr.fraction ?? 0, 'transcribing');
          case asr.AsrTranscribePausedEvent():
            throwIfSubtitleCancelled(cancel);
          case asr.AsrTranscribeFinishedEvent(
            result: final asr.AsrTranscribeResult r,
          ):
            result = r;
        }
      }
    } finally {
      await running.dispose();
    }
    throwIfSubtitleCancelled(cancel);
    final asr.AsrTranscribeResult done =
        result ??
        (throw const VideoSubtitleRecognizeFailure(
          'transcription ended without a result',
        ));
    final List<SubtitleCue> cues = parseSrt(
      await File(done.srtPath).readAsString(),
    );
    final List<asr.AsrCueTokenTiming>? timings =
        await asr.AsrTranscriptionService.readCueTokenTimings(
          done.srtPath,
          expectedCount: cues.length,
        );
    return <SubtitleDraftCue>[
      for (int i = 0; i < cues.length; i++)
        SubtitleDraftCue(
          startMs: cues[i].startMs,
          endMs: cues[i].endMs,
          text: cues[i].text.replaceAll('\n', ' ').trim(),
          tokenTiming: timings?[i],
        ),
    ];
  }
}
