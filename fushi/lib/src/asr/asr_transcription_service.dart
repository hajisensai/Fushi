/// 有声书设备端转录的装配层：模型存储 / 引擎加载 / PCM 源 / 任务目录 三者拼成
/// 一次可运行的 [AsrRunningTranscription]，UI 只与本层对话。
///
/// 任务目录按「音频文件名 + 字节数 + 模型包 id」的 SHA-1 命名
/// （`<appSupport>/asr_jobs/<hash>`），与绝对路径无关：用户把有声书目录挪个位置
/// 再选同一组文件，进度照样接上；同一组音频换语言转录是另一个任务，互不覆盖。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr/asr_engine.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/asr/asr_model_store.dart';
import 'package:fushi/src/asr/asr_pcm_source.dart';
import 'package:fushi/src/asr/asr_transcribe_job.dart';
import 'package:fushi/src/asr/asr_transducer_decoder.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/asr/asr_vad.dart';
import 'package:fushi/src/onnx/model_file_downloader.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';
import 'package:fushi/src/onnx/onnx_inference_ort.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// 切段器种类：默认能量门限（零模型调用，见 `asr_vad.dart` 文件头的实测依据）；
/// silero 作为带背景音乐/噪声音源的可选高质量路径。
enum AsrSegmenterKind { energy, silero }

/// 开跑前的计划：哪个语言包、会用哪个编码器变体、期望落到哪个 EP、模型是否就绪。
@immutable
class AsrTranscribePlan {
  const AsrTranscribePlan({
    required this.language,
    required this.variant,
    required this.expectedProvider,
    required this.modelStatus,
  });

  final AsrLanguage language;
  final AsrEncoderVariant variant;

  /// 按平台策略与本机 EP 集合预期的编码器 EP（真正生效以运行期 resolution 为准）。
  final OnnxExecutionProvider expectedProvider;
  final AsrModelStatus modelStatus;

  bool get modelReady => modelStatus.ready;
  int get bytesToDownload =>
      (modelStatus.totalBytes - modelStatus.obtainedBytes).clamp(
        0,
        modelStatus.totalBytes,
      );
}

/// 一次正在运行的转录（会话 + 任务）。用完必须 [dispose] 释放 native 会话。
class AsrRunningTranscription {
  AsrRunningTranscription({required this.sessions, required this.job});

  final AsrEngineSessions sessions;
  final AsrTranscribeJob job;

  OnnxProviderResolution get encoderResolution => sessions.encoderResolution;

  /// 事件流（一次性；见 [AsrTranscribeJob.run]）。
  Stream<AsrTranscribeEvent> run() => job.run();

  void requestPause() => job.requestPause();

  Future<void> dispose() => sessions.close();
}

/// 装配层。所有依赖可注入以便测试。
class AsrTranscriptionService {
  AsrTranscriptionService({
    AsrEngineLoader? loader,
    AsrPcmSource? pcm,
    Future<AsrModelStore> Function(AsrLanguage language)? openStore,
    Future<Directory> Function()? jobsRoot,
    this.batchSize,
    this.chunkSeconds = 300,
    this.segmenterKind = AsrSegmenterKind.energy,
  }) : _loader = loader ?? AsrEngineLoader(),
       _pcm = pcm ?? FfmpegAsrPcmSource(),
       _openStore = openStore ?? AsrModelStore.open,
       _jobsRoot = jobsRoot ?? _defaultJobsRoot;

  final AsrEngineLoader _loader;
  final AsrPcmSource _pcm;
  final Future<AsrModelStore> Function(AsrLanguage language) _openStore;
  final Future<Directory> Function() _jobsRoot;

  /// 一次 encoder 前向的段数；null 时按编码器实际落到的 EP 取
  /// [defaultBatchSizeFor]。
  final int? batchSize;
  final int chunkSeconds;
  final AsrSegmenterKind segmenterKind;

  /// 默认批次：GPU 上 batch 越大越省逐帧 joiner 的往返（2026-09-05 真机分阶段计时
  /// 里逐帧循环是 ASR 阶段的大头，encoder 本身在 DirectML 上只占零头）；CPU 上
  /// int8 encoder 的算力随 batch 线性增长，取一半平衡内存与往返。
  static int defaultBatchSizeFor(OnnxExecutionProvider encoderProvider) =>
      encoderProvider == OnnxExecutionProvider.cpu ? 16 : 32;

  /// 本平台是否具备设备端转录能力（= 本地 ONNX Runtime 随包）。
  static bool get isSupported => isLocalOnnxRuntimeAvailable;

  static Future<Directory> _defaultJobsRoot() async {
    final Directory support = await AppPaths.supportRootDirectory();
    return Directory(p.join(support.path, 'asr_jobs'));
  }

  Future<AsrModelStore> modelStore(AsrLanguage language) =>
      _openStore(language);

  /// 计算计划：探测 EP → 推荐变体 → 查该语言包的模型状态。
  Future<AsrTranscribePlan> plan({
    required AsrLanguage language,
    required AsrAccelerationPreference preference,
  }) async {
    Set<OnnxExecutionProvider> available = const <OnnxExecutionProvider>{};
    if (preference != AsrAccelerationPreference.cpuOnly) {
      try {
        available = await _loader.availableAcceleratedProviders();
      } catch (_) {
        // 探测失败按 CPU 规划；运行期 loader 会把原因记进 resolution。
        available = const <OnnxExecutionProvider>{};
      }
    }
    final AsrPlatform platform = currentAsrPlatform();
    final AsrEncoderVariant variant = recommendAsrEncoderVariant(
      platform: platform,
      available: available,
      preference: preference,
    );
    final OnnxExecutionProvider expected = selectAsrEncoderProviders(
      platform: platform,
      available: available,
      preference: preference,
      variant: variant,
    ).first;
    final AsrModelStore store = await _openStore(language);
    return AsrTranscribePlan(
      language: language,
      variant: variant,
      expectedProvider: expected,
      modelStatus: await store.status(variant),
    );
  }

  Stream<ModelDownloadEvent> downloadModel({
    required AsrLanguage language,
    required AsrEncoderVariant variant,
  }) async* {
    final AsrModelStore store = await _openStore(language);
    yield* store.download(variant);
  }

  /// 任务目录：文件名 + 字节数 + 模型包 id 的 SHA-1。
  Future<Directory> jobDirFor(
    List<String> audioPaths,
    AsrLanguage language,
  ) async {
    final Directory root = await _jobsRoot();
    return Directory(p.join(root.path, jobIdFor(audioPaths, language)));
  }

  /// 纯函数：由文件名、字节数与模型包 id 派生稳定 id（文件不存在按 0 字节计）。
  static String jobIdFor(List<String> audioPaths, AsrLanguage language) {
    final StringBuffer sb = StringBuffer();
    for (final String path in audioPaths) {
      final File f = File(path);
      final int bytes = f.existsSync() ? f.lengthSync() : 0;
      sb
        ..write(p.basename(path))
        ..write('|')
        ..write(bytes)
        ..write('\n');
    }
    sb
      ..write('model=')
      ..write(asrModelPackFor(language).id)
      ..write('\n');
    return sha1.convert(utf8.encode(sb.toString())).toString();
  }

  /// 已有的任务状态（没有则 null）。
  Future<AsrJobState?> existingState(
    List<String> audioPaths,
    AsrLanguage language,
  ) async {
    final Directory dir = await jobDirFor(audioPaths, language);
    if (!File(p.join(dir.path, AsrJobFiles.state)).existsSync()) return null;
    final ({AsrJobState state, bool fresh}) loaded =
        await AsrTranscribeJob.loadStateDetailed(
          dir,
          audioPaths,
          modelId: asrModelPackFor(language).id,
        );
    return loaded.fresh ? null : loaded.state;
  }

  /// 已完成任务的 SRT 路径（未完成或不存在则 null）。
  Future<String?> finishedSrtPath(
    List<String> audioPaths,
    AsrLanguage language,
  ) async {
    final AsrJobState? state = await existingState(audioPaths, language);
    if (state == null || !state.finished) return null;
    final Directory dir = await jobDirFor(audioPaths, language);
    final File srt = File(p.join(dir.path, AsrJobFiles.srt));
    return srt.existsSync() ? srt.path : null;
  }

  /// 该字幕路径是否是本服务转录出来的产物（任务目录里的 `transcript.srt`，
  /// 旁边有 `state.json`）。导入链路据此决定要不要把命中 cue 的文本换成正文
  /// （听写文本换成正文后阅读器 DOM 重定位才精确）。
  static bool isAsrGeneratedSubtitlePath(String path) {
    if (p.basename(path) != AsrJobFiles.srt) return false;
    return File(p.join(p.dirname(path), AsrJobFiles.state)).existsSync();
  }

  /// 丢弃该组音频在该语言下的全部转录进度与产物。
  Future<void> discard(List<String> audioPaths, AsrLanguage language) async {
    final Directory dir = await jobDirFor(audioPaths, language);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  /// 装载引擎并构造任务（不开跑；调用方订阅 [AsrRunningTranscription.run]）。
  Future<AsrRunningTranscription> start({
    required List<String> audioPaths,
    required AsrLanguage language,
    required AsrEncoderVariant variant,
    required AsrAccelerationPreference preference,
  }) async {
    final AsrModelStore store = await _openStore(language);
    final AsrEngineSessions sessions = await _loader.load(
      store: store,
      variant: variant,
      preference: preference,
    );
    try {
      final Directory jobDir = await jobDirFor(audioPaths, language);
      final AsrTranscribeJob job = AsrTranscribeJob(
        jobDir: jobDir,
        audioPaths: audioPaths,
        modelId: store.pack.id,
        pcm: _pcm,
        segmenter: switch (segmenterKind) {
          AsrSegmenterKind.energy => AsrVadSegmenter(scorer: EnergyVadScorer()),
          AsrSegmenterKind.silero => AsrVadSegmenter(session: sessions.vad),
        },
        decoder: AsrTransducerDecoder(
          encoder: sessions.encoder,
          decoder: sessions.decoder,
          joiner: sessions.joiner,
          tokens: sessions.tokens,
          greedy: sessions.greedy,
        ),
        batchSize:
            batchSize ??
            defaultBatchSizeFor(sessions.encoderResolution.effective),
        chunkSeconds: chunkSeconds,
      );
      return AsrRunningTranscription(sessions: sessions, job: job);
    } catch (_) {
      await sessions.close();
      rethrow;
    }
  }
}
