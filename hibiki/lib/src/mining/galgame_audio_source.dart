import 'package:flutter/services.dart';

import 'package:hibiki/src/mining/galgame_audio_encode.dart' show PcmFormat;

/// galgame 一键制卡（docs/specs/galgame-mining）的音频来源抽象。
///
/// 只暴露一个能力：**开一路采集 → 需要时取「最近 N 毫秒」的 PCM**。波形选区对话框、VAD、
/// 制卡出口都只认这个抽象，不关心音频哪来的——A 阶段是 WASAPI loopback 混音
/// （[LoopbackGalAudioSource]），C 阶段换成引擎级 voice hook 的干净语音轨（同一接口，
/// 换一个实现，不动上层）。
abstract interface class GalAudioSource {
  /// 开始采集到环形缓冲。成功返回 PCM 格式（采样率/声道/位深），失败（native 缺失 /
  /// 无采集设备）返回 null（fail-open，调用方降级提示，不崩）。
  Future<PcmFormat?> start();

  /// 停止采集并释放环形缓冲。
  Future<void> stop();

  /// 取「当前时刻往前 [backMs] 毫秒」的 PCM 切片。缓冲不足 [backMs] 时返回现有全部；
  /// native 缺失 / 未 start / 无数据返回 null。
  Future<GalAudioSlice?> grabRecent(int backMs);
}

/// 一段裸 PCM 切片 + 它的格式。
class GalAudioSlice {
  const GalAudioSlice({required this.pcm, required this.format});

  final Uint8List pcm;
  final PcmFormat format;

  bool get isEmpty => pcm.isEmpty;
}

/// A 阶段实现：WASAPI loopback 抓系统混音（含 BGM/SE/语音，混音后）。环形缓冲在 native
/// 侧（内存有界、不持续 IPC），Dart 只在热键那一刻按 [backMs] 拉最近一段。
///
/// native 侧（`hibiki/windows/runner/audio_loopback_capture.cpp`）注册 `audio_loopback`
/// MethodChannel，方法：
///   - `start` -> `Map`：`{sampleRate, channels, bitsPerSample, isFloat}` 或 `{error}`。
///   - `stop` -> void。
///   - `grabRecent` `{backMs}` -> `Map`：`{pcm:Uint8List, sampleRate, channels,
///     bitsPerSample, isFloat}` 或 `{error}`。
///
/// native 缺失（未构建 / 非 Windows）时所有方法以 [MissingPluginException] /
/// [PlatformException] 收敛为 null（调用方降级）。
class LoopbackGalAudioSource implements GalAudioSource {
  LoopbackGalAudioSource({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('app.hibiki.reader/audio_loopback');

  final MethodChannel _channel;

  @override
  Future<PcmFormat?> start() async {
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>('start');
      if (r == null || r['error'] != null) {
        return null;
      }
      return _parseFormat(r);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // 停不掉不该崩上层（native 会在进程退出兜底释放）。
    } on MissingPluginException {
      // native 缺失：本就没开，无操作。
    }
  }

  @override
  Future<GalAudioSlice?> grabRecent(int backMs) async {
    if (backMs <= 0) {
      return null;
    }
    try {
      final Map<Object?, Object?>? r =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'grabRecent',
        <String, Object?>{'backMs': backMs},
      );
      if (r == null || r['error'] != null) {
        return null;
      }
      final Uint8List? pcm = r['pcm'] as Uint8List?;
      final PcmFormat? fmt = _parseFormat(r);
      if (pcm == null || pcm.isEmpty || fmt == null) {
        return null;
      }
      return GalAudioSlice(pcm: pcm, format: fmt);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 从 native map 解析 [PcmFormat]；缺任一必需字段返回 null。
  static PcmFormat? _parseFormat(Map<Object?, Object?> m) {
    final Object? sampleRate = m['sampleRate'];
    final Object? channels = m['channels'];
    final Object? bitsPerSample = m['bitsPerSample'];
    if (sampleRate is! int ||
        channels is! int ||
        bitsPerSample is! int ||
        sampleRate <= 0 ||
        channels <= 0 ||
        bitsPerSample <= 0) {
      return null;
    }
    return PcmFormat(
      sampleRate: sampleRate,
      channels: channels,
      bitsPerSample: bitsPerSample,
      isFloat: m['isFloat'] == true,
    );
  }
}
