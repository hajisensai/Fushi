/// 合成的「演出参数」（设计 §5 / §6）：种子、给定时长这类引擎无关的字段。
///
/// 现有 [TtsProvider.synthesize] 只收文本。演出参数走一个**可选能力接口**
/// [TtsDirectedSynthesis]：引擎实现它并在 [TtsDirectedSynthesis.directionSupport] 里声明
/// 能表达哪些字段，调用方用 [effectiveTtsDirection] 去掉引擎不支持的字段后再调用；
/// 不实现它的引擎照旧走 [TtsProvider.synthesize]，演出参数整体忽略。缓存键只把**实际
/// 生效**的字段算进去（[TtsDirection.cacheIdentity]），所以同一句换不支持种子的引擎时
/// 不会因为种子不同而重复合成。
///
/// 现状（2026-11-17）：仓内没有引擎实现它——Irodori 官方服务端（`61012c7`）请求体只有
/// `voice` + `caption`，是否收种子 / 时长未核实（设计 §5）；v4-large 批处理 worker
/// 落地时由它实现。因此漫画短句定长规则（handoff「不挂 LoRA 的声音在短句上念两遍」）
/// 今天在 app 里不生效，等引擎声明 [TtsDirectionSupport.duration] 后自动生效。
library;

import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';

/// 一次合成的演出参数（都可选）。
class TtsDirection {
  const TtsDirection({this.seed, this.durationSeconds});

  static const TtsDirection none = TtsDirection();

  /// 采样种子（同一句同一种子应得到同一段音频）。
  final int? seed;

  /// 直接给定的音频时长（秒）；null = 引擎自己预测。
  final double? durationSeconds;

  bool get isEmpty => seed == null && durationSeconds == null;

  /// 进缓存键的部分（只含实际生效的字段；时长按 10 ms 取整，避免浮点噪声）。
  Map<String, Object?> get cacheIdentity => <String, Object?>{
    if (seed != null) 'seed': seed,
    if (durationSeconds != null) 'durationCs': (durationSeconds! * 100).round(),
  };
}

/// 引擎能表达的演出字段。
class TtsDirectionSupport {
  const TtsDirectionSupport({
    this.seed = false,
    this.duration = false,
    this.adapter = false,
  });

  static const TtsDirectionSupport none = TtsDirectionSupport();

  final bool seed;
  final bool duration;

  /// 这份声音挂了 LoRA adapter（时长预测可靠，漫画短句定长规则不适用）。
  final bool adapter;
}

/// 能收演出参数的引擎实例（可选能力；见库注释）。
abstract interface class TtsDirectedSynthesis {
  TtsDirectionSupport get directionSupport;

  /// 同 [TtsProvider.synthesize]，外加演出参数。[direction] 已经按
  /// [directionSupport] 去掉了不支持的字段。
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

/// 去掉 [support] 不支持的字段。
TtsDirection effectiveTtsDirection(
  TtsDirectionSupport support,
  TtsDirection wanted,
) => TtsDirection(
  seed: support.seed ? wanted.seed : null,
  durationSeconds: support.duration ? wanted.durationSeconds : null,
);

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
