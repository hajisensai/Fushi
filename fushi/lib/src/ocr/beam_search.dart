/// Beam search 解码（纯函数，不依赖 ONNX runtime）。
///
/// 语义对齐 HuggingFace `transformers` 的 `generate`（BeamSearchScorer +
/// NoRepeatNGramLogitsProcessor，early_stopping=False），manga-ocr 原版
/// generation_config：num_beams=4, length_penalty=2.0, no_repeat_ngram_size=3,
/// max_length=300。已实测该配置与原版输出逐字一致（贪心解码只有 ~97.8%）。
///
/// 与 HF 对齐的关键细节：
/// - 序列长度计数**包含** decoder 起始 token（[CLS]），max_length 同口径；
/// - 每步取 top `2 * numBeams` 候选；候选 rank >= numBeams 的 EOS 直接丢弃；
/// - EOS 候选完成时：分数 = 累计 logprob（含 EOS 那一步的 logprob）除以
///   `len ** lengthPenalty`，其中 `len` 是**不含 EOS** 的序列长度；
/// - early_stopping=False 的终止判据：已有 numBeams 条完成假设，且其中最差
///   分数 >= 当前存活 beam 可能达到的最好分数
///   （maxAliveScore / curLen ** lengthPenalty）；
/// - 到达 max_length 时把存活 beam 按同样的长度惩罚公式收编进完成集。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 每步 logits 回调。
///
/// 输入：当前每条存活 beam 的完整 token 序列（含 decoder 起始 token）。
/// 输出：每条 beam 对应的最后一个位置的词表 logits（长度 = vocabSize，
/// 未做 softmax）。实现方通常把 beams 打成一个 batch 跑 decoder。
typedef BeamStepLogits = Future<List<Float32List>> Function(
    List<List<int>> sequences);

class BeamSearchConfig {
  const BeamSearchConfig({
    required this.startTokenId,
    required this.eosTokenId,
    this.numBeams = 4,
    this.lengthPenalty = 2.0,
    this.noRepeatNgramSize = 3,
    this.maxLength = 300,
  })  : assert(numBeams >= 1),
        assert(maxLength >= 2);

  /// decoder 起始 token（manga-ocr 为 [CLS]）。
  final int startTokenId;

  /// 结束 token（manga-ocr 为 [SEP]）。
  final int eosTokenId;

  final int numBeams;
  final double lengthPenalty;

  /// 0 表示不启用 no-repeat-ngram。
  final int noRepeatNgramSize;

  /// 序列最大长度（含起始 token，对齐 HF max_length 口径）。
  final int maxLength;
}

class BeamSearchResult {
  const BeamSearchResult({required this.tokens, required this.score});

  /// 解码出的 token id 序列，不含起始 token 与 EOS。
  final List<int> tokens;

  /// 长度惩罚后的假设分数。
  final double score;
}

class _Hypothesis {
  _Hypothesis(this.tokens, this.score);

  /// 含起始 token、不含 EOS。
  final List<int> tokens;
  final double score;
}

/// 对 [logits] 求 log-softmax。
Float64List logSoftmax(Float32List logits) {
  double maxLogit = double.negativeInfinity;
  for (int i = 0; i < logits.length; i++) {
    if (logits[i] > maxLogit) {
      maxLogit = logits[i];
    }
  }
  double sumExp = 0;
  for (int i = 0; i < logits.length; i++) {
    sumExp += math.exp(logits[i] - maxLogit);
  }
  final double logSumExp = maxLogit + math.log(sumExp);
  final Float64List result = Float64List(logits.length);
  for (int i = 0; i < logits.length; i++) {
    result[i] = logits[i] - logSumExp;
  }
  return result;
}

/// no-repeat-ngram：若在 [sequence] 末尾再生成某 token 会复现序列中已出现过的
/// n-gram，则该 token 被禁止。对齐 HF `NoRepeatNGramLogitsProcessor`。
Set<int> bannedNgramTokens(List<int> sequence, int ngramSize) {
  if (ngramSize <= 0 || sequence.length + 1 < ngramSize) {
    return const <int>{};
  }
  final int prefixLen = ngramSize - 1;
  final List<int> currentPrefix = sequence.sublist(sequence.length - prefixLen);
  final Set<int> banned = <int>{};
  for (int i = 0; i + ngramSize <= sequence.length; i++) {
    bool match = true;
    for (int j = 0; j < prefixLen; j++) {
      if (sequence[i + j] != currentPrefix[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      banned.add(sequence[i + prefixLen]);
    }
  }
  return banned;
}

/// 运行 beam search，返回最优假设。
Future<BeamSearchResult> beamSearchDecode({
  required BeamSearchConfig config,
  required BeamStepLogits stepLogits,
}) async {
  final int numBeams = config.numBeams;

  List<List<int>> sequences = <List<int>>[
    for (int i = 0; i < numBeams; i++) <int>[config.startTokenId],
  ];
  // 首步除 beam0 外全部 -inf，避免 numBeams 条相同序列占满候选（对齐 HF）。
  final List<double> beamScores =
      List<double>.filled(numBeams, double.negativeInfinity);
  beamScores[0] = 0;

  final List<_Hypothesis> finished = <_Hypothesis>[];

  void addHypothesis(List<int> tokens, double sumLogProbs) {
    final double score =
        sumLogProbs / math.pow(tokens.length, config.lengthPenalty);
    if (finished.length < numBeams) {
      finished.add(_Hypothesis(tokens, score));
      return;
    }
    int worstIndex = 0;
    for (int i = 1; i < finished.length; i++) {
      if (finished[i].score < finished[worstIndex].score) {
        worstIndex = i;
      }
    }
    if (score > finished[worstIndex].score) {
      finished[worstIndex] = _Hypothesis(tokens, score);
    }
  }

  double worstFinishedScore() {
    double worst = double.infinity;
    for (final _Hypothesis h in finished) {
      worst = math.min(worst, h.score);
    }
    return worst;
  }

  bool searchDone = false;
  int curLen = 1;

  while (curLen < config.maxLength && !searchDone) {
    final List<Float32List> logitsPerBeam = await stepLogits(sequences);
    assert(logitsPerBeam.length == numBeams);
    final int vocabSize = logitsPerBeam[0].length;

    // 每条 beam：log-softmax + no-repeat-ngram 屏蔽 + 累计分。
    final List<Float64List> nextScores = <Float64List>[];
    for (int b = 0; b < numBeams; b++) {
      final Float64List logProbs = logSoftmax(logitsPerBeam[b]);
      final Set<int> banned =
          bannedNgramTokens(sequences[b], config.noRepeatNgramSize);
      for (final int token in banned) {
        logProbs[token] = double.negativeInfinity;
      }
      for (int v = 0; v < vocabSize; v++) {
        logProbs[v] += beamScores[b];
      }
      nextScores.add(logProbs);
    }

    // 全局取 top 2*numBeams 候选（beam, token, score）。
    final int candidateCount = math.min(2 * numBeams, numBeams * vocabSize);
    final List<int> topBeam = List<int>.filled(candidateCount, 0);
    final List<int> topToken = List<int>.filled(candidateCount, 0);
    final List<double> topScore =
        List<double>.filled(candidateCount, double.negativeInfinity);
    for (int b = 0; b < numBeams; b++) {
      final Float64List scores = nextScores[b];
      for (int v = 0; v < vocabSize; v++) {
        final double s = scores[v];
        if (s <= topScore[candidateCount - 1]) {
          continue;
        }
        // 插入排序进 top 列表（candidateCount 很小）。
        int pos = candidateCount - 1;
        while (pos > 0 && topScore[pos - 1] < s) {
          topScore[pos] = topScore[pos - 1];
          topBeam[pos] = topBeam[pos - 1];
          topToken[pos] = topToken[pos - 1];
          pos--;
        }
        topScore[pos] = s;
        topBeam[pos] = b;
        topToken[pos] = v;
      }
    }

    // 分配下一轮 beam；EOS 候选（rank < numBeams）收编为完成假设。
    final List<List<int>> nextSequences = <List<int>>[];
    final List<double> nextBeamScores = <double>[];
    for (int rank = 0; rank < candidateCount; rank++) {
      if (topScore[rank] == double.negativeInfinity) {
        break;
      }
      final int beam = topBeam[rank];
      final int token = topToken[rank];
      if (token == config.eosTokenId) {
        if (rank < numBeams) {
          // 分数含 EOS 步的 logprob；长度不含 EOS（对齐 HF）。
          addHypothesis(List<int>.from(sequences[beam]), topScore[rank]);
        }
        continue;
      }
      nextSequences.add(<int>[...sequences[beam], token]);
      nextBeamScores.add(topScore[rank]);
      if (nextSequences.length == numBeams) {
        break;
      }
    }
    if (nextSequences.isEmpty) {
      // 所有可行延续都是 EOS（或全 -inf）：解码结束。
      searchDone = true;
      break;
    }
    while (nextSequences.length < numBeams) {
      // 极端退化（词表过小 + ngram 屏蔽）：复制最后一条占位。
      nextSequences.add(List<int>.from(nextSequences.last));
      nextBeamScores.add(double.negativeInfinity);
    }

    sequences = nextSequences;
    for (int b = 0; b < numBeams; b++) {
      beamScores[b] = nextBeamScores[b];
    }
    curLen++;

    // early_stopping=False 的 is_done 判据。
    if (finished.length >= numBeams) {
      double bestAlive = double.negativeInfinity;
      for (int b = 0; b < numBeams; b++) {
        bestAlive = math.max(bestAlive, beamScores[b]);
      }
      final double highestAttainable =
          bestAlive / math.pow(curLen, config.lengthPenalty);
      if (worstFinishedScore() >= highestAttainable) {
        searchDone = true;
      }
    }
  }

  // 到达 max_length / 提前终止后，把存活 beam 收编（对齐 HF finalize）。
  if (!searchDone || finished.length < numBeams) {
    for (int b = 0; b < numBeams; b++) {
      if (beamScores[b] == double.negativeInfinity) {
        continue;
      }
      addHypothesis(List<int>.from(sequences[b]), beamScores[b]);
    }
  }

  _Hypothesis? best;
  for (final _Hypothesis h in finished) {
    if (best == null || h.score > best.score) {
      best = h;
    }
  }
  best ??= _Hypothesis(<int>[config.startTokenId], 0);

  // 去掉起始 token。
  return BeamSearchResult(
    tokens: best.tokens.sublist(1),
    score: best.score,
  );
}
