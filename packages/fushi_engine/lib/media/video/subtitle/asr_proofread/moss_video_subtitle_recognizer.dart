/// MOSS 分段 + Parakeet 按分段识别（spec `2026-10-19-video-asr-llm-subtitle-pipeline`
/// 第 3 节 S1/S2；对应基准 `C:\asr_bench\scripts\run_onseg.py pk moss`）。
///
/// ```
/// 视频 ─extractVideoSubtitleAudio─▶ 16 kHz 日语音轨 wav
///   ─MossRunner（audio.cpp CLI）─▶ 带说话人的句级时间轴 + MOSS 正文  → segments.moss.json
///   ─AsrTranscriptionService(mixedAudio).start(segments:)─▶ Parakeet 每段一条 cue
///   ─按时间对回─▶ SubtitleDraftCue{主稿 = Parakeet，候选 = [MOSS]，说话人 = MOSS}
/// ```
///
/// - 时间轴永远是 MOSS 的分段：上游「按给定分段识别」保证每段至多一条 cue、起止
///   严格等于分段，所以按 `(startMs, endMs)` 逐一配对；配不上就是上游契约被破坏，
///   直接报错，不猜。
/// - Parakeet 识别为空的段丢弃（上游不出 cue；同基准 `if t`）。被丢段的 MOSS 正文
///   仍按「与哪条主稿重叠最多」挂到那条上当候选（基准 `llm_fix.py` 的 `assign`）。
/// - 续跑：抽出的音轨、MOSS 每块的结果（`<任务目录>/moss/`，块缓存带指纹）、整段
///   MOSS 时间轴（`segments.moss.json`）、上游转录任务目录都各自落盘；取消 / 重启
///   后再跑同一集只补没做完的部分。
/// - 取消：MOSS 子进程经 [asr.AsrCancellationToken] 当场杀掉；Parakeet 走转录任务的
///   暂停。两者都换成 [SubtitlePipelineCancelled]。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_asr_subtitles/asr_subtitles.dart'
    show SubtitleCue, parseSrt;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:path/path.dart' as p;

/// 识别器 id（进 `drafts.<id>.json`）。与 audio.cpp 后端无关：同一块音频 CUDA 与
/// Vulkan 的转写实测只差几个字，换后端不该让已完成的稿作废。
const String kMossVideoSubtitleRecognizerId = 'moss_pk';

/// 整段 MOSS 时间轴在任务目录里的文件名（spec 第 3 节「产物与加载」）。
const String kMossSegmentsFileName = 'segments.moss.json';

/// MOSS 每块缓存的子目录。
const String kMossChunkCacheDirName = 'moss';

/// 进度里各阶段的份额：抽音轨 / MOSS / Parakeet。MOSS 是自回归解码，墙钟时间是
/// Parakeet（CTC 一次前向）的数倍。
const double kMossProgressExtractShare = 0.05;
const double kMossProgressMossShare = 0.65;

/// 16 kHz 单声道 PCM_16 WAV 字节 → float32 样本（`/32768`，与
/// [asr.encodePcm16Wav] 互逆）。按 RIFF 块遍历找 `fmt ` / `data`（ffmpeg 会写
/// `LIST` 块）。格式不是 16 kHz / 单声道 / 16 bit PCM 抛 [FormatException]。
Float32List decodePcm16MonoWav(Uint8List bytes) {
  final ByteData view = ByteData.sublistView(bytes);
  String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const FormatException('not a RIFF/WAVE file');
  }
  int at = 12;
  bool formatOk = false;
  while (at + 8 <= bytes.length) {
    final String id = tag(at);
    final int size = view.getUint32(at + 4, Endian.little);
    final int body = at + 8;
    if (id == 'fmt ') {
      final int format = view.getUint16(body, Endian.little);
      final int channels = view.getUint16(body + 2, Endian.little);
      final int rate = view.getUint32(body + 4, Endian.little);
      final int bits = view.getUint16(body + 14, Endian.little);
      if (format != 1 ||
          channels != 1 ||
          rate != asr.kAsrSampleRate ||
          bits != 16) {
        throw FormatException(
          'wav must be 16 kHz mono PCM_16 '
          '(got format=$format channels=$channels rate=$rate bits=$bits)',
        );
      }
      formatOk = true;
    } else if (id == 'data') {
      if (!formatOk) throw const FormatException('wav data before fmt chunk');
      // ffmpeg 写管道时 data 长度可能是占位值：以文件实际长度为准。
      final int end = body + size > bytes.length || size == 0xFFFFFFFF
          ? bytes.length
          : body + size;
      final int count = (end - body) ~/ 2;
      final Float32List out = Float32List(count);
      for (int i = 0; i < count; i++) {
        out[i] = view.getInt16(body + i * 2, Endian.little) / 32768;
      }
      return out;
    }
    at = body + size + (size.isOdd ? 1 : 0);
  }
  throw const FormatException('wav has no data chunk');
}

/// MOSS 句级 cue → 「按给定分段识别」的分段（毫秒，原样）。
List<asr.AsrSegmentSpan> mossSegmentSpans(List<asr.MossCue> cues) =>
    <asr.AsrSegmentSpan>[
      for (final asr.MossCue c in cues)
        asr.AsrSegmentSpan(startMs: c.startMs, endMs: c.endMs),
    ];

int _overlapMs(int a0, int a1, int b0, int b1) {
  final int lo = a0 > b0 ? a0 : b0;
  final int hi = a1 < b1 ? a1 : b1;
  return hi > lo ? hi - lo : 0;
}

/// 把 Parakeet 按分段识别出的 cue 对回 MOSS 段（纯函数）。
///
/// - [parakeet]：上游转录产出的 cue（每段至多一条，起止 = 分段）；[timings] 与它
///   按下标一一对应（可为 null）。
/// - 每条 Parakeet cue 按 `(startMs, endMs)` 认领一个还没被认领的同区间 MOSS 段
///   （区间相同的多段按出现顺序认领），说话人取该段；认领不到抛
///   [VideoSubtitleRecognizeFailure]。
/// - 候选稿：每个 MOSS 段的正文挂到与它重叠最多的那条保留下来的 Parakeet cue 上
///   （认领关系里重叠就是整段，自然挂回自己），同一条上的多个候选以空格相接成一条
///   （同基准 `' '.join(at[i])`）；与所有保留 cue 都不重叠的（它的 Parakeet 稿为空）
///   丢掉。
/// - Parakeet 正文为空的 cue 丢弃。
List<SubtitleDraftCue> pairParakeetCuesWithMoss({
  required List<asr.MossCue> moss,
  required List<SubtitleCue> parakeet,
  List<asr.AsrCueTokenTiming>? timings,
}) {
  final Map<String, List<int>> unclaimed = <String, List<int>>{};
  for (int i = 0; i < moss.length; i++) {
    unclaimed
        .putIfAbsent('${moss[i].startMs}-${moss[i].endMs}', () => <int>[])
        .add(i);
  }
  final List<SubtitleCue> kept = <SubtitleCue>[];
  final List<asr.AsrCueTokenTiming?> keptTiming = <asr.AsrCueTokenTiming?>[];
  final List<String> keptSpeaker = <String>[];
  for (int i = 0; i < parakeet.length; i++) {
    final SubtitleCue c = parakeet[i];
    final List<int>? queue = unclaimed['${c.startMs}-${c.endMs}'];
    if (queue == null || queue.isEmpty) {
      throw VideoSubtitleRecognizeFailure(
        'parakeet cue ${c.startMs}-${c.endMs} matches no MOSS segment',
      );
    }
    final int owner = queue.removeAt(0);
    final String text = c.text.replaceAll('\n', ' ').trim();
    if (text.isEmpty) continue;
    kept.add(
      SubtitleCue(
        index: c.index,
        startMs: c.startMs,
        endMs: c.endMs,
        text: text,
      ),
    );
    keptTiming.add(timings?[i]);
    keptSpeaker.add(moss[owner].speaker);
  }
  final List<List<String>> alternatives = <List<String>>[
    for (int i = 0; i < kept.length; i++) <String>[],
  ];
  for (final asr.MossCue m in moss) {
    if (m.text.trim().isEmpty) continue;
    int best = 0;
    int bestIndex = -1;
    for (int i = 0; i < kept.length; i++) {
      final int ov = _overlapMs(
        kept[i].startMs,
        kept[i].endMs,
        m.startMs,
        m.endMs,
      );
      if (ov > best) {
        best = ov;
        bestIndex = i;
      }
    }
    if (bestIndex >= 0) alternatives[bestIndex].add(m.text.trim());
  }
  return <SubtitleDraftCue>[
    for (int i = 0; i < kept.length; i++)
      SubtitleDraftCue(
        startMs: kept[i].startMs,
        endMs: kept[i].endMs,
        text: kept[i].text,
        speaker: keptSpeaker[i],
        alternatives: alternatives[i].isEmpty
            ? const <String>[]
            : <String>[alternatives[i].join(' ')],
        tokenTiming: keptTiming[i],
      ),
  ];
}

/// [kMossSegmentsFileName] 的读写（`MossTranscript.toJson` 的形状）。坏文件当没有。
List<asr.MossCue>? readMossSegmentsFile(File file) {
  if (!file.existsSync()) return null;
  try {
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map || decoded['cues'] is! List) return null;
    return <asr.MossCue>[
      for (final Object? c in decoded['cues'] as List<Object?>)
        asr.MossCue.fromJson((c! as Map<Object?, Object?>).cast()),
    ];
  } on Object {
    return null;
  }
}

/// MOSS 分段 + Parakeet 识别。见文件头。
class MossVideoSubtitleRecognizer implements VideoSubtitleRecognizer {
  MossVideoSubtitleRecognizer({
    required this.serviceFactory,
    required this.moss,
    this.preference = asr.AsrAccelerationPreference.auto,
  });

  /// 与 `AsrHostJobRunner.serviceFactory` 同形；本识别器只用
  /// [asr.AsrAudioProfile.mixedAudio]（日语 = Parakeet）。
  final asr.AsrTranscriptionService Function(asr.AsrAudioProfile profile)
  serviceFactory;

  /// 已装好 CLI / 权重 / 后端 / 进程启动器的 MOSS 运行器。
  final asr.MossRunner moss;
  final asr.AsrAccelerationPreference preference;

  @override
  String get id => kMossVideoSubtitleRecognizerId;

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

    // Parakeet 先确认模型在：MOSS 一集要跑好几分钟，跑完才发现缺模型白等。
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

    final List<asr.MossCue> mossCues = await _runMoss(
      audio,
      workDir,
      onProgress,
      cancel,
    );
    throwIfSubtitleCancelled(cancel);
    final List<asr.AsrSegmentSpan> spans = mossSegmentSpans(mossCues);
    if (spans.isEmpty) {
      onProgress(1, 'no speech');
      return const <SubtitleDraftCue>[];
    }

    const double base = kMossProgressExtractShare + kMossProgressMossShare;
    onProgress(base, 'loading model');
    final asr.AsrRunningTranscription running = await service.start(
      audioPaths: <String>[audio.path],
      language: language,
      variant: plan.variant,
      preference: preference,
      segments: spans,
    );
    cancel.onCancel(running.requestPause);
    asr.AsrTranscribeResult? result;
    try {
      await for (final asr.AsrTranscribeEvent e in running.run()) {
        switch (e) {
          case asr.AsrTranscribeProgressEvent(
            progress: final asr.AsrTranscribeProgress pr,
          ):
            onProgress(base + (1 - base) * (pr.fraction ?? 0), 'transcribing');
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
    return pairParakeetCuesWithMoss(
      moss: mossCues,
      parakeet: cues,
      timings: timings,
    );
  }

  /// MOSS 阶段：有 [kMossSegmentsFileName] 就直接用；否则读音轨、跑 MOSS（块缓存在
  /// `<任务目录>/moss/`），整段结果落盘。
  Future<List<asr.MossCue>> _runMoss(
    File audio,
    Directory workDir,
    VideoSubtitleRecognizeProgress onProgress,
    SubtitleCancelToken cancel,
  ) async {
    final File segmentsFile = File(p.join(workDir.path, kMossSegmentsFileName));
    final List<asr.MossCue>? cached = readMossSegmentsFile(segmentsFile);
    if (cached != null) return cached;
    onProgress(kMossProgressExtractShare, 'segmenting (MOSS)');
    final Float32List samples;
    try {
      samples = decodePcm16MonoWav(await audio.readAsBytes());
    } on FormatException catch (e) {
      throw VideoSubtitleRecognizeFailure(
        'unreadable audio ${audio.path}: ${e.message}',
      );
    }
    final asr.AsrCancellationToken token = asr.AsrCancellationToken();
    cancel.onCancel(token.cancel);
    final asr.MossTranscript transcript;
    try {
      transcript = await moss.run(
        samples,
        workDir: Directory(p.join(workDir.path, kMossChunkCacheDirName)),
        cancellation: token,
        onProgress: (asr.MossProgress pr) => onProgress(
          kMossProgressExtractShare + kMossProgressMossShare * pr.fraction,
          'segmenting (MOSS) ${pr.completedChunks} chunks',
        ),
      );
    } on asr.AsrCancelledException {
      throw const SubtitlePipelineCancelled();
    } on asr.MossRunException catch (e) {
      throw VideoSubtitleRecognizeFailure('MOSS failed: $e');
    } on ProcessException catch (e) {
      throw VideoSubtitleRecognizeFailure(
        'cannot start audiocpp_cli (${e.executable}): ${e.message}',
      );
    }
    await writeSubtitleJobFileAtomic(
      segmentsFile,
      const JsonEncoder.withIndent(' ').convert(transcript.toJson()),
    );
    return transcript.cues;
  }
}
