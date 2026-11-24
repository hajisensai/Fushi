/// 合成的「演出参数」（设计 §5 / §6）：种子、给定时长，以及逐句的语气（情绪 + 强度、
/// 自由文本语气说明、语速 / 音高 / 音量偏移）。
///
/// 现有 [TtsProvider.synthesize] 只收文本。演出参数走一个**可选能力接口**
/// [TtsDirectedSynthesis]：引擎实现它并在 [TtsDirectedSynthesis.directionSupport] 里声明
/// 能表达哪些字段，调用方用 [effectiveTtsDirection] 去掉引擎不支持的字段后再调用；
/// 不实现它的引擎照旧走 [TtsProvider.synthesize]，演出参数整体忽略。缓存键只把**实际
/// 生效**的字段算进去（[TtsDirection.cacheIdentity]），所以同一句换不支持种子 / 语气的
/// 引擎时不会因为这些字段不同而重复合成，也不会让已有缓存失效。
///
/// 语气的落地（2026-11-23 起参与合成，此前「只标注」）：
/// - 引擎能原生表达情绪（风格 / 情感参数 / 自然语言指令）就声明
///   [TtsDirectionSupport.emotion]，自己翻译 [TtsDirection.emotion] + 强度；
/// - 不能表达情绪、但能调语速 / 音高 / 音量的引擎，[effectiveTtsDirection] 按
///   [ttsEmotionProsody] 把情绪折算成这三项偏移叠到标注的偏移上，再交给引擎——同一个
///   人连着说的一长串句子至少在节奏与音高上有起伏，不会全是一个调；
/// - 能收自然语言的引擎声明 [TtsDirectionSupport.tone]，用 [ttsDeliveryInstruction] 把
///   情绪 + 语气说明拼成一段指令。
library;

import 'package:fushi_engine/tts/cast/cast_line_direction.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';

/// 一次合成的演出参数（都可选）。
class TtsDirection {
  const TtsDirection({
    this.seed,
    this.durationSeconds,
    this.emotion,
    this.intensity,
    this.rateOffset,
    this.pitchOffset,
    this.volumeOffset,
    this.tone,
  });

  /// 由一句的演出字段（漫画演出稿 / 小说选角表共用的 [CastLineDirection]）构造；
  /// [seed] 是这句实际用的种子（单句 → 作品默认），[durationSeconds] 由调用方算。
  factory TtsDirection.fromLine(
    CastLineDirection line, {
    int? seed,
    double? durationSeconds,
  }) => TtsDirection(
    seed: seed,
    durationSeconds: durationSeconds,
    emotion: line.emotion == CastEmotion.neutral ? null : line.emotion,
    intensity: line.emotion == CastEmotion.neutral ? null : line.intensity,
    rateOffset: line.rateOffset,
    pitchOffset: line.pitchOffset,
    volumeOffset: line.volumeOffset,
    tone: line.tone,
  );

  static const TtsDirection none = TtsDirection();

  /// 采样种子（同一句同一种子应得到同一段音频）。
  final int? seed;

  /// 直接给定的音频时长（秒）；null = 引擎自己预测。
  final double? durationSeconds;

  /// 情绪（封闭词表；[CastEmotion.neutral] 视同没标）与强度 0..100（null = 中等）。
  final CastEmotion? emotion;
  final int? intensity;

  /// 语速偏移（倍率增量：-0.5 = 慢一半，+1.0 = 快一倍）。
  final double? rateOffset;

  /// 音高偏移，半音。
  final double? pitchOffset;

  /// 音量偏移，dB。
  final double? volumeOffset;

  /// 自由文本语气说明（如「おずおずと、申し訳なさそうに」）。
  final String? tone;

  bool get isEmpty =>
      seed == null &&
      durationSeconds == null &&
      emotion == null &&
      rateOffset == null &&
      pitchOffset == null &&
      volumeOffset == null &&
      tone == null;

  /// 强度（没标按 50）。
  int get effectiveIntensity => intensity ?? 50;

  /// 去掉给定时长（被拒拆句时片段不再沿用整句的时长，其余字段照旧）。
  TtsDirection withoutDuration() => TtsDirection(
    seed: seed,
    emotion: emotion,
    intensity: intensity,
    rateOffset: rateOffset,
    pitchOffset: pitchOffset,
    volumeOffset: volumeOffset,
    tone: tone,
  );

  /// 进缓存键的部分（只含实际生效的字段；数值按引擎能分辨的精度取整，避免浮点噪声）。
  Map<String, Object?> get cacheIdentity => <String, Object?>{
    if (seed != null) 'seed': seed,
    if (durationSeconds != null) 'durationCs': (durationSeconds! * 100).round(),
    if (emotion != null) 'emo': emotion!.wire,
    if (emotion != null) 'emoI': effectiveIntensity,
    if (rateOffset != null) 'rateC': (rateOffset! * 100).round(),
    if (pitchOffset != null) 'pitchD': (pitchOffset! * 10).round(),
    if (volumeOffset != null) 'volD': (volumeOffset! * 10).round(),
    if (tone != null) 'tone': tone,
  };
}

/// 引擎能表达的演出字段。
class TtsDirectionSupport {
  const TtsDirectionSupport({
    this.seed = false,
    this.duration = false,
    this.adapter = false,
    this.emotion = false,
    this.tone = false,
    this.rate = false,
    this.pitch = false,
    this.volume = false,
  });

  static const TtsDirectionSupport none = TtsDirectionSupport();

  final bool seed;
  final bool duration;

  /// 这份声音挂了 LoRA adapter（时长预测可靠，漫画短句定长规则不适用）。
  final bool adapter;

  /// 引擎能原生表达情绪（风格 / 情感参数 / 指令）。false 时情绪按
  /// [ttsEmotionProsody] 折进语速 / 音高 / 音量（引擎支持其中任一项时）。
  final bool emotion;

  /// 引擎能收自然语言的语气说明（见 [ttsDeliveryInstruction]）。
  final bool tone;

  /// 引擎能逐句调语速 / 音高 / 音量。
  final bool rate;
  final bool pitch;
  final bool volume;

  bool get prosody => rate || pitch || volume;
}

/// 能收演出参数的引擎实例（可选能力；见库注释）。
abstract interface class TtsDirectedSynthesis {
  TtsDirectionSupport get directionSupport;

  /// 同 [TtsProvider.synthesize]，外加演出参数。[direction] 已经按
  /// [directionSupport] 去掉了不支持的字段（情绪已按需折成偏移）。
  Future<TtsResult> synthesizeDirected(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
    required TtsDirection direction,
  });
}

/// [provider] 的演出能力；不实现 [TtsDirectedSynthesis] 的一律 [TtsDirectionSupport.none]。
TtsDirectionSupport ttsDirectionSupportOf(TtsProvider provider) =>
    switch (provider) {
      final TtsDirectedSynthesis directed => directed.directionSupport,
      _ => TtsDirectionSupport.none,
    };

/// 情绪折算成的语速 / 音高 / 音量偏移（给不能原生表达情绪的引擎用）。
typedef TtsProsodyOffsets = ({double rate, double pitch, double volume});

/// 各情绪在强度 100 时的偏移（语速倍率增量 / 半音 / dB），按强度线性缩放。取值是
/// 「听得出起伏、不至于变调」的保守量：最大约 ±12% 语速、±2.5 半音、±3 dB。
const Map<CastEmotion, TtsProsodyOffsets> kTtsEmotionProsody =
    <CastEmotion, TtsProsodyOffsets>{
      CastEmotion.neutral: (rate: 0, pitch: 0, volume: 0),
      CastEmotion.joy: (rate: 0.08, pitch: 1.5, volume: 1),
      CastEmotion.sadness: (rate: -0.12, pitch: -1.5, volume: -2),
      CastEmotion.anger: (rate: 0.06, pitch: 0.5, volume: 3),
      CastEmotion.surprise: (rate: 0.05, pitch: 2.5, volume: 2),
      CastEmotion.fear: (rate: 0.10, pitch: 1.5, volume: -1),
      CastEmotion.disgust: (rate: -0.05, pitch: -1, volume: 0),
      CastEmotion.embarrassment: (rate: 0.04, pitch: 1, volume: -2),
      CastEmotion.tenderness: (rate: -0.10, pitch: -0.5, volume: -2),
      CastEmotion.tension: (rate: 0.06, pitch: 0.5, volume: 0),
    };

/// [emotion] 在 [intensity]（0..100）下折算出的偏移。
TtsProsodyOffsets ttsEmotionProsody(CastEmotion emotion, int intensity) {
  final TtsProsodyOffsets base = kTtsEmotionProsody[emotion]!;
  final double k = intensity.clamp(0, CastLineLimits.maxIntensity) / 100;
  return (rate: base.rate * k, pitch: base.pitch * k, volume: base.volume * k);
}

// 0 当作没给（不进缓存键、不下发）。
double? _nonZero(double v) => v.abs() < 1e-9 ? null : v;

/// 去掉 [support] 不支持的字段。引擎不能原生表达情绪、但能调语速 / 音高 / 音量时，
/// 情绪按 [ttsEmotionProsody] 折进这几项偏移（与标注的偏移相加后夹到
/// [CastLineLimits] 的范围）。
TtsDirection effectiveTtsDirection(
  TtsDirectionSupport support,
  TtsDirection wanted,
) {
  final CastEmotion? emotion = wanted.emotion;
  final TtsProsodyOffsets folded = emotion != null && !support.emotion
      ? ttsEmotionProsody(emotion, wanted.effectiveIntensity)
      : (rate: 0, pitch: 0, volume: 0);
  double? offset(
    bool supported,
    double? given,
    double add,
    double lo,
    double hi,
  ) {
    if (!supported) return null;
    if (given == null && add == 0) return null;
    return _nonZero(((given ?? 0) + add).clamp(lo, hi).toDouble());
  }

  return TtsDirection(
    seed: support.seed ? wanted.seed : null,
    durationSeconds: support.duration ? wanted.durationSeconds : null,
    emotion: support.emotion ? emotion : null,
    intensity: support.emotion && emotion != null ? wanted.intensity : null,
    rateOffset: offset(
      support.rate,
      wanted.rateOffset,
      folded.rate,
      CastLineLimits.minRateOffset,
      CastLineLimits.maxRateOffset,
    ),
    pitchOffset: offset(
      support.pitch,
      wanted.pitchOffset,
      folded.pitch,
      -CastLineLimits.maxPitchSemitones,
      CastLineLimits.maxPitchSemitones,
    ),
    volumeOffset: offset(
      support.volume,
      wanted.volumeOffset,
      folded.volume,
      -CastLineLimits.maxVolumeDb,
      CastLineLimits.maxVolumeDb,
    ),
    tone: support.tone ? wanted.tone : null,
  );
}

/// 情绪的日语描述（给收自然语言的引擎）。
const Map<CastEmotion, String> kTtsEmotionJa = <CastEmotion, String>{
  CastEmotion.neutral: '平静',
  CastEmotion.joy: '嬉しそう',
  CastEmotion.sadness: '悲しげ',
  CastEmotion.anger: '怒り',
  CastEmotion.surprise: '驚き',
  CastEmotion.fear: '怯え',
  CastEmotion.disgust: '嫌悪',
  CastEmotion.embarrassment: '照れ・気恥ずかしさ',
  CastEmotion.tenderness: '優しく',
  CastEmotion.tension: '緊張',
};

/// 强度的日语程度词。
String _degreeJa(int intensity) => intensity >= 75
    ? '強く'
    : intensity >= 40
    ? ''
    : 'わずかに';

/// 把情绪 + 强度 + 语气说明拼成一段日语演技指令（如「感情：悲しげ（強く）。
/// 話し方：おずおずと、申し訳なさそうに。」）；什么都没有返回 null。只读
/// [direction] 里还留着的字段（引擎不支持的已被 [effectiveTtsDirection] 去掉）。
String? ttsDeliveryInstruction(TtsDirection direction) {
  final List<String> parts = <String>[];
  final CastEmotion? emotion = direction.emotion;
  if (emotion != null && emotion != CastEmotion.neutral) {
    final String degree = _degreeJa(direction.effectiveIntensity);
    parts.add(
      degree.isEmpty
          ? '感情：${kTtsEmotionJa[emotion]}'
          : '感情：${kTtsEmotionJa[emotion]}（$degree）',
    );
  }
  final String? tone = direction.tone?.trim();
  if (tone != null && tone.isNotEmpty) parts.add('話し方：$tone');
  if (parts.isEmpty) return null;
  return '${parts.join('。')}。';
}

/// 按能力合成：有生效的演出字段且引擎支持就走 [TtsDirectedSynthesis]，否则走普通合成。
Future<TtsResult> synthesizeWithDirection(
  TtsProvider provider,
  String text, {
  required String outputPath,
  required TtsCancelToken cancel,
  required TtsDirection direction,
}) {
  if (direction.isEmpty) {
    return provider.synthesize(text, outputPath: outputPath, cancel: cancel);
  }
  if (provider case final TtsDirectedSynthesis directed) {
    return directed.synthesizeDirected(
      text,
      outputPath: outputPath,
      cancel: cancel,
      direction: direction,
    );
  }
  return provider.synthesize(text, outputPath: outputPath, cancel: cancel);
}
