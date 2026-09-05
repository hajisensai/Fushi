/// 有声书设备端转录的装配层：模型存储 / 引擎加载 / PCM 源 / 任务目录 三者拼成
/// 一次可运行的 [AsrRunningTranscription]，UI 只与本层对话。
///
/// 任务目录按「音频文件名 + 字节数」的 SHA-1 命名（`<appSupport>/asr_jobs/<hash>`），
/// 与绝对路径无关：用户把有声书目录挪个位置再选同一组文件，进度照样接上。
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

/// 开跑前的计划：会用哪个编码器变体、期望落到哪个 EP、模型是否就绪。
@immutable
class AsrTranscribePlan {
  const AsrTranscribePlan({
    required this.variant,
    required this.expectedProvider,
    required this.modelStatus,
  });

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
    Future<AsrModelStore> Function()? openStore,
    Future<Directory> Function()? jobsRoot,
    this.batchSize = 8,
    this.chunkSeconds = 300,
  }) : _loader = loader ?? AsrEngineLoader(),
       _pcm = pcm ?? FfmpegAsrPcmSource(),
       _openStore = openStore ?? AsrModelStore.open,
       _jobsRoot = jobsRoot ?? _defaultJobsRoot;

  final AsrEngineLoader _loader;
  final AsrPcmSource _pcm;
  final Future<AsrModelStore> Function() _openStore;
  final Future<Directory> Function() _jobsRoot;
  final int batchSize;
  final int chunkSeconds;

  /// 本平台是否具备设备端转录能力（= 本地 ONNX Runtime 随包）。
  static bool get isSupported => isLocalOnnxRuntimeAvailable;

  static Future<Directory> _defaultJobsRoot() async {
    final Directory support = await AppPaths.supportRootDirectory();
    return Directory(p.join(support.path, 'asr_jobs'));
  }

  Future<AsrModelStore> modelStore() => _openStore();

  /// 计算计划：探测 EP → 推荐变体 → 查模型状态。
  Future<AsrTranscribePlan> plan(AsrAccelerationPreference preference) async {
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
    final AsrModelStore store = await _openStore();
    return AsrTranscribePlan(
      variant: variant,
      expectedProvider: expected,
      modelStatus: await store.status(variant),
    );
  }

  Stream<ModelDownloadEvent> downloadModel(AsrEncoderVariant variant) async* {
    final AsrModelStore store = await _openStore();
    yield* store.download(variant);
  }

  /// 任务目录：文件名 + 字节数 的 SHA-1。
  Future<Directory> jobDirFor(List<String> audioPaths) async {
    final Directory root = await _jobsRoot();
    return Directory(p.join(root.path, jobIdFor(audioPaths)));
  }

  /// 纯函数：由文件名与字节数派生稳定 id（文件不存在按 0 字节计）。
  static String jobIdFor(List<String> audioPaths) {
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
    return sha1.convert(utf8.encode(sb.toString())).toString();
  }

  /// 已有的任务状态（没有则 null）。
  Future<AsrJobState?> existingState(List<String> audioPaths) async {
    final Directory dir = await jobDirFor(audioPaths);
    if (!File(p.join(dir.path, AsrJobFiles.state)).existsSync()) return null;
    final ({AsrJobState state, bool fresh}) loaded =
        await AsrTranscribeJob.loadStateDetailed(dir, audioPaths);
    return loaded.fresh ? null : loaded.state;
  }

  /// 已完成任务的 SRT 路径（未完成或不存在则 null）。
  Future<String?> finishedSrtPath(List<String> audioPaths) async {
    final AsrJobState? state = await existingState(audioPaths);
    if (state == null || !state.finished) return null;
    final Directory dir = await jobDirFor(audioPaths);
    final File srt = File(p.join(dir.path, AsrJobFiles.srt));
    return srt.existsSync() ? srt.path : null;
  }

  /// 丢弃该组音频的全部转录进度与产物。
  Future<void> discard(List<String> audioPaths) async {
    final Directory dir = await jobDirFor(audioPaths);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  /// 装载引擎并构造任务（不开跑；调用方订阅 [AsrRunningTranscription.run]）。
  Future<AsrRunningTranscription> start({
    required List<String> audioPaths,
    required AsrEncoderVariant variant,
    required AsrAccelerationPreference preference,
  }) async {
    final AsrModelStore store = await _openStore();
    final AsrEngineSessions sessions = await _loader.load(
      store: store,
      variant: variant,
      preference: preference,
    );
    try {
      final Directory jobDir = await jobDirFor(audioPaths);
      final AsrTranscribeJob job = AsrTranscribeJob(
        jobDir: jobDir,
        audioPaths: audioPaths,
        pcm: _pcm,
        segmenter: AsrVadSegmenter(session: sessions.vad),
        decoder: AsrTransducerDecoder(
          encoder: sessions.encoder,
          decoder: sessions.decoder,
          joiner: sessions.joiner,
          tokens: sessions.tokens,
        ),
        batchSize: batchSize,
        chunkSeconds: chunkSeconds,
      );
      return AsrRunningTranscription(sessions: sessions, job: job);
    } catch (_) {
      await sessions.close();
      rethrow;
    }
  }
}
