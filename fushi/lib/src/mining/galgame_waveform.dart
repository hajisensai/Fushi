import 'dart:typed_data';

import 'package:fushi/src/mining/galgame_audio_encode.dart' show PcmFormat;
import 'package:fushi_compute/fushi_compute.dart';

/// galgame 一键制卡（docs/specs/galgame-mining）波形数据桥。
///
/// 视频波形 UI 复用的是 `downsampleEnergyEnvelope`（`audio_energy_probe.dart`），它吃的是
/// **逐帧 RMS dBFS 序列**（视频那边由 ffmpeg astats 产出）。loopback 给的是裸 PCM，所以这里
/// 补上等价的一步：把 PCM 切成 [windowMs] 的窗，逐窗算 RMS 并转 dBFS（≤0，越大越响），产出
/// 和 ffmpeg 同构的能量帧，下游 `downsampleEnergyEnvelope` + `SubtitleWaveformPainter` 原样
/// 复用。无 IO，可单测。

/// 波形能量窗（毫秒），与视频波形对齐用的 `kSubtitleWaveformWindowMs` 一致（20ms）。
const int kGalWaveformWindowMs = 20;

/// 把裸 PCM 转成逐窗 RMS dBFS 能量帧（喂 `downsampleEnergyEnvelope`）。
///
/// 支持 WASAPI 共享模式常见格式：16-bit 整型、32-bit 整型、32-bit float。其它位深无法可靠
/// 解码时返回空列表（下游据此画空波形，不崩、不乱画）。[silenceDb] 为静音地板（RMS 为 0 的
/// 窗返回它），结果每帧 ∈ [silenceDb, 0]。
///
/// 计算在 Rust（native/fushi_compute `ffc_signal_pcm_rms_db`，整段 PCM 一次调用；纯计算，
/// 与 hook / helper 无关）。库不可用抛 `FushiComputeUnavailableError`。
List<double> pcmToEnergyEnvelope(
  Uint8List pcm,
  PcmFormat format, {
  int windowMs = kGalWaveformWindowMs,
  double silenceDb = -120.0,
}) => ffcPcmRmsDb(
  pcm,
  sampleRate: format.sampleRate,
  channels: format.channels,
  bitsPerSample: format.bitsPerSample,
  isFloat: format.isFloat,
  windowMs: windowMs,
  silenceDb: silenceDb,
);
