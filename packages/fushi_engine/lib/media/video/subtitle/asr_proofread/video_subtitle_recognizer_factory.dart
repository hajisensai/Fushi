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

import 'package:fushi_asr_core/asr_core.dart' as asr;
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
  });

  final VideoSubtitleRecognizer recognizer;

  /// 用上 MOSS 时的后端；滑窗为 null。
  final asr.AudioCppBackend? mossBackend;

  /// 想用 MOSS（auto / moss）却没用上时的原因（驱动不达标、运行库没下载……）。
  final String? mossUnavailableReason;

  bool get usesMoss => mossBackend != null;
}

/// 挑识别器。[mode] 为 [VideoSubtitleSegmenterMode.moss] 而 MOSS 不可用时抛
/// [VideoSubtitleRecognizeFailure]（用户显式要求的东西不能悄悄降级）；`auto` 下
/// 不可用则退回滑窗并在 [VideoSubtitleRecognizerChoice.mossUnavailableReason]
/// 里说明。
Future<VideoSubtitleRecognizerChoice> resolveVideoSubtitleRecognizer({
  required VideoSubtitleSegmenterMode mode,
  MossBackendPreference mossBackend = MossBackendPreference.auto,
  required asr.AsrTranscriptionService Function(asr.AsrAudioProfile profile)
  serviceFactory,
  asr.AsrProcessStarter? startProcess,
  asr.AsrAccelerationPreference preference = asr.AsrAccelerationPreference.auto,
}) async {
  // MOSS 实现由后续提交接入；在那之前 auto 一律退回滑窗。
  if (mode == VideoSubtitleSegmenterMode.moss) {
    throw const VideoSubtitleRecognizeFailure('moss segmenter not available');
  }
  return VideoSubtitleRecognizerChoice(
    recognizer: SlidingWindowVideoSubtitleRecognizer(
      serviceFactory: serviceFactory,
      preference: preference,
    ),
    mossUnavailableReason: mode == VideoSubtitleSegmenterMode.auto
        ? 'moss segmenter not available'
        : null,
  );
}
