/// 音乐输出的平台原生侧（设计 §7.4）：mpv 管不到的两件事走 method channel——
///
/// * **Android 14+ USB DAC bit-perfect**：`AudioManager.getSupportedMixerAttributes` /
///   `setPreferredMixerAttributes(MIXER_BEHAVIOR_BIT_PERFECT)`。这是可选 HAL 能力，
///   不支持就如实回报，界面照实显示，不假装成功。
/// * **iOS 首选采样率**：`AVAudioSession.setPreferredSampleRate(源采样率)`；iOS 没有独占，
///   系统混音照旧，回报硬件实际采样率。
///
/// 通道名与方法契约由 `android/.../MusicOutputChannelHandler.java` 与
/// `ios/Runner/MusicOutputChannel.swift` 实现；其余平台不注册这个通道。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android bit-perfect 请求的结果。
enum MusicBitPerfectState {
  /// 已对当前 USB 设备设成 bit-perfect 混音属性。
  enabled('enabled'),

  /// 系统低于 Android 14（API 34），没有这组 API。
  unsupportedOs('unsupportedOs'),

  /// 没接 USB 音频设备（bit-perfect 混音属性只对 USB 设备开放）。
  noUsbDevice('noUsbDevice'),

  /// 设备 HAL 不提供与源格式匹配的 bit-perfect 混音属性。
  unsupportedByDevice('unsupportedByDevice'),

  /// 系统拒绝了设置（返回 false 或抛异常）。
  failed('failed'),

  /// 本平台没有这个能力（非 Android）。
  unsupportedPlatform('unsupportedPlatform');

  const MusicBitPerfectState(this.wire);

  final String wire;

  static MusicBitPerfectState fromWire(String? wire) =>
      MusicBitPerfectState.values.firstWhere(
        (MusicBitPerfectState s) => s.wire == wire,
        orElse: () => MusicBitPerfectState.failed,
      );
}

/// PCM 编码（Android `AudioFormat.ENCODING_*` 的对应名）。
enum MusicPcmEncoding {
  pcm16('pcm16'),
  pcm24('pcm24'),
  pcm32('pcm32'),
  float('float');

  const MusicPcmEncoding(this.wire);

  final String wire;
}

/// 纯函数：mpv `audio-params/format`（`s16` / `s32` / `floatp` …）+ 源位深 → Android 编码。
/// 24 bit 源被 FFmpeg 解成 s32（低 8 bit 为 0），按源位深报 pcm24。
MusicPcmEncoding? musicPcmEncodingOf(String? mpvFormat, {int? sourceBitDepth}) {
  if (mpvFormat == null || mpvFormat.isEmpty) return null;
  final String f = mpvFormat.endsWith('p')
      ? mpvFormat.substring(0, mpvFormat.length - 1)
      : mpvFormat;
  switch (f) {
    case 's16':
      return MusicPcmEncoding.pcm16;
    case 's32':
      return sourceBitDepth == 24
          ? MusicPcmEncoding.pcm24
          : MusicPcmEncoding.pcm32;
    case 'float':
      return MusicPcmEncoding.float;
    default:
      return null;
  }
}

@immutable
class MusicBitPerfectResult {
  const MusicBitPerfectResult({
    required this.state,
    this.deviceName,
    this.sampleRate,
    this.message,
  });

  final MusicBitPerfectState state;

  /// USB 设备的产品名（`AudioDeviceInfo.getProductName`）。
  final String? deviceName;

  /// 设成功时混音器的采样率。
  final int? sampleRate;

  /// 失败 / 不支持时的说明（含设备实际支持的格式清单），原样给界面。
  final String? message;

  bool get enabled => state == MusicBitPerfectState.enabled;

  static MusicBitPerfectResult fromMap(Map<Object?, Object?> map) =>
      MusicBitPerfectResult(
        state: MusicBitPerfectState.fromWire(map['state'] as String?),
        deviceName: map['deviceName'] as String?,
        sampleRate: (map['sampleRate'] as num?)?.toInt(),
        message: map['message'] as String?,
      );
}

/// iOS 采样率请求的结果。
@immutable
class MusicIosSampleRateResult {
  const MusicIosSampleRateResult({
    required this.preferred,
    required this.actual,
  });

  final double preferred;

  /// `AVAudioSession.sampleRate`：硬件实际采样率。
  final double actual;
}

/// method channel 封装。测试注入 [MethodChannel] 的 mock handler。
class MusicPlatformOutput {
  const MusicPlatformOutput({
    MethodChannel channel = const MethodChannel(kMusicOutputChannel),
  }) : _channel = channel;

  /// 通道名（两端原生实现与 Dart 共用）。
  static const String kMusicOutputChannel = 'app.fushi.reader/music_output';

  final MethodChannel _channel;

  bool get _android => !kIsWeb && Platform.isAndroid;
  bool get _ios => !kIsWeb && Platform.isIOS;

  /// Android：对当前 USB 输出设备请求与源格式匹配的 bit-perfect 混音属性。
  Future<MusicBitPerfectResult> requestBitPerfect({
    required int sampleRate,
    required int channelCount,
    required MusicPcmEncoding encoding,
  }) async {
    if (!_android) {
      return const MusicBitPerfectResult(
        state: MusicBitPerfectState.unsupportedPlatform,
      );
    }
    try {
      final Map<Object?, Object?>? reply = await _channel
          .invokeMethod<Map<Object?, Object?>>(
            'requestBitPerfect',
            <String, Object>{
              'sampleRate': sampleRate,
              'channelCount': channelCount,
              'encoding': encoding.wire,
            },
          );
      if (reply == null) {
        return const MusicBitPerfectResult(
          state: MusicBitPerfectState.failed,
          message: 'no reply',
        );
      }
      return MusicBitPerfectResult.fromMap(reply);
    } on PlatformException catch (e) {
      return MusicBitPerfectResult(
        state: MusicBitPerfectState.failed,
        message: '${e.code}: ${e.message}',
      );
    }
  }

  /// Android：撤掉之前设的 bit-perfect 混音属性（退出独占 / 停止音乐时）。
  Future<void> clearBitPerfect() async {
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>('clearBitPerfect');
    } on PlatformException catch (e) {
      debugPrint('[music] clearBitPerfect failed: ${e.code} ${e.message}');
    }
  }

  /// iOS：把 AVAudioSession 首选采样率设成源采样率，回报硬件实际值。非 iOS 返回 null。
  Future<MusicIosSampleRateResult?> setPreferredSampleRate(
    int sampleRate,
  ) async {
    if (!_ios) return null;
    try {
      final Map<Object?, Object?>? reply = await _channel
          .invokeMethod<Map<Object?, Object?>>(
            'setPreferredSampleRate',
            <String, Object>{'sampleRate': sampleRate.toDouble()},
          );
      if (reply == null) return null;
      return MusicIosSampleRateResult(
        preferred: (reply['preferred'] as num?)?.toDouble() ?? 0,
        actual: (reply['actual'] as num?)?.toDouble() ?? 0,
      );
    } on PlatformException catch (e) {
      debugPrint(
        '[music] setPreferredSampleRate failed: ${e.code} ${e.message}',
      );
      return null;
    }
  }
}
