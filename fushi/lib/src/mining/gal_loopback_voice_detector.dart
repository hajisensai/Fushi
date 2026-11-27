/// 系统 loopback（整机混音）逐行切片里**有没有人声**（BUG-5550）。
///
/// loopback 切片只证明「这段时间电脑在出声」：旁白句截到的是 BGM / 环境音，台词句
/// 截到的是 BGM + 角色语音。旧实现把每段切片都当成「这句配上了原声」，于是「仅朗读无
/// 原声的句子」在 loopback 会话里一句都不读。这里用 silero-vad（有声书转写同一份
/// `silero_vad.onnx`，混音素材只能用它，见 fushi_asr_core `asr_vad.dart` 文件头）判
/// 切片里有没有人声，结论写回该行的 fallbackReason，朗读裁决按它分 voiced / unvoiced。
///
/// 判不出（ONNX 不可用、模型下不来、位深不认识）返回 null：调用方如实标「未核实」，
/// 不得替游戏宣布「有配音」或「没配音」。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi/src/mining/galgame_audio_encode.dart' show PcmFormat;
import 'package:fushi/src/mining/galgame_audio_source.dart' show GalAudioSlice;
import 'package:fushi/src/onnx/onnx_inference_ort.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:path/path.dart' as p;

/// 切片人声检测器（可替换，测试注入）。
abstract interface class GalLoopbackVoiceDetector {
  /// [slice] 里有没有人声。[leadInMs] = 切片开头属于「上一句」的预卷长度：只落在
  /// 这段里的人声是上一句的尾巴，不算本句的配音；跨过它的（语音略早于文本）照算。
  /// 判不出返回 null。
  Future<bool?> hasSpeech(GalAudioSlice slice, {required int leadInMs});
}

/// 把 loopback PCM（int16 / float32，任意声道、任意采样率）转成 VAD 要的 16 kHz
/// 单声道 float32：先逐帧混成单声道，再按输出样本覆盖的输入区间取平均降采样
/// （区间平均就是一个盒式低通，足够 VAD 用）。不认识的位深返回 null。
Float32List? galSliceToVadPcm(GalAudioSlice slice) {
  final PcmFormat format = slice.format;
  final int block = format.blockAlign;
  if (block <= 0 || format.sampleRate <= 0 || format.channels <= 0) {
    return null;
  }
  final bool float32 = format.isFloat && format.bitsPerSample == 32;
  final bool int16 = !format.isFloat && format.bitsPerSample == 16;
  if (!float32 && !int16) return null;
  final ByteData data = ByteData.sublistView(slice.pcm);
  final int frames = slice.pcm.length ~/ block;
  final int sampleBytes = format.bitsPerSample ~/ 8;
  double monoAt(int frame) {
    double sum = 0;
    for (int c = 0; c < format.channels; c++) {
      final int offset = frame * block + c * sampleBytes;
      sum += float32
          ? data.getFloat32(offset, Endian.little)
          : data.getInt16(offset, Endian.little) / 32768.0;
    }
    return sum / format.channels;
  }

  final int outLength = frames * asr.kAsrSampleRate ~/ format.sampleRate;
  final Float32List out = Float32List(outLength);
  final double ratio = format.sampleRate / asr.kAsrSampleRate;
  for (int i = 0; i < outLength; i++) {
    final int start = (i * ratio).floor();
    final int end = math.min(
      frames,
      math.max(start + 1, ((i + 1) * ratio).floor()),
    );
    double sum = 0;
    for (int f = start; f < end; f++) {
      sum += monoAt(f);
    }
    out[i] = (sum / (end - start)).clamp(-1.0, 1.0).toDouble();
  }
  return out;
}

/// 用 VAD 切分状态机判「有没有本句的人声」（纯逻辑，打分器可替换）。
///
/// 段判据沿用有声书转写的默认值（阈值 0.5、最短语音 250 ms），只认未外扩的语音窗口
/// （`rawEndMs`）：结束点落在 [leadInMs] 之后才算本句。
Future<bool> galVadFindsLineSpeech({
  required asr.AsrVadScorer scorer,
  required Float32List pcm16k,
  required int leadInMs,
}) async {
  if (pcm16k.isEmpty) return false;
  final asr.AsrVadSegmenter segmenter = asr.AsrVadSegmenter(scorer: scorer);
  final List<asr.AsrSpeechSegment> segments = <asr.AsrSpeechSegment>[
    ...await segmenter.feed(asr.AsrPcmChunk(startSample: 0, samples: pcm16k)),
    ...await segmenter.flush(),
  ];
  return segments.any(
    (asr.AsrSpeechSegment s) => (s.rawEndMs ?? s.endMs) > leadInMs,
  );
}

/// 把打分器装配成检测器：转码放后台 isolate（30 s 立体声切片在主 isolate 上要几十
/// 毫秒），检测串行执行（silero 的 LSTM 状态在打分器上，会话本身只建一次）。
class VadGalLoopbackVoiceDetector implements GalLoopbackVoiceDetector {
  VadGalLoopbackVoiceDetector({
    required Future<asr.AsrVadScorer?> Function() scorerFactory,
  }) : _scorerFactory = scorerFactory;

  final Future<asr.AsrVadScorer?> Function() _scorerFactory;
  Future<void> _tail = Future<void>.value();

  @override
  Future<bool?> hasSpeech(GalAudioSlice slice, {required int leadInMs}) {
    final Completer<bool?> done = Completer<bool?>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await _detect(slice, leadInMs: leadInMs));
      } on Object catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  Future<bool?> _detect(GalAudioSlice slice, {required int leadInMs}) async {
    final asr.AsrVadScorer? scorer = await _scorerFactory();
    if (scorer == null) return null;
    final Float32List? pcm = await Isolate.run<Float32List?>(
      () => galSliceToVadPcm(slice),
    );
    if (pcm == null) return null;
    return galVadFindsLineSpeech(
      scorer: scorer,
      pcm16k: pcm,
      leadInMs: leadInMs,
    );
  }
}

/// silero-vad 模型的独立存放目录 `<support>/asr_models/<本目录>/`（已下过任一语音
/// 识别包时直接借用包里那份，不重复下载）。
const String kGalLoopbackVadModelDirName = 'silero_vad';

/// 生产打分器工厂：ONNX 不可用返回 null；会话建一次后复用，失败不缓存（下次重试）。
class SileroGalLoopbackVadScorers {
  SileroGalLoopbackVadScorers._();

  static final SileroGalLoopbackVadScorers shared =
      SileroGalLoopbackVadScorers._();

  Future<asr.OnnxSession>? _session;

  Future<asr.AsrVadScorer?> create() async {
    if (!asr.isLocalOnnxRuntimeAvailable) return null;
    final Future<asr.OnnxSession> pending = _session ??= _createSession();
    try {
      return asr.SileroVadScorer(await pending);
    } on Object {
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
      p.join(models.path, kGalLoopbackVadModelDirName),
    );
    await asr.ModelFileDownloader()
        .downloadAll(
          files: const <asr.DownloadableModelFile>[asr.kAsrVadFile],
          targetDir: target,
          isReady: ready,
        )
        .drain<void>();
    final File file = File(p.join(target.path, asr.kAsrVadFile.fileName));
    if (!ready(file)) {
      throw StateError('silero_vad.onnx missing after download');
    }
    return file;
  }
}

/// 生产检测器（会话单例用）。
final GalLoopbackVoiceDetector kSileroGalLoopbackVoiceDetector =
    VadGalLoopbackVoiceDetector(
      scorerFactory: SileroGalLoopbackVadScorers.shared.create,
    );
