import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;
import 'package:fushi/src/mining/galgame_audio_encode.dart' show PcmFormat;
import 'package:fushi/src/mining/galgame_audio_source.dart' show GalAudioSlice;
import 'package:fushi_engine/mining/immersion_mining_request.dart';

/// galgame 制卡句子音频的长度策略（反馈 II3jOBIhT5）。
///
/// 没有配音的游戏，资源 / 引擎 PCM 都配不上语音，兜底链只能落到系统混音：窗口右界是
/// 「下一句到达 / 制卡时刻」，停在一句上看得越久，卡里那段 BGM 就越长（几十秒）。
/// 这里让用户自己定：
///
/// - [auto]：现状——按捕获窗口原样入卡。
/// - [maxLength]：最多 N 秒，短的原样。
/// - [fixedLength]：恰好 N 秒——长的截到 N 秒，短的在尾部补静音到 N 秒。
/// - [off]：卡片不带句子音频（不截取）。
///
/// 只作用于**截取**出来的 PCM（引擎 PCM / 系统混音）。游戏资源原件就是这句的
/// 语音文件，边界天然准确、不可能混进 BGM，不受长度策略影响；用户手动「重播并录音」
/// 或逐句选轨是显式裁决，同样不二次裁剪。[off] 则对所有来源生效。
enum GalMiningAudioMode {
  auto('auto'),
  maxLength('max_length'),
  fixedLength('fixed_length'),
  off('off');

  const GalMiningAudioMode(this.wireName);

  /// 偏好持久化用的稳定字符串（勿随枚举名改动）。
  final String wireName;

  /// 未知 / null → null（调用方决定回落到什么）。
  static GalMiningAudioMode? tryParse(String? name) {
    for (final GalMiningAudioMode mode in GalMiningAudioMode.values) {
      if (mode.wireName == name) return mode;
    }
    return null;
  }

  /// 是否需要秒数参数。
  bool get usesSeconds =>
      this == GalMiningAudioMode.maxLength ||
      this == GalMiningAudioMode.fixedLength;
}

/// 长度策略秒数的默认值 / 取值范围。下限 1s：0 秒等于 [GalMiningAudioMode.off]，
/// 应当选那一档而不是把秒数拖到 0。上限 60s = loopback 环的真实容量。
const int kGalMiningAudioSecondsDefault = 8;
const int kGalMiningAudioSecondsMin = 1;
const int kGalMiningAudioSecondsMax = 60;

int clampGalMiningAudioSeconds(int seconds) =>
    seconds.clamp(kGalMiningAudioSecondsMin, kGalMiningAudioSecondsMax).toInt();

/// 一次制卡生效的句子音频长度策略（全局默认叠加单游戏覆盖之后的结果）。
@immutable
class GalMiningAudioLimit {
  const GalMiningAudioLimit({
    required this.mode,
    this.seconds = kGalMiningAudioSecondsDefault,
  });

  /// 现状：不裁剪。
  static const GalMiningAudioLimit unlimited = GalMiningAudioLimit(
    mode: GalMiningAudioMode.auto,
  );

  final GalMiningAudioMode mode;

  /// [GalMiningAudioMode.usesSeconds] 时的秒数（已 clamp）。
  final int seconds;

  /// 卡片不要句子音频。
  bool get skipsAudio => mode == GalMiningAudioMode.off;

  /// 生效的毫秒上限；不裁剪时为 null。
  int? get limitMs =>
      mode.usesSeconds ? clampGalMiningAudioSeconds(seconds) * 1000 : null;

  @override
  bool operator ==(Object other) =>
      other is GalMiningAudioLimit &&
      other.mode == mode &&
      other.seconds == seconds;

  @override
  int get hashCode => Object.hash(mode, seconds);

  @override
  String toString() => 'GalMiningAudioLimit(${mode.wireName}, ${seconds}s)';
}

/// 把 [limit] 应用到一段截取的 PCM 上（纯函数，帧对齐）。
///
/// - maxLength：超过 N 秒的截到前 N 秒（前面是这句的开头——窗口从台词到达开始）。
/// - fixedLength：同上截断；不足 N 秒的在尾部补零（PCM 零值即静音，int16 / float32
///   都成立），让每张卡的音频时长一致。
/// - auto / off：原样返回（off 由调用方在取音之前就短路，不会走到这里）。
GalAudioSlice applyGalMiningAudioLimit(
  GalAudioSlice slice,
  GalMiningAudioLimit limit,
) {
  final int? limitMs = limit.limitMs;
  if (limitMs == null || slice.isEmpty) return slice;
  final PcmFormat format = slice.format;
  final int block = format.blockAlign;
  if (block <= 0 || format.byteRate <= 0) return slice;
  final int targetBytes = (limitMs * format.byteRate ~/ 1000) ~/ block * block;
  if (targetBytes <= 0) return slice;
  final int length = slice.pcm.length ~/ block * block;
  if (length > targetBytes) {
    return GalAudioSlice(
      pcm: Uint8List.sublistView(slice.pcm, 0, targetBytes),
      format: format,
    );
  }
  if (limit.mode == GalMiningAudioMode.fixedLength && length < targetBytes) {
    final Uint8List padded = Uint8List(targetBytes)
      ..setRange(0, length, slice.pcm);
    return GalAudioSlice(pcm: padded, format: format);
  }
  return slice;
}

/// 单个游戏对 galgame 制卡设置的覆盖层（反馈 3dRZdakRdJ）。
///
/// 每项 null = 跟随全局设置。持久化在偏好表 `gal_mining_overrides::<galgames.id>`
/// （JSON），键用库内游戏 id 而不是 exe 路径：改 exe 路径 / 搬游戏目录不丢覆盖。
@immutable
class GalGameMiningOverrides {
  const GalGameMiningOverrides({
    this.imageMode,
    this.animatedFormat,
    this.stillFormat,
    this.clipFormat,
    this.audioMode,
    this.audioSeconds,
  });

  static const GalGameMiningOverrides none = GalGameMiningOverrides();

  /// 脏值 / 未知 wireName 一律当「没覆盖」（跟随全局），不崩。
  factory GalGameMiningOverrides.fromJson(Map<Object?, Object?> json) {
    T? pick<T extends Enum>(List<T> values, Object? raw, String Function(T) wire) {
      if (raw is! String) return null;
      for (final T value in values) {
        if (wire(value) == raw) return value;
      }
      return null;
    }

    final Object? seconds = json['audioSeconds'];
    return GalGameMiningOverrides(
      imageMode: pick<VideoMiningImageMode>(
        galMiningImageModeChoices,
        json['imageMode'],
        (VideoMiningImageMode v) => v.wireName,
      ),
      animatedFormat: pick<MiningAnimatedFormat>(
        MiningAnimatedFormat.values,
        json['animatedFormat'],
        (MiningAnimatedFormat v) => v.wireName,
      ),
      stillFormat: pick<MiningStillFormat>(
        MiningStillFormat.values,
        json['stillFormat'],
        (MiningStillFormat v) => v.wireName,
      ),
      clipFormat: pick<MiningClipFormat>(
        MiningClipFormat.values,
        json['clipFormat'],
        (MiningClipFormat v) => v.wireName,
      ),
      audioMode: GalMiningAudioMode.tryParse(json['audioMode'] as String?),
      audioSeconds: seconds is int ? clampGalMiningAudioSeconds(seconds) : null,
    );
  }

  /// 偏好原文 → 覆盖层；空串 / 坏 JSON → [none]。
  static GalGameMiningOverrides decode(Object? stored) {
    if (stored is! String || stored.isEmpty) return none;
    try {
      final Object? decoded = jsonDecode(stored);
      if (decoded is Map) {
        return GalGameMiningOverrides.fromJson(decoded.cast<Object?, Object?>());
      }
    } on FormatException {
      return none;
    }
    return none;
  }

  final VideoMiningImageMode? imageMode;
  final MiningAnimatedFormat? animatedFormat;
  final MiningStillFormat? stillFormat;
  final MiningClipFormat? clipFormat;
  final GalMiningAudioMode? audioMode;
  final int? audioSeconds;

  bool get isEmpty =>
      imageMode == null &&
      animatedFormat == null &&
      stillFormat == null &&
      clipFormat == null &&
      audioMode == null &&
      audioSeconds == null;

  /// 逐项改：传 [clear] 里列出的字段名就把它清回「跟随全局」。
  GalGameMiningOverrides copyWith({
    VideoMiningImageMode? imageMode,
    MiningAnimatedFormat? animatedFormat,
    MiningStillFormat? stillFormat,
    MiningClipFormat? clipFormat,
    GalMiningAudioMode? audioMode,
    int? audioSeconds,
    Set<GalMiningOverrideField> clear = const <GalMiningOverrideField>{},
  }) => GalGameMiningOverrides(
    imageMode: clear.contains(GalMiningOverrideField.imageMode)
        ? null
        : imageMode ?? this.imageMode,
    animatedFormat: clear.contains(GalMiningOverrideField.animatedFormat)
        ? null
        : animatedFormat ?? this.animatedFormat,
    stillFormat: clear.contains(GalMiningOverrideField.stillFormat)
        ? null
        : stillFormat ?? this.stillFormat,
    clipFormat: clear.contains(GalMiningOverrideField.clipFormat)
        ? null
        : clipFormat ?? this.clipFormat,
    audioMode: clear.contains(GalMiningOverrideField.audioMode)
        ? null
        : audioMode ?? this.audioMode,
    audioSeconds: clear.contains(GalMiningOverrideField.audioSeconds)
        ? null
        : audioSeconds == null
        ? this.audioSeconds
        : clampGalMiningAudioSeconds(audioSeconds),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    if (imageMode != null) 'imageMode': imageMode!.wireName,
    if (animatedFormat != null) 'animatedFormat': animatedFormat!.wireName,
    if (stillFormat != null) 'stillFormat': stillFormat!.wireName,
    if (clipFormat != null) 'clipFormat': clipFormat!.wireName,
    if (audioMode != null) 'audioMode': audioMode!.wireName,
    if (audioSeconds != null) 'audioSeconds': audioSeconds,
  };

  /// 落盘原文；空覆盖层写空串（= 删掉这份覆盖）。
  String encode() => isEmpty ? '' : jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is GalGameMiningOverrides &&
      other.imageMode == imageMode &&
      other.animatedFormat == animatedFormat &&
      other.stillFormat == stillFormat &&
      other.clipFormat == clipFormat &&
      other.audioMode == audioMode &&
      other.audioSeconds == audioSeconds;

  @override
  int get hashCode => Object.hash(
    imageMode,
    animatedFormat,
    stillFormat,
    clipFormat,
    audioMode,
    audioSeconds,
  );
}

/// [GalGameMiningOverrides.copyWith] 的清除标记。
enum GalMiningOverrideField {
  imageMode,
  animatedFormat,
  stillFormat,
  clipFormat,
  audioMode,
  audioSeconds,
}

/// galgame 封面模式能选的三档（与全局设置页同一组：gif / 静态截图 / 视频片段）。
const List<VideoMiningImageMode> galMiningImageModeChoices =
    <VideoMiningImageMode>[
      VideoMiningImageMode.gif,
      VideoMiningImageMode.currentFrame,
      VideoMiningImageMode.videoClip,
    ];

/// 一次 galgame 制卡实际生效的整组设置：全局默认 + 当前游戏覆盖。
///
/// 所有 gal 制卡入口（浮窗、texthooker 页、操作目录、游戏串流主机）都从这一份取，
/// 不各自读全局偏好——否则「本游戏设置」会在某个入口静默失效。
@immutable
class GalMiningSettings {
  const GalMiningSettings({
    required this.imageMode,
    required this.animatedFormat,
    required this.stillFormat,
    required this.clipFormat,
    required this.audioLimit,
  });

  /// 覆盖层逐项压过全局；秒数与模式分开覆盖（只改了模式的游戏沿用全局秒数）。
  factory GalMiningSettings.resolve({
    required GalMiningSettings global,
    required GalGameMiningOverrides overrides,
  }) => GalMiningSettings(
    imageMode: overrides.imageMode ?? global.imageMode,
    animatedFormat: overrides.animatedFormat ?? global.animatedFormat,
    stillFormat: overrides.stillFormat ?? global.stillFormat,
    clipFormat: overrides.clipFormat ?? global.clipFormat,
    audioLimit: GalMiningAudioLimit(
      mode: overrides.audioMode ?? global.audioLimit.mode,
      seconds: overrides.audioSeconds ?? global.audioLimit.seconds,
    ),
  );

  final VideoMiningImageMode imageMode;
  final MiningAnimatedFormat animatedFormat;
  final MiningStillFormat stillFormat;
  final MiningClipFormat clipFormat;
  final GalMiningAudioLimit audioLimit;

  @override
  bool operator ==(Object other) =>
      other is GalMiningSettings &&
      other.imageMode == imageMode &&
      other.animatedFormat == animatedFormat &&
      other.stillFormat == stillFormat &&
      other.clipFormat == clipFormat &&
      other.audioLimit == audioLimit;

  @override
  int get hashCode =>
      Object.hash(imageMode, animatedFormat, stillFormat, clipFormat, audioLimit);
}

/// 单游戏覆盖层的偏好键前缀（登记在 `kKnownPreferenceKeyPrefixes`）。
const String kGalMiningOverridesPrefKeyPrefix = 'gal_mining_overrides::';

String galMiningOverridesPrefKey(String gameId) =>
    '$kGalMiningOverridesPrefKeyPrefix$gameId';
