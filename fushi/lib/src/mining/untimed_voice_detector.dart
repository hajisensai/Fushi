import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/mining/untimed_sentence_audio.dart';
import 'package:fushi/src/onnx/onnx_inference_ort.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:path/path.dart' as p;

/// 人声检测器：返回 [startMs] 起 [durationMs] 长那一段里的人声窗口（播放器轴毫秒，
/// 未外扩）。可替换（测试注入）。
abstract interface class UntimedVoiceSegmentDetector {
  Future<List<({int startMs, int endMs})>> detect({
    required String source,
    required int? audioStreamIndex,
    required int? audioStreamCount,
    required int startMs,
    required int durationMs,
  });
}

/// 人声检测拿不到结果（模型下不来、ONNX 不可用、ffmpeg 解不出音频）。页面据此退回
/// 固定窗口并在来源小字里如实写「人声检测失败」。
class UntimedVoiceDetectionException implements Exception {
  const UntimedVoiceDetectionException(this.message);

  final String message;

  @override
  String toString() => 'UntimedVoiceDetectionException: $message';
}

/// Silero VAD 模型（有声书转写用的同一份 `silero_vad.onnx`，643 KB）的独立存放目录：
/// `<support>/asr_models/<本目录>/`。已下过任一语音识别包时直接借用包里那份。
const String kUntimedVadModelDirName = 'silero_vad';

/// 生产实现：ffmpeg 截出那一段 → Silero VAD（CPU，与有声书转写同一个切分状态机）。
class SileroUntimedVoiceSegmentDetector implements UntimedVoiceSegmentDetector {
  SileroUntimedVoiceSegmentDetector({FfmpegBackend Function()? backend})
    : _backend = backend ?? resolveFfmpegBackend;

  /// 全应用一份：会话很小，建一次后一直复用（VAD 的 LSTM 状态在每次的打分器里，
  /// 不在会话上）。
  static final SileroUntimedVoiceSegmentDetector shared =
      SileroUntimedVoiceSegmentDetector();

  final FfmpegBackend Function() _backend;
  Future<asr.OnnxSession>? _session;

  @override
  Future<List<({int startMs, int endMs})>> detect({
    required String source,
    required int? audioStreamIndex,
    required int? audioStreamCount,
    required int startMs,
    required int durationMs,
  }) async {
    if (!asr.isLocalOnnxRuntimeAvailable) {
      throw const UntimedVoiceDetectionException('ONNX runtime unavailable');
    }
    if (durationMs <= 0) return const <({int startMs, int endMs})>[];
    final asr.OnnxSession session = await _openSession();
    final Float32List pcm = await _decode(
      source: source,
      audioStreamIndex: audioStreamIndex,
      audioStreamCount: audioStreamCount,
      startMs: startMs,
      durationMs: durationMs,
    );
    final asr.AsrVadSegmenter segmenter = asr.AsrVadSegmenter(session: session);
    final List<asr.AsrSpeechSegment> segments = <asr.AsrSpeechSegment>[
      ...await segmenter.feed(asr.AsrPcmChunk(startSample: 0, samples: pcm)),
      ...await segmenter.flush(),
    ];
    return <({int startMs, int endMs})>[
      for (final asr.AsrSpeechSegment s in segments)
        (
          startMs: startMs + (s.rawStartMs ?? s.startMs),
          endMs: startMs + (s.rawEndMs ?? s.endMs),
        ),
    ];
  }

  Future<asr.OnnxSession> _openSession() async {
    final Future<asr.OnnxSession> pending = _session ??= _createSession();
    try {
      return await pending;
    } on Object {
      // 失败不缓存：下次（网络恢复后）重新下载 / 建会话。错误照常抛给调用方。
      if (identical(_session, pending)) _session = null;
      rethrow;
    }
  }

  Future<asr.OnnxSession> _createSession() async {
    final File model = await _ensureModel();
    return OrtOnnxSessionFactory().createSession(
      model.path,
      providers: const <asr.OnnxExecutionProvider>[
        asr.OnnxExecutionProvider.cpu,
      ],
      intraOpNumThreads: 1,
    );
  }

  /// 模型：先找已下好的语音识别包里那份（与有声书转写共用，不重复下），否则下到
  /// [kUntimedVadModelDirName]。
  Future<File> _ensureModel() async {
    final Directory support = await AppPaths.supportRootDirectory();
    final Directory models = Directory(p.join(support.path, 'asr_models'));
    bool ready(File file) =>
        file.existsSync() && file.lengthSync() == asr.kAsrVadFile.expectedBytes;
    if (await models.exists()) {
      await for (final FileSystemEntity entity in models.list()) {
        if (entity is! Directory) continue;
        final File candidate = File(
          p.join(entity.path, asr.kAsrVadFile.fileName),
        );
        if (ready(candidate)) return candidate;
      }
    }
    final Directory target = Directory(
      p.join(models.path, kUntimedVadModelDirName),
    );
    try {
      await asr.ModelFileDownloader()
          .downloadAll(
            files: const <asr.DownloadableModelFile>[asr.kAsrVadFile],
            targetDir: target,
            isReady: ready,
          )
          .drain<void>();
    } on Object catch (error) {
      throw UntimedVoiceDetectionException('VAD model download failed: $error');
    }
    final File file = File(p.join(target.path, asr.kAsrVadFile.fileName));
    if (!ready(file)) {
      throw const UntimedVoiceDetectionException('VAD model missing');
    }
    return file;
  }

  Future<Float32List> _decode({
    required String source,
    required int? audioStreamIndex,
    required int? audioStreamCount,
    required int startMs,
    required int durationMs,
  }) async {
    final Directory work = await Directory.systemTemp.createTemp(
      'fushi_untimed_vad_',
    );
    try {
      final File out = File(p.join(work.path, 'window.wav'));
      final FfmpegRunResult result = await _backend().run(
        buildUntimedVoicePcmArgs(
          source: source,
          outputPath: out.path,
          startMs: startMs,
          durationMs: durationMs,
          audioStreamIndex: audioStreamIndex,
          audioStreamCount: audioStreamCount,
        ),
        const Duration(seconds: 30),
      );
      if (result.returnCode != 0 || !await out.exists()) {
        throw UntimedVoiceDetectionException(
          'ffmpeg exit ${result.returnCode}: ${result.output}',
        );
      }
      try {
        return decodeWavPcm16(await out.readAsBytes());
      } on FormatException catch (error) {
        throw UntimedVoiceDetectionException('bad WAV output: $error');
      }
    } finally {
      try {
        await work.delete(recursive: true);
      } on FileSystemException {
        // 临时目录删不掉（杀毒软件占用等）只是留一个小文件，不影响结果。
      }
    }
  }
}
