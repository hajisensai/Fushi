import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';

import '../audiobook/audiobook_model.dart';

/// 把**紧挨着**的两条 cue 之间的切点吸到真实的停顿（能量谷）上（设备端转录产物
/// 专用，重切之后、落库之前跑）。
///
/// 重切器在正文句号处新加的切点取「下一句首 token − 150 ms」，而 RNN-T 的发射
/// 时刻相对真实发声前后漂 −440 ~ +340 ms：同一个切点既是前句终点又是后句起点，
/// 常数补偿只能把误差从一侧推到另一侧（春物 2 卷整本实测提前量 150 → 0 ms，
/// 起点提前嫌疑反而 441 → 463）。这里改用声学证据：在切点 ±[windowMs] 内找
/// 「足够长、离原切点不远」的低能量谷，前句收在谷起点 + [tailMs]，后句从谷终点
/// − [leadMs] 起。
///
/// 只动时间，不动文本、区间与条数——覆盖率与阅读器定位不受影响。缺包络（旧任务、
/// 非转录产物）、找不到谷、或吸附后任一侧短于 [minDurationMs] 时该切点原样保留。
class CueEnergySnapper {
  const CueEnergySnapper({
    this.frameMs = 20,
    this.maxGapMs = 400,
    this.windowMs = 600,
    this.minValleyMs = 120,
    this.distancePenalty = 0.5,
    this.tailMs = 80,
    this.leadMs = 40,
    this.minDurationMs = 500,
    this.floorMarginDb = 16,
    this.minThresholdDb = -50,
    this.maxThresholdDb = -30,
    this.tokenGuardMs = 200,
    this.edgeMaxShiftMs = 600,
    this.edgeMinVoiceMs = 60,
    this.edgeLeadMs = 150,
    this.edgeTailMs = 80,
  });

  /// [refineEdges]：终点留到收声后多少。春物卷 2 扫过 80 / 150：150 起点延迟
  /// p90 从 88 涨回 110~124 ms、尾挂变多，只换来提前截断少 3~9 条。
  final int edgeTailMs;

  /// [refineEdges]：起点挪到开口前多少。比 [leadMs] 宽——轻声开口（气声、清辅音）
  /// 常在门限下，40 ms 时字头被切（晚起 > 150 ms）11~16 条，150 ms 降到 7~8 条，
  /// 提前开始几乎不变（春物卷 2 扫 40 / 100 / 150）。
  final int edgeLeadMs;

  /// [refineEdges]：起止点最多往 cue 内收多远。
  final int edgeMaxShiftMs;

  /// [refineEdges]：多长的连续有声才算真开口 / 真收声（滤掉单帧噪声）。
  final int edgeMinVoiceMs;

  /// 包络帧长（与转录时写入的一致）。
  final int frameMs;

  /// 两条 cue 之间空隙超过此值就不算「紧挨着」（那是 VAD 已经切开的停顿）。
  final int maxGapMs;

  /// 在原切点前后多远内找谷。
  final int windowMs;

  /// 谷的最短长度：塞音闭塞只有几十毫秒，不算句间停顿。
  final int minValleyMs;

  /// 选谷打分 = 谷长 − 此系数 × 谷中心离原切点的距离（都按毫秒）。
  final double distancePenalty;

  /// 前句终点在谷起点之后留的余韵。
  final int tailMs;

  /// 后句起点在谷终点之前提前的量。
  final int leadMs;

  /// 吸附后两侧 cue 都不得短于此值，否则不动。
  final int minDurationMs;

  /// 门限 = 附近 ±15 s 电平第 10 百分位（底噪）+ 此值，夹到
  /// [[minThresholdDb], [maxThresholdDb]]。下限比能量 VAD（−55）高：−45 ~ −55 dB
  /// 的气声/混响尾巴听感上已是静音，按 −55 判会把前句终点推迟进停顿里。
  final double floorMarginDb;
  final double minThresholdDb;
  final double maxThresholdDb;

  /// 后句新起点不晚于它首 token 发射时刻 + 此值（RNN-T 首 token 一般早于开口，
  /// 比它还晚很多就是吸错了谷、会吃掉字头）。
  final int tokenGuardMs;

  // 两个方法共用的门限：每 250 帧一块、取前后 750 帧已知电平的第 10 百分位当底噪 +
  // [floorMarginDb]，夹到 [[minThresholdDb], [maxThresholdDb]]。判定本体在 Rust
  // （native/fushi_compute/src/signal.rs，整本书一次调用），这里只打包 / 写回。

  /// [energyDb]：从时间 0 起每 [frameMs] 一帧的电平（整数 dBFS，0 = 未知，按有声
  /// 处理）。就地修改 [cues] 的起止时间，返回挪动的切点数。
  ///
  /// 库不可用抛 `FushiComputeUnavailableError`；[frameMs] <= 0 或门限上下限颠倒抛
  /// [ArgumentError]。
  int snap(List<AudioCue> cues, Int8List energyDb) {
    if (energyDb.isEmpty || cues.length < 2) return 0;
    final Int64List packed = _pack(cues);
    final int moved = ffcCueEnergySnap(packed, energyDb, _params());
    _unpack(cues, packed);
    return moved;
  }

  /// 起止点落在静音里时收回到真实有声处（[snap] 之后跑）。
  ///
  /// [snap] 只管紧挨着的两条 cue；前面是长停顿的起点、后面是长停顿的终点它不碰，
  /// 而那里恰是 token 时刻粗的模型（Kitsune CTC 80 ms 一帧、多字 token 线性摊开，
  /// 同一字相对 RNN-T ±200 ms 散布）最常把字幕挂进静音的地方：
  /// - 起点所在帧是静音 → 往后 [edgeMaxShiftMs] 内找第一段 ≥ [edgeMinVoiceMs] 的
  ///   有声，起点挪到它 − [edgeLeadMs]；
  /// - 终点前一帧是静音 → 往前同样找最后一段有声，终点收到它 + [edgeTailMs]，但不早于
  ///   末 token 发射时刻 − [tokenGuardMs]。
  ///
  /// 只往 cue 内部收，不越界、不动文本；挪完短于 [minDurationMs] 的不动。返回
  /// 挪动的边数。异常同 [snap]。
  int refineEdges(List<AudioCue> cues, Int8List energyDb) {
    if (energyDb.isEmpty || cues.isEmpty) return 0;
    final Int64List packed = _pack(cues);
    final int moved = ffcCueRefineEdges(packed, energyDb, _params());
    _unpack(cues, packed);
    return moved;
  }

  /// 顺序见 [kFfcSnapParamCount]。
  Float64List _params() => Float64List.fromList(<double>[
    frameMs.toDouble(),
    maxGapMs.toDouble(),
    windowMs.toDouble(),
    minValleyMs.toDouble(),
    distancePenalty,
    tailMs.toDouble(),
    leadMs.toDouble(),
    minDurationMs.toDouble(),
    floorMarginDb,
    minThresholdDb,
    maxThresholdDb,
    tokenGuardMs.toDouble(),
    edgeMaxShiftMs.toDouble(),
    edgeMinVoiceMs.toDouble(),
    edgeLeadMs.toDouble(),
    edgeTailMs.toDouble(),
  ]);

  /// 打包成 [kFfcSnapCueStride] 槽一条：起止、文件序号、有无 token、首末 token 偏移
  /// （判定只看首末两个偏移；平移规则 `max(0, o − Δ)` 单调，首末位置不变）。
  static Int64List _pack(List<AudioCue> cues) {
    final Int64List out = Int64List(cues.length * kFfcSnapCueStride);
    for (int i = 0; i < cues.length; i++) {
      final AudioCue cue = cues[i];
      final CueTokenTiming? t = cue.tokenTiming;
      final bool hasTokens = t != null && !t.isEmpty;
      final int at = i * kFfcSnapCueStride;
      out[at] = cue.startMs;
      out[at + 1] = cue.endMs;
      out[at + 2] = cue.audioFileIndex;
      out[at + 3] = hasTokens ? 1 : 0;
      out[at + 4] = hasTokens ? t.offsetsMs.first : 0;
      out[at + 5] = hasTokens ? t.offsetsMs.last : 0;
    }
    return out;
  }

  /// 写回 Rust 改过的起止。每条 cue 的起点在一次调用里最多挪一次，所以按新旧起点之差
  /// 一次平移全部 token 偏移，与原先在循环里就地平移结果相同。
  static void _unpack(List<AudioCue> cues, Int64List packed) {
    for (int i = 0; i < cues.length; i++) {
      final AudioCue cue = cues[i];
      final int at = i * kFfcSnapCueStride;
      if (packed[at] != cue.startMs) _shiftStart(cue, packed[at]);
      cue.endMs = packed[at + 1];
    }
  }

  /// 挪起点时 token 偏移（相对起点）一起平移，绝对发射时刻不变。
  static void _shiftStart(AudioCue cue, int start) {
    final CueTokenTiming? t = cue.tokenTiming;
    final int delta = start - cue.startMs;
    cue.startMs = start;
    if (t == null || t.isEmpty || delta == 0) return;
    cue.tokenTiming = CueTokenTiming(
      tokens: t.tokens,
      offsetsMs: List<int>.unmodifiable(
        t.offsetsMs.map((int o) => math.max(0, o - delta)),
      ),
    );
  }
}
