import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';

import '../audiobook/audiobook_model.dart';

/// 跟读显示余量（设备端转录产物专用，能量吸附 + 句内碎片合并之后跑）。
///
/// 吸附与修边把起止贴到了真实声音上（开口前 40~150 ms、收声后 80 ms）。贴得紧对快
/// 节奏的连读是对的，但慢 / 正常语速时字幕刚念完就消失、下一句开口才出现，读起来
/// 赶。这里按 cue 有声跨度的字速分三档：快档几乎不加，正常 / 慢档在开口前、收声后
/// 各多留一两百毫秒；句间停顿越长尾巴越宽（停顿 × [gapTailRatio]，封顶
/// [tailCapMs]）。与前后句的空地不超过 [glueMs]（连读 / 窄缝）的一侧不加。
///
/// 只外扩、不内收，起点不压前一条终点、终点不越过下一条起点 − [tailSafetyMs]，跨音频
/// 文件的邻居不参与——不改文本、条数与匹配区间。判定本体在 Rust
/// （`native/fushi_compute/src/signal.rs` 的 `display_margins`，整本书一次调用）。
///
/// 七魔剑 II 整卷（K2）：不足 0.8 s 的 cue 283 → 170，收声后续显中位 79 → 174 ms，
/// 晚起点 / 重叠 / 覆盖率不变（参照 YuiMoe 的余量做法与 SubPlz 的较宽句间间隔）。
class CueDisplayMargins {
  const CueDisplayMargins({
    this.frameMs = 20,
    this.floorMarginDb = 16,
    this.minThresholdDb = -50,
    this.maxThresholdDb = -30,
    this.minVoiceMs = 60,
    this.slowCps = 5.5,
    this.fastCps = 7.0,
    this.headSlowMs = 120,
    this.headNormalMs = 80,
    this.headFastMs = 40,
    this.tailSlowMs = 180,
    this.tailNormalMs = 100,
    this.tailFastMs = 20,
    this.gapTailRatio = 0.18,
    this.tailCapMs = 250,
    this.glueMs = 400,
    this.tailSafetyMs = 50,
  });

  /// 包络帧长（与转录时写入的一致）。
  final int frameMs;

  /// 有声门限（与 `CueEnergySnapper` 同口径）：附近底噪第 10 百分位 + [floorMarginDb]，
  /// 夹到 [[minThresholdDb], [maxThresholdDb]]。
  final double floorMarginDb;
  final double minThresholdDb;
  final double maxThresholdDb;

  /// 多长的连续有声才算真开口 / 真收声。
  final int minVoiceMs;

  /// 字速分档（正文字母 / 数字 / 假名 / 汉字每秒，按有声跨度算）：低于 [slowCps] 为慢，
  /// 不低于 [fastCps] 为快。
  final double slowCps;
  final double fastCps;

  /// 起点在开口前留的毫秒数，按慢 / 正常 / 快。
  final int headSlowMs;
  final int headNormalMs;
  final int headFastMs;

  /// 终点在收声后留的基础毫秒数，按慢 / 正常 / 快（快档不吃停顿项）。
  final int tailSlowMs;
  final int tailNormalMs;
  final int tailFastMs;

  /// 慢 / 正常档尾巴还可以取 `(停顿 − glueMs) × gapTailRatio`，与基础量取大。
  final double gapTailRatio;

  /// 尾巴上限。
  final int tailCapMs;

  /// 与邻句空地不超过此值视为连读，该侧不加余量。
  final int glueMs;

  /// 终点与下一条起点之间至少留的空隙。
  final int tailSafetyMs;

  /// 就地改 [cues]（按时间排序）的起止，返回动过的边数。[energyDb] 为空或没有 cue
  /// 时不动。库不可用抛 `FushiComputeUnavailableError`。
  int apply(List<AudioCue> cues, Int8List energyDb) {
    if (energyDb.isEmpty || cues.isEmpty) return 0;
    final Int64List packed = Int64List(cues.length * kFfcDisplayCueStride);
    for (int i = 0; i < cues.length; i++) {
      final AudioCue cue = cues[i];
      final int at = i * kFfcDisplayCueStride;
      packed[at] = cue.startMs;
      packed[at + 1] = cue.endMs;
      packed[at + 2] = cue.audioFileIndex;
      packed[at + 3] = countSpokenChars(cue.text);
    }
    final int moved = ffcCueDisplayMargins(packed, energyDb, _params());
    for (int i = 0; i < cues.length; i++) {
      final AudioCue cue = cues[i];
      final int at = i * kFfcDisplayCueStride;
      final int start = packed[at];
      if (start != cue.startMs) _shiftStart(cue, start);
      cue.endMs = packed[at + 1];
    }
    return moved;
  }

  /// 字速分档用的字数：字母、数字（含全角）、假名、汉字；标点与空白不算。
  static int countSpokenChars(String text) {
    int n = 0;
    for (final int c in text.runes) {
      if (_isSpoken(c)) n++;
    }
    return n;
  }

  static bool _isSpoken(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      (c >= 0x3041 && c <= 0x309F && c != 0x309B && c != 0x309C) ||
      (c >= 0x30A1 && c <= 0x30FA) ||
      c == 0x30FC ||
      (c >= 0x3400 && c <= 0x4DBF) ||
      (c >= 0x4E00 && c <= 0x9FFF) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0xFF10 && c <= 0xFF19) ||
      (c >= 0xFF21 && c <= 0xFF3A) ||
      (c >= 0xFF41 && c <= 0xFF5A) ||
      (c >= 0xFF66 && c <= 0xFF9D) ||
      (c >= 0x20000 && c <= 0x2FFFF);

  Float64List _params() => Float64List.fromList(<double>[
    frameMs.toDouble(),
    floorMarginDb,
    minThresholdDb,
    maxThresholdDb,
    minVoiceMs.toDouble(),
    slowCps,
    fastCps,
    headSlowMs.toDouble(),
    headNormalMs.toDouble(),
    headFastMs.toDouble(),
    tailSlowMs.toDouble(),
    tailNormalMs.toDouble(),
    tailFastMs.toDouble(),
    gapTailRatio,
    tailCapMs.toDouble(),
    glueMs.toDouble(),
    tailSafetyMs.toDouble(),
  ]);

  /// 起点提前时 token 偏移（相对起点）一起平移，绝对发射时刻不变。
  static void _shiftStart(AudioCue cue, int start) {
    final CueTokenTiming? t = cue.tokenTiming;
    final int delta = start - cue.startMs;
    cue.startMs = start;
    if (t == null || t.isEmpty || delta == 0) return;
    cue.tokenTiming = CueTokenTiming(
      tokens: t.tokens,
      offsetsMs: List<int>.unmodifiable(t.offsetsMs.map((int o) => o - delta)),
    );
  }
}
