/// 信号路径（设计 §7.4，Roon 式）：源 → 解码 → DSP 链 → 输出。数据**只**来自 mpv 属性
/// （`audio-params` / `audio-out-params` / `current-ao` / `af` / `volume` …）与平台原生
/// 回报（Android bit-perfect、iOS 硬件采样率），不靠推测；判定是纯函数，可单测。
///
/// 只有链上零修改、且输出是独占 / bit-perfect 直通时才判「Bit-perfect」；任何一环生效
/// 就降为「高品质」并列出是哪一环。DSD 源在 mpv 里只能先转 PCM，单独标「DSD→PCM」。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/music/music_crossfade.dart';
import 'package:fushi/src/media/music/music_platform_output.dart';

/// 输出所在的平台（判定「是否绕过系统混音」的规则按平台不同）。
enum MusicOutputPlatform { windows, macos, linux, android, ios, other }

/// mpv `audio-params` / `audio-out-params` 的一份。
@immutable
class MusicAudioFormat {
  const MusicAudioFormat({
    required this.format,
    required this.sampleRate,
    required this.channelCount,
    this.channels,
  });

  /// mpv 采样格式（`s16` / `s32` / `float` / `floatp` / `double` …）。
  final String format;
  final int sampleRate;
  final int channelCount;

  /// 声道布局名（`stereo` / `5.1` …）。
  final String? channels;

  /// 去掉平面（planar）后缀的采样格式：平面 / 交错只是内存排布，不改样本值。
  String get packedFormat => format.endsWith('p') && format.length > 1
      ? format.substring(0, format.length - 1)
      : format;

  /// mpv 的 JSON 串（`getProperty('audio-params')`）→ 格式；属性不可用（空串）为 null。
  static MusicAudioFormat? fromMpvJson(String raw) {
    if (raw.trim().isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final Object? format = decoded['format'];
    final Object? rate = decoded['samplerate'];
    final Object? count = decoded['channel-count'];
    if (format is! String || rate is! num || count is! num) return null;
    return MusicAudioFormat(
      format: format,
      sampleRate: rate.toInt(),
      channelCount: count.toInt(),
      channels: decoded['channels'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MusicAudioFormat &&
      other.format == format &&
      other.sampleRate == sampleRate &&
      other.channelCount == channelCount &&
      other.channels == channels;

  @override
  int get hashCode => Object.hash(format, sampleRate, channelCount, channels);

  @override
  String toString() => '$format ${sampleRate}Hz ${channels ?? '$channelCount'}';
}

/// mpv `audio-device-list` 的一项。
@immutable
class MusicAudioDevice {
  const MusicAudioDevice({required this.name, required this.description});

  /// mpv 设备名（`auto` / `wasapi/{guid}` / `coreaudio/<uid>` / `alsa/hw:CARD=…`）。
  final String name;
  final String description;

  bool get isAuto => name == 'auto';

  /// ALSA 硬件设备直出（绕过 PipeWire / dmix）。
  bool get isAlsaHardware => name.startsWith('alsa/hw:');

  static List<MusicAudioDevice> listFromMpvJson(String raw) {
    if (raw.trim().isEmpty) return const <MusicAudioDevice>[];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const <MusicAudioDevice>[];
    }
    if (decoded is! List<Object?>) return const <MusicAudioDevice>[];
    return <MusicAudioDevice>[
      for (final Object? e in decoded)
        if (e is Map<String, Object?> && e['name'] is String)
          MusicAudioDevice(
            name: e['name']! as String,
            description: (e['description'] as String?) ?? e['name']! as String,
          ),
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is MusicAudioDevice &&
      other.name == name &&
      other.description == description;

  @override
  int get hashCode => Object.hash(name, description);
}

/// 一次读出的信号路径原始数据（都是 mpv 属性 / 平台回报的原值）。
@immutable
class MusicSignalPathSnapshot {
  const MusicSignalPathSnapshot({
    required this.platform,
    this.fileFormat,
    this.codec,
    this.codecDescription,
    this.sourceSampleRate,
    this.sourceChannelCount,
    this.sourceBitDepth,
    this.bitrate,
    this.decoded,
    this.output,
    this.currentAo,
    this.audioDevice,
    this.audioDeviceDescription,
    this.exclusiveRequested = false,
    this.volume = 100,
    this.volumeGainDb = 0,
    this.muted = false,
    this.speed = 1,
    this.pitchCorrection = true,
    this.userFilters = '',
    this.crossfade = false,
    this.crossfadeAvailability = MusicCrossfadeAvailability.off,
    this.androidBitPerfect,
    this.iosSampleRate,
  });

  final MusicOutputPlatform platform;

  /// `file-format`（容器）。
  final String? fileFormat;

  /// `current-tracks/audio/codec`（`flac` / `alac` / `dsd_lsbf_planar` …）。
  final String? codec;

  /// `audio-codec`（人读的编码名）。
  final String? codecDescription;

  /// `current-tracks/audio/demux-samplerate` / `demux-channel-count`：容器里写的源属性。
  final int? sourceSampleRate;
  final int? sourceChannelCount;

  /// 源位深：mpv 不报（FLAC 24 bit 解成 s32），取曲库扫描时从文件头读到的值。
  final int? sourceBitDepth;

  /// `audio-bitrate`（bit/s）。
  final int? bitrate;

  /// `audio-params`：解码器输出。
  final MusicAudioFormat? decoded;

  /// `audio-out-params`：实际写给音频 API 的格式。
  final MusicAudioFormat? output;

  /// `current-ao`（`wasapi` / `coreaudio_exclusive` / `alsa` / `pipewire` / `audiotrack` …）；
  /// 空 = 音频输出没起来。
  final String? currentAo;

  /// `audio-device` 与它在 `audio-device-list` 里的描述。
  final String? audioDevice;
  final String? audioDeviceDescription;

  /// `audio-exclusive`。
  final bool exclusiveRequested;

  /// `volume`（0–100+）、`volume-gain`（dB，本模块只用它承载 ReplayGain）、`mute`。
  final double volume;
  final double volumeGainDb;
  final bool muted;

  /// `speed` 与 `audio-pitch-correction`（变速不变调 = scaletempo2）。
  final double speed;
  final bool pitchCorrection;

  /// `af`：用户 / 本模块显式插的滤镜链；空串 = 没有。
  final String userFilters;

  /// 交叉淡入正在作用于本曲（加载时装了淡入淡出滤镜）。
  final bool crossfade;

  /// 交叉淡入此刻是否可用（独占 / 硬件直出时自动停用，面板要标出来）。
  final MusicCrossfadeAvailability crossfadeAvailability;

  /// Android：bit-perfect 混音属性请求的回报（没请求过为 null）。
  final MusicBitPerfectResult? androidBitPerfect;

  /// iOS：AVAudioSession 首选 / 实际采样率。
  final MusicIosSampleRateResult? iosSampleRate;

  bool get isDsd => codec != null && codec!.startsWith('dsd_');
}

/// 链上让输出偏离源数据的一环。
enum MusicSignalStage {
  /// 输出走系统混音（共享模式 / iOS / 未拿到 bit-perfect）。
  systemMixer,

  /// 输出没起来（`current-ao` 为空）。
  noOutput,

  /// DSD → PCM 转换（mpv 不支持 DoP / 原生 DSD 输出）。
  dsdToPcm,

  /// 采样率转换。
  resampler,

  /// 采样格式转换（位深 / 浮点）。
  formatConversion,

  /// 声道重混。
  channelRemix,

  /// 软件音量。
  volume,

  /// ReplayGain 增益。
  replayGain,

  /// 变速（scaletempo2 / 重采样）。
  speed,

  /// 显式滤镜链（`af`）。
  filters,

  /// 交叉淡入。
  crossfade,
}

/// 判定结果。
enum MusicSignalQuality {
  /// 源样本原样到达设备。
  bitPerfect,

  /// 有某一环修改了样本或经过了系统混音。
  highQuality,

  /// 没在播 / 读不到。
  unknown,
}

@immutable
class MusicSignalPathVerdict {
  const MusicSignalPathVerdict(this.quality, this.stages);

  final MusicSignalQuality quality;

  /// 生效（偏离 bit-perfect）的各环，按链路顺序。
  final List<MusicSignalStage> stages;

  bool get isBitPerfect => quality == MusicSignalQuality.bitPerfect;
}

/// 纯函数：这条输出是否绕过了系统混音（独占 / HAL bit-perfect / ALSA 硬件直出）。
bool musicOutputBypassesMixer(MusicSignalPathSnapshot s) {
  final String ao = s.currentAo ?? '';
  switch (s.platform) {
    case MusicOutputPlatform.windows:
      return ao == 'wasapi' && s.exclusiveRequested;
    case MusicOutputPlatform.macos:
      // mpv 的 coreaudio 在 audio-exclusive 下重定向到 coreaudio_exclusive（hog mode）。
      return ao == 'coreaudio_exclusive';
    case MusicOutputPlatform.linux:
      return ao == 'alsa' && (s.audioDevice?.startsWith('alsa/hw:') ?? false);
    case MusicOutputPlatform.android:
      return s.androidBitPerfect?.enabled ?? false;
    case MusicOutputPlatform.ios:
    case MusicOutputPlatform.other:
      return false;
  }
}

/// 两个采样格式是否不改样本值：同格式；或 24 bit（及以下）源经 s32 容器写成 s24。
bool _sameSamples(String decoded, String output, int? sourceBitDepth) {
  if (decoded == output) return true;
  return decoded == 's32' &&
      output == 's24' &&
      sourceBitDepth != null &&
      sourceBitDepth <= 24;
}

/// 纯函数：快照 → 判定（设计 §7.4）。
MusicSignalPathVerdict judgeMusicSignalPath(MusicSignalPathSnapshot s) {
  final MusicAudioFormat? decoded = s.decoded;
  final MusicAudioFormat? output = s.output;
  if (decoded == null) {
    return const MusicSignalPathVerdict(
      MusicSignalQuality.unknown,
      <MusicSignalStage>[],
    );
  }
  final List<MusicSignalStage> stages = <MusicSignalStage>[];
  if (s.isDsd) stages.add(MusicSignalStage.dsdToPcm);
  if (s.userFilters.trim().isNotEmpty) stages.add(MusicSignalStage.filters);
  if ((s.speed - 1).abs() > 1e-9) stages.add(MusicSignalStage.speed);
  if (s.volumeGainDb.abs() > 1e-9) stages.add(MusicSignalStage.replayGain);
  if (s.muted || (s.volume - 100).abs() > 1e-9) {
    stages.add(MusicSignalStage.volume);
  }
  if (s.crossfade) stages.add(MusicSignalStage.crossfade);
  if (output == null || (s.currentAo ?? '').isEmpty) {
    stages.add(MusicSignalStage.noOutput);
  } else {
    if (output.sampleRate != decoded.sampleRate) {
      stages.add(MusicSignalStage.resampler);
    }
    if (!_sameSamples(
      decoded.packedFormat,
      output.packedFormat,
      s.sourceBitDepth,
    )) {
      stages.add(MusicSignalStage.formatConversion);
    }
    if (output.channelCount != decoded.channelCount) {
      stages.add(MusicSignalStage.channelRemix);
    }
    if (!musicOutputBypassesMixer(s)) stages.add(MusicSignalStage.systemMixer);
  }
  return MusicSignalPathVerdict(
    stages.isEmpty
        ? MusicSignalQuality.bitPerfect
        : MusicSignalQuality.highQuality,
    stages,
  );
}

/// 纯函数：ReplayGain 增益（dB）。专辑模式优先专辑增益、缺了退曲目增益，曲目模式反之；
/// 都没有 = 0（没有响度信息时不施加预放大，与 foobar2000 / mpv 一致）。有峰值时做防削波：
/// 增益不超过 `-20·log10(peak)`。
double musicReplayGainDb({
  required bool albumMode,
  required double? trackGain,
  required double? trackPeak,
  required double? albumGain,
  required double? albumPeak,
  required double preampDb,
}) {
  final double? gain = albumMode
      ? (albumGain ?? trackGain)
      : (trackGain ?? albumGain);
  if (gain == null) return 0;
  final double? peak = albumMode
      ? (albumGain != null ? albumPeak : trackPeak)
      : (trackGain != null ? trackPeak : albumPeak);
  double db = gain + preampDb;
  if (peak != null && peak > 0) {
    db = math.min(db, -20 * math.log(peak) / math.ln10);
  }
  return db;
}
