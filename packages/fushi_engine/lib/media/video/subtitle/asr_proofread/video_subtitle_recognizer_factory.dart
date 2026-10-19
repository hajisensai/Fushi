/// 按平台与用户选择挑识别器（spec 第 4 节平台矩阵）：
///
/// - MOSS 分段（audio.cpp）+ Parakeet 按分段识别 + MOSS 稿作候选：Windows +
///   合格 NVIDIA（CUDA）、Linux（audio.cpp v0.9.2 无 Linux CUDA CLI，走 Vulkan），
///   以及用户显式选 Vulkan / CPU；
/// - 其余平台：现有 Parakeet 15 s / 3 s 滑窗（[SlidingWindowVideoSubtitleRecognizer]）。
///
/// app、fushi_server 与 host 任务共用这一个入口，各自只注入 ASR 服务工厂与进程
/// 启动器（宿主接 `HelperProcessRegistry`）。
library;

import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/moss_provisioning.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/moss_video_subtitle_recognizer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';

/// 分段方式：自动（能用 MOSS 就用）/ 强制 MOSS / 强制滑窗。
enum VideoSubtitleSegmenterMode { auto, moss, window }

/// MOSS 的 audio.cpp 后端偏好。`auto` = Windows 合格 NVIDIA → CUDA；Linux 检测到
/// GPU → Vulkan；否则不用 MOSS。Vulkan / CPU 只在用户显式选择时用。
enum MossBackendPreference { auto, cuda, vulkan, cpu }

/// 挑选结果：实际用的识别器 + 没用上 MOSS 的原因（用了 MOSS 或用户选了滑窗时为 null）。
class VideoSubtitleRecognizerChoice {
  const VideoSubtitleRecognizerChoice({
    required this.recognizer,
    this.mossBackend,
    this.mossUnavailableReason,
    this.mossUnavailableCode,
  });

  final VideoSubtitleRecognizer recognizer;

  /// 用上 MOSS 时的后端；滑窗为 null。
  final asr.AudioCppBackend? mossBackend;

  /// 想用 MOSS（auto / moss）却没用上时的原因（驱动不达标、运行库没下载……）。
  final String? mossUnavailableReason;

  /// [mossUnavailableReason] 的分类（UI 按它出文案）；同样只在没用上 MOSS 时有。
  final MossUnavailableCode? mossUnavailableCode;

  bool get usesMoss => mossBackend != null;
}

/// 挑识别器。[mode] 为 [VideoSubtitleSegmenterMode.moss] 而 MOSS 不可用时抛
/// [VideoSubtitleRecognizeFailure]（用户显式要求的东西不能悄悄降级）；`auto` 下
/// 不可用则退回滑窗并在 [VideoSubtitleRecognizerChoice.mossUnavailableReason]
/// 里说明。
///
/// 判定顺序：后端（[decideMossBackend]：平台矩阵 + `nvidia-smi` / GPU 探测）→ 运行库
/// 与权重是否已在磁盘上就绪。**这里不下载**：没下好就当不可用（原因
/// [MossUnavailableCode.runtimeMissing] / [MossUnavailableCode.modelMissing]），
/// 下载由调用方经 `ensureMossProvisioned` 显式触发。
///
/// - [startProcess]：MOSS / `nvidia-smi` 子进程的启动器，宿主接自己的子进程登记表；
///   null = 引擎的 [engineAsrProcessStarter]（同一个 `HelperProcessRegistry`）。
/// - [probes]：环境探测（测试注入）；null = 真实探测。
/// - [mossCliPath] / [mossModelPath]：跳过下载目录、直接用本机已有的 audio.cpp CLI
///   与 GGUF（CLI 排障 / 已手动部署时）；给了就只检查文件存在。
Future<VideoSubtitleRecognizerChoice> resolveVideoSubtitleRecognizer({
  required VideoSubtitleSegmenterMode mode,
  MossBackendPreference mossBackend = MossBackendPreference.auto,
  required asr.AsrTranscriptionService Function(asr.AsrAudioProfile profile)
  serviceFactory,
  asr.AsrProcessStarter? startProcess,
  asr.AsrAccelerationPreference preference = asr.AsrAccelerationPreference.auto,
  MossHostProbes? probes,
  String? mossCliPath,
  String? mossModelPath,
}) async {
  VideoSubtitleRecognizerChoice sliding({
    MossUnavailableCode? code,
    String? reason,
  }) => VideoSubtitleRecognizerChoice(
    recognizer: SlidingWindowVideoSubtitleRecognizer(
      serviceFactory: serviceFactory,
      preference: preference,
    ),
    mossUnavailableReason: reason,
    mossUnavailableCode: code,
  );

  if (mode == VideoSubtitleSegmenterMode.window) return sliding();
  VideoSubtitleRecognizerChoice unavailable(
    MossUnavailableCode code,
    String reason,
  ) {
    if (mode == VideoSubtitleSegmenterMode.moss) {
      throw VideoSubtitleRecognizeFailure('MOSS unavailable: $reason');
    }
    return sliding(code: code, reason: reason);
  }

  final asr.AsrProcessStarter starter = startProcess ?? engineAsrProcessStarter;
  final MossBackendDecision decision = await decideMossBackend(
    mossBackend,
    probes: probes ?? MossHostProbes.system(startProcess: starter),
  );
  final asr.AudioCppRuntimePack? pack = decision.pack;
  if (pack == null) {
    return unavailable(
      decision.code ?? MossUnavailableCode.unsupportedPlatform,
      decision.reason ?? 'MOSS unavailable',
    );
  }
  final String cli;
  if (mossCliPath != null) {
    if (!File(mossCliPath).existsSync()) {
      return unavailable(
        MossUnavailableCode.runtimeMissing,
        'audiocpp_cli not found: $mossCliPath',
      );
    }
    cli = mossCliPath;
  } else {
    final asr.AudioCppRuntimeStore runtime =
        await asr.AudioCppRuntimeStore.open(pack, startProcess: starter);
    if (!runtime.isReady) {
      return unavailable(
        MossUnavailableCode.runtimeMissing,
        'audio.cpp ${pack.directoryName} is not installed '
        '(${runtime.dir.path})',
      );
    }
    cli = runtime.executable.path;
  }
  final String model;
  if (mossModelPath != null) {
    if (!File(mossModelPath).existsSync()) {
      return unavailable(
        MossUnavailableCode.modelMissing,
        'MOSS model not found: $mossModelPath',
      );
    }
    model = mossModelPath;
  } else {
    final asr.MossModelStore store = await asr.MossModelStore.open();
    if (!store.isReady) {
      return unavailable(
        MossUnavailableCode.modelMissing,
        'MOSS model ${store.file.fileName} is not downloaded '
        '(${store.dir.path})',
      );
    }
    model = store.modelFile.path;
  }
  return VideoSubtitleRecognizerChoice(
    recognizer: MossVideoSubtitleRecognizer(
      serviceFactory: serviceFactory,
      preference: preference,
      moss: asr.MossRunner(
        cliPath: cli,
        modelPath: model,
        backend: pack.backend,
        startProcess: starter,
      ),
    ),
    mossBackend: pack.backend,
  );
}
