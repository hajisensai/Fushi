/// 一句的「演出字段」：漫画演出稿（`MangaScriptLine`）与小说选角表（`TtsCastLine`）
/// 共用一套取值范围、解析 / 夹取规则、JSON 键名与转场停顿（设计 §1 / §2 / §8）。
///
/// - 取值范围只在 [CastLineLimits] 写一次；落盘解析与 AI 输出校验都经
///   [CastLineDirection.fromJson]，夹取规则只有一份。
/// - 句后停顿 = 转场基础值（[castTransitionBaseMs]）+ 该句一拍；漫画再加翻页值与页
///   规则（`manga_audio_timeline.dart`），小说再叠段落 / 场景停顿
///   （`tts_cast_timing.dart`）。
library;

import 'package:fushi_engine/tts/cast/cast_line_kind.dart';

/// 演出字段的取值范围；超出的值在解析 / 校验时夹到范围内（不丢行）。
abstract final class CastLineLimits {
  /// 一拍（句后额外停顿）上限，毫秒。
  static const int maxBeatMs = 10000;

  /// 情绪强度上限（下限 0）。
  static const int maxIntensity = 100;

  /// 语速偏移（倍率的增量：-0.5 = 慢一半，+1.0 = 快一倍）。
  static const double minRateOffset = -0.5;
  static const double maxRateOffset = 1.0;

  /// 音高偏移绝对值上限，半音。
  static const double maxPitchSemitones = 12;

  /// 音量偏移绝对值上限，dB。
  static const double maxVolumeDb = 12;

  /// 逐页 `hold` 上限，毫秒（漫画）。
  static const int maxHoldMs = 60000;

  /// 逐页 `lead` 上限，毫秒（漫画）。
  static const int maxLeadMs = 10000;

  /// 种子上限（32 位无符号，各引擎都能收）。
  static const int maxSeed = 0xFFFFFFFF;

  /// 语气说明（自由文本）最多保留的字数；超出的截断。
  static const int maxToneChars = 40;
}

/// 语气说明：去首尾空白、截到 [CastLineLimits.maxToneChars]；空或不是字符串返回 null。
String? castToneOf(Object? raw) {
  if (raw is! String) return null;
  final String t = raw.trim();
  if (t.isEmpty) return null;
  return t.length <= CastLineLimits.maxToneChars
      ? t
      : t.substring(0, CastLineLimits.maxToneChars);
}

// 有限数值才算数（NaN / 无穷当作没给）。
num? _finiteNum(Object? v) => v is num && v.isFinite ? v : null;

/// 有限数值四舍五入后夹到 `[lo, hi]`；不是有限数值返回 null。
int? castIntIn(Object? raw, int lo, int hi) {
  final num? v = _finiteNum(raw);
  return v?.round().clamp(lo, hi);
}

/// 有限数值夹到 `[lo, hi]`；不是有限数值返回 null。
double? castDoubleIn(Object? raw, double lo, double hi) {
  final num? v = _finiteNum(raw);
  return v?.toDouble().clamp(lo, hi);
}

/// 一句的演出字段（都可选）。JSON 键：`beat` / `e` / `ei` / `rate` / `pitch` /
/// `vol` / `seed` / `tone`（漫画与小说同名，冻结）。
class CastLineDirection {
  const CastLineDirection({
    this.beatMs = 0,
    this.emotion,
    this.intensity,
    this.rateOffset,
    this.pitchOffset,
    this.volumeOffset,
    this.seed,
    this.tone,
  });

  /// 宽松解析：数值夹到 [CastLineLimits] 的范围，不认识的情绪当作没标（强度随之
  /// 丢掉），种子只收整数。
  factory CastLineDirection.fromJson(Map<Object?, Object?> raw) {
    final CastEmotion? emotion = CastEmotion.parse(raw['e']);
    final Object? seed = raw['seed'];
    return CastLineDirection(
      beatMs: castIntIn(raw['beat'], 0, CastLineLimits.maxBeatMs) ?? 0,
      emotion: emotion,
      intensity: emotion == null
          ? null
          : castIntIn(raw['ei'], 0, CastLineLimits.maxIntensity),
      rateOffset: castDoubleIn(
        raw['rate'],
        CastLineLimits.minRateOffset,
        CastLineLimits.maxRateOffset,
      ),
      pitchOffset: castDoubleIn(
        raw['pitch'],
        -CastLineLimits.maxPitchSemitones,
        CastLineLimits.maxPitchSemitones,
      ),
      volumeOffset: castDoubleIn(
        raw['vol'],
        -CastLineLimits.maxVolumeDb,
        CastLineLimits.maxVolumeDb,
      ),
      seed: seed is int ? seed.clamp(0, CastLineLimits.maxSeed) : null,
      tone: castToneOf(raw['tone']),
    );
  }

  /// 句后额外停顿（毫秒），叠加在转场基础值之上。
  final int beatMs;

  final CastEmotion? emotion;

  /// 情绪强度 0..100（没有情绪时为 null）。
  final int? intensity;

  /// 语速 / 音高 / 音量偏移（可选；引擎不支持的字段忽略）。
  final double? rateOffset;
  final double? pitchOffset;
  final double? volumeOffset;

  /// 种子；null = 用作品默认种子（单句重生成时写入）。
  final int? seed;

  /// 自由文本语气说明（如「おずおずと、申し訳なさそうに」）：情绪词表装不下的细微差别
  /// （试探 / 辩解 / 保证 / 哀求）。能收自然语言的引擎拿它当演技指令。
  final String? tone;

  Map<String, Object?> toJson() => <String, Object?>{
    if (beatMs != 0) 'beat': beatMs,
    if (emotion != null) 'e': emotion!.wire,
    if (intensity != null) 'ei': intensity,
    if (rateOffset != null) 'rate': rateOffset,
    if (pitchOffset != null) 'pitch': pitchOffset,
    if (volumeOffset != null) 'vol': volumeOffset,
    if (seed != null) 'seed': seed,
    if (tone != null) 'tone': tone,
  };
}

/// 转场基础值的默认取值（试做里所有者听过两轮后的取值，不是测量结果）。
abstract final class CastTransitionDefaults {
  /// 同一人接着说下一句。
  static const int sameSpeakerMs = 300;

  /// 换人说话。
  static const int speakerChangeMs = 450;

  /// 内心（独白 / 心声 / 嘟囔）与说出口之间切换（优先于换人）。
  static const int registerShiftMs = 900;
}

/// 两句之间的转场基础值（不含一拍）：内心 ↔ 说出口切换 > 换人 > 同人。漫画与小说
/// 共用这一份判定（漫画再加翻页值，小说再与段落 / 场景停顿取大）。
int castTransitionBaseMs({
  required String speaker,
  required CastLineKind kind,
  required String nextSpeaker,
  required CastLineKind nextKind,
  int sameSpeakerMs = CastTransitionDefaults.sameSpeakerMs,
  int speakerChangeMs = CastTransitionDefaults.speakerChangeMs,
  int registerShiftMs = CastTransitionDefaults.registerShiftMs,
}) {
  if (kind.isInner != nextKind.isInner) return registerShiftMs;
  if (speaker != nextSpeaker) return speakerChangeMs;
  return sameSpeakerMs;
}
