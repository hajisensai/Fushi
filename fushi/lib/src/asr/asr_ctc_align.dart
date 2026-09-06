/// CTC 强制对齐（forced alignment）：给定一段音频的 CTC `logits[T, V]` 与已知
/// 文本，用 Viterbi 求每个字符 token 的起止帧。
///
/// 纯 Dart、无 IO。输入是 Omnilingual 这类字符级 CTC 模型的**原始 logit**
/// （未 softmax；`<s>`=blank=0，空格本身是 token），内部逐帧做 log-softmax。
///
/// 标准 CTC 拓扑：S 个 label 之间与两端插 blank，共 `2S+1` 个状态；
/// 相邻 label 不同时允许跳过中间 blank（`s-2 → s`），相同时必须经过 blank。
///
/// 内存：alpha 只保留相邻两帧（`double`），backpointer 用 `Uint8List`
/// （每格 0/1/2 = 来自 `s` / `s-1` / `s-2`），`frames × (2S+1)` 字节。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/asr/asr_types.dart';

/// 字符级词表的「文本 → token id」编码器（强制对齐要把正文编码成模型 token 序列）。
///
/// 构造时建一张 `token 文本 → id` 表，跳过特殊符号（blank / unk / eos / pad）
/// 与空 token；同一文本出现多次时取最小 id。
class AsrCtcTextEncoder {
  AsrCtcTextEncoder(AsrTokenTable table)
      : _isSupported = !table.isSentencePiece,
        _idByText = _buildIndex(table);

  final bool _isSupported;
  final Map<String, int> _idByText;

  /// SentencePiece 形态词表返回 false（BPE 需要分词器，逐字符查表没有意义）。
  bool get isSupported => _isSupported;

  static Map<String, int> _buildIndex(AsrTokenTable table) {
    final Map<String, int> index = <String, int>{};
    for (int id = 0; id < table.size; id++) {
      if (table.isSpecial(id)) {
        continue;
      }
      final String text = table.tokenAt(id);
      if (text.isEmpty) {
        continue;
      }
      index.putIfAbsent(text, () => id);
    }
    return index;
  }

  /// 逐 rune 查表；查不到的字符跳过（**不填 `<unk>`**——unk 会吸收任何帧，毁掉对齐）。
  ///
  /// 返回 ids 与每个 id 对应的原文 UTF-16 码元偏移（便于把帧时间映射回原文字符；
  /// 增补平面字符占两个码元）。词表不受支持（[isSupported] 为 false）时返回空。
  AsrCtcEncodedText encode(String text) {
    final List<int> ids = <int>[];
    final List<int> offsets = <int>[];
    if (!_isSupported) {
      return AsrCtcEncodedText._(ids, offsets);
    }
    int offset = 0;
    for (final int rune in text.runes) {
      final int? id = _idByText[String.fromCharCode(rune)];
      if (id != null) {
        ids.add(id);
        offsets.add(offset);
      }
      offset += rune > 0xFFFF ? 2 : 1;
    }
    return AsrCtcEncodedText._(ids, offsets);
  }
}

/// [AsrCtcTextEncoder.encode] 的产物：token id 序列与各自在原文中的 UTF-16 偏移。
@immutable
class AsrCtcEncodedText {
  AsrCtcEncodedText._(List<int> ids, List<int> charOffsets)
      : assert(ids.length == charOffsets.length),
        ids = List<int>.unmodifiable(ids),
        charOffsets = List<int>.unmodifiable(charOffsets);

  final List<int> ids;
  final List<int> charOffsets;

  int get length => ids.length;
  bool get isEmpty => ids.isEmpty;
}

/// 一个 token 的对齐结果：起始帧（含）、结束帧（不含）、该 token 帧上的平均 log-prob。
@immutable
class AsrCtcAlignedToken {
  const AsrCtcAlignedToken({
    required this.id,
    required this.startFrame,
    required this.endFrame,
    required this.meanLogProb,
  });

  final int id;
  final int startFrame;
  final int endFrame;
  final double meanLogProb;

  int get frameCount => endFrame - startFrame;

  @override
  String toString() => 'AsrCtcAlignedToken(id=$id, [$startFrame, $endFrame), '
      'meanLogProb=${meanLogProb.toStringAsFixed(3)})';
}

/// 整段的对齐结果：每个 label 一条 [AsrCtcAlignedToken]（顺序同 targets），
/// [totalLogProb] 是 Viterbi 最优路径的总 log-prob（各帧 log-softmax 之和）。
@immutable
class AsrCtcAlignment {
  AsrCtcAlignment._(List<AsrCtcAlignedToken> tokens, this.totalLogProb)
      : tokens = List<AsrCtcAlignedToken>.unmodifiable(tokens);

  final List<AsrCtcAlignedToken> tokens;
  final double totalLogProb;
}

/// Viterbi 强制对齐。
///
/// [logits] 是一行的 `[frames × vocab]` 行主序原始 logit（调用方已剥掉 padding
/// 行/帧），内部逐帧做 log-softmax（logsumexp over vocab）。
///
/// 返回 null 的情况：
/// - targets 比帧数能容纳的还长（需要 `S + 相邻重复对数 ≤ frames`）；
/// - `frames × (2S+1)` 超过 [maxCells] 预算（默认 5000 万格）。
///
/// targets 为空时返回零 token 的对齐（totalLogProb = 全 blank 路径分数）。
///
/// 抛 [ArgumentError]：`vocab <= 0`、`frames < 0`、logits 长度 ≠ `frames × vocab`、
/// [blankId] 越界、targets 含越界 id 或 blank。
AsrCtcAlignment? ctcForcedAlign({
  required Float32List logits,
  required int frames,
  required int vocab,
  required List<int> targets,
  required int blankId,
  int maxCells = 50000000,
}) {
  _validateArguments(
    logits: logits,
    frames: frames,
    vocab: vocab,
    targets: targets,
    blankId: blankId,
  );
  final int labelCount = targets.length;
  final int numStates = 2 * labelCount + 1;
  if (frames < _minFramesFor(targets)) {
    return null;
  }
  if (frames * numStates > maxCells) {
    return null;
  }
  if (frames == 0) {
    // 只有 targets 为空才会走到这里（否则上面已判帧数不足）：空路径分数为 log 1。
    return AsrCtcAlignment._(const <AsrCtcAlignedToken>[], 0);
  }

  // 每帧 logsumexp，前向与回溯共用：lp(t, v) = logit[t, v] - lse[t]。
  final Float64List lse = Float64List(frames);
  for (int t = 0; t < frames; t++) {
    lse[t] = _logSumExp(logits, t * vocab, vocab);
  }

  // 状态 s 的发射 id：偶数 = blank，奇数 = targets[(s-1)/2]。
  final Int32List stateIds = Int32List(numStates);
  for (int s = 0; s < numStates; s++) {
    stateIds[s] = s.isEven ? blankId : targets[(s - 1) >> 1];
  }
  // 奇数状态 s 能否从 s-2 跳过 blank：相邻 label 不同才行。
  final Uint8List canSkip = Uint8List(numStates);
  for (int s = 3; s < numStates; s += 2) {
    canSkip[s] = targets[(s - 1) >> 1] != targets[(s - 3) >> 1] ? 1 : 0;
  }

  final Uint8List backpointers = Uint8List(frames * numStates);
  Float64List prev = Float64List(numStates);
  Float64List cur = Float64List(numStates);

  // t = 0：只能落在状态 0（blank）或 1（首 label）。
  prev.fillRange(0, numStates, double.negativeInfinity);
  prev[0] = logits[blankId] - lse[0];
  if (labelCount > 0) {
    prev[1] = logits[stateIds[1]] - lse[0];
  }

  for (int t = 1; t < frames; t++) {
    final int base = t * vocab;
    final int bpBase = t * numStates;
    for (int s = 0; s < numStates; s++) {
      double best = prev[s];
      int from = 0;
      if (s >= 1 && prev[s - 1] > best) {
        best = prev[s - 1];
        from = 1;
      }
      if (canSkip[s] == 1 && prev[s - 2] > best) {
        best = prev[s - 2];
        from = 2;
      }
      backpointers[bpBase + s] = from;
      cur[s] = best == double.negativeInfinity
          ? double.negativeInfinity
          : best + logits[base + stateIds[s]] - lse[t];
    }
    final Float64List swap = prev;
    prev = cur;
    cur = swap;
  }

  // 终态：末尾 blank（2S）或末 label（2S-1）取优。
  int state = numStates - 1;
  double total = prev[state];
  if (labelCount > 0 && prev[numStates - 2] > total) {
    state = numStates - 2;
    total = prev[state];
  }
  if (total == double.negativeInfinity) {
    return null;
  }

  // 回溯：逐帧记录所在状态，并累计各 label 的帧数与 log-prob。
  final Int32List startFrames = Int32List(labelCount);
  final Int32List endFrames = Int32List(labelCount);
  final Float64List logProbSums = Float64List(labelCount);
  for (int t = frames - 1; t >= 0; t--) {
    if (state.isOdd) {
      final int label = (state - 1) >> 1;
      if (endFrames[label] == 0) {
        endFrames[label] = t + 1;
      }
      startFrames[label] = t;
      logProbSums[label] += logits[t * vocab + stateIds[state]] - lse[t];
    }
    if (t > 0) {
      state -= backpointers[t * numStates + state];
    }
  }

  final List<AsrCtcAlignedToken> tokens = <AsrCtcAlignedToken>[];
  for (int i = 0; i < labelCount; i++) {
    final int count = endFrames[i] - startFrames[i];
    tokens.add(
      AsrCtcAlignedToken(
        id: targets[i],
        startFrame: startFrames[i],
        endFrame: endFrames[i],
        meanLogProb: logProbSums[i] / count,
      ),
    );
  }
  return AsrCtcAlignment._(tokens, total);
}

void _validateArguments({
  required Float32List logits,
  required int frames,
  required int vocab,
  required List<int> targets,
  required int blankId,
}) {
  if (vocab <= 0) {
    throw ArgumentError.value(vocab, 'vocab', '必须为正');
  }
  if (frames < 0) {
    throw ArgumentError.value(frames, 'frames', '不能为负');
  }
  if (logits.length != frames * vocab) {
    throw ArgumentError.value(
      logits.length,
      'logits',
      '长度应为 frames × vocab = ${frames * vocab}',
    );
  }
  if (blankId < 0 || blankId >= vocab) {
    throw ArgumentError.value(blankId, 'blankId', '越界（vocab=$vocab）');
  }
  for (int i = 0; i < targets.length; i++) {
    final int id = targets[i];
    if (id < 0 || id >= vocab) {
      throw ArgumentError.value(id, 'targets[$i]', '越界（vocab=$vocab）');
    }
    if (id == blankId) {
      throw ArgumentError.value(id, 'targets[$i]', 'targets 不能含 blank');
    }
  }
}

/// CTC 路径能容纳 targets 的最少帧数：每个 label 至少一帧，相邻重复之间还要一帧 blank。
int _minFramesFor(List<int> targets) {
  int frames = targets.length;
  for (int i = 1; i < targets.length; i++) {
    if (targets[i] == targets[i - 1]) {
      frames++;
    }
  }
  return frames;
}

/// `log(Σ exp(x))`，先减最大值避免溢出；`double` 累加。
double _logSumExp(Float32List data, int offset, int length) {
  double max = double.negativeInfinity;
  for (int v = 0; v < length; v++) {
    final double value = data[offset + v];
    if (value > max) {
      max = value;
    }
  }
  if (max == double.negativeInfinity) {
    return max;
  }
  double sum = 0;
  for (int v = 0; v < length; v++) {
    sum += math.exp(data[offset + v] - max);
  }
  return max + math.log(sum);
}
