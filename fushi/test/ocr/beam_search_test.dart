import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ocr/beam_search.dart';

/// 词表约定：0 = start（[CLS]）、1 = EOS（[SEP]）、2..5 = 普通 token。
const int kStart = 0;
const int kEos = 1;
const int kVocab = 6;

/// 用「序列 -> 每 token logit」的映射构造 stepLogits 回调。
/// [rule] 返回 null 时使用 [defaultLogit] 填充。
BeamStepLogits scriptedLogits(
  double? Function(List<int> sequence, int token) rule, {
  double defaultLogit = -20,
}) {
  return (List<List<int>> sequences) async {
    return <Float32List>[
      for (final List<int> seq in sequences)
        Float32List.fromList(<double>[
          for (int v = 0; v < kVocab; v++) rule(seq, v) ?? defaultLogit,
        ]),
    ];
  };
}

void main() {
  group('logSoftmax', () {
    test('输出为合法 log 概率（exp 和为 1，保序）', () {
      final Float64List logProbs =
          logSoftmax(Float32List.fromList(<double>[1, 2, 3]));
      double sum = 0;
      for (final double p in logProbs) {
        sum += math.exp(p);
      }
      expect(sum, closeTo(1.0, 1e-9));
      expect(logProbs[2], greaterThan(logProbs[1]));
      expect(logProbs[1], greaterThan(logProbs[0]));
    });
  });

  group('bannedNgramTokens', () {
    test('长度不足 ngram 时不禁止', () {
      expect(bannedNgramTokens(<int>[0, 2], 3), isEmpty);
    });

    test('末尾前缀命中历史 3-gram 时禁止其后继', () {
      // 3-grams: (0,2,3) (2,3,4) (3,4,2) (4,2,3)；末尾前缀 (2,3) -> 禁 4。
      expect(bannedNgramTokens(<int>[0, 2, 3, 4, 2, 3], 3), <int>{4});
    });

    test('多个后继都被禁止', () {
      // 前缀 (2,) 的 2-gram 后继：3 和 4。
      expect(bannedNgramTokens(<int>[0, 2, 3, 2, 4, 2], 2), <int>{3, 4});
    });

    test('ngramSize=0 不启用', () {
      expect(bannedNgramTokens(<int>[2, 2, 2, 2], 0), isEmpty);
    });
  });

  group('beamSearchDecode', () {
    test('无歧义路径等价贪心', () async {
      // start -> 2 -> 3 -> EOS。
      final BeamSearchResult result = await beamSearchDecode(
        config: const BeamSearchConfig(
          startTokenId: kStart,
          eosTokenId: kEos,
          numBeams: 4,
          lengthPenalty: 1.0,
          noRepeatNgramSize: 0,
          maxLength: 10,
        ),
        stepLogits: scriptedLogits((List<int> seq, int token) {
          final int last = seq.last;
          if (last == kStart && token == 2) return 10;
          if (last == 2 && token == 3) return 10;
          if (last == 3 && token == kEos) return 10;
          return null;
        }),
      );
      expect(result.tokens, <int>[2, 3]);
    });

    test('beam 选路：首步次优 token 的后续更好时胜出（贪心会选错）', () async {
      // 首步：2 的 logit 略高于 3（贪心选 2）；
      // [.,2] 的后续三路均分（每步 ~-1.1 logprob）；
      // [.,3] 的后续一枝独秀（每步 ~0 logprob）→ 总分 3 路径更高。
      final BeamSearchResult result = await beamSearchDecode(
        config: const BeamSearchConfig(
          startTokenId: kStart,
          eosTokenId: kEos,
          numBeams: 4,
          lengthPenalty: 1.0,
          noRepeatNgramSize: 0,
          maxLength: 10,
        ),
        stepLogits: scriptedLogits((List<int> seq, int token) {
          final int last = seq.last;
          if (last == kStart) {
            if (token == 2) return 2.0;
            if (token == 3) return 1.8;
            return null;
          }
          if (last == 2) {
            // 三个候选并列 → 每个 logprob ≈ ln(1/3)。
            if (token == 4 || token == 5 || token == kEos) return 0;
            return null;
          }
          if (last == 3) {
            if (token == 4) return 10;
            return null;
          }
          if (last == 4 && seq.contains(3)) {
            if (token == kEos) return 10;
            return null;
          }
          if (last == 4 || last == 5) {
            if (token == kEos) return 0;
            if (token == 4) return 0;
            return null;
          }
          return null;
        }),
      );
      expect(result.tokens, <int>[3, 4]);
    });

    test('length_penalty=2.0 偏好长序列、0.0 偏好高原始分', () async {
      // 首步 EOS 略优于 token 2；走 2 之后 EOS 概率 ~1。
      // lp=2：长路径 sum/-len^2 摊薄 → 长路径赢；lp=0：短路径赢。
      BeamStepLogits logits() => scriptedLogits((List<int> seq, int token) {
            final int last = seq.last;
            if (last == kStart) {
              if (token == kEos) return 1.0;
              if (token == 2) return 0.9;
              return null;
            }
            if (last == 2 && token == kEos) return 10;
            return null;
          });

      final BeamSearchResult long = await beamSearchDecode(
        config: const BeamSearchConfig(
          startTokenId: kStart,
          eosTokenId: kEos,
          numBeams: 4,
          lengthPenalty: 2.0,
          noRepeatNgramSize: 0,
          maxLength: 10,
        ),
        stepLogits: logits(),
      );
      expect(long.tokens, <int>[2]);

      final BeamSearchResult short = await beamSearchDecode(
        config: const BeamSearchConfig(
          startTokenId: kStart,
          eosTokenId: kEos,
          numBeams: 4,
          lengthPenalty: 0.0,
          noRepeatNgramSize: 0,
          maxLength: 10,
        ),
        stepLogits: logits(),
      );
      expect(short.tokens, isEmpty);
    });

    test('no_repeat_ngram_size=3 阻止重复 3-gram，改走次优 token', () async {
      // 偏好链：start->2->3->4->2->3->(4 被禁)->5->EOS。
      double? rule(List<int> seq, int token) {
        final int last = seq.last;
        if (last == kStart) return token == 2 ? 10 : null;
        if (last == 2) return token == 3 ? 10 : (token == 5 ? 0 : null);
        if (last == 3) return token == 4 ? 10 : (token == 5 ? 0 : null);
        if (last == 4) return token == 2 ? 10 : (token == 5 ? 0 : null);
        if (last == 5) return token == kEos ? 10 : null;
        return null;
      }

      final BeamSearchResult banned = await beamSearchDecode(
        config: const BeamSearchConfig(
          startTokenId: kStart,
          eosTokenId: kEos,
          numBeams: 4,
          lengthPenalty: 1.0,
          noRepeatNgramSize: 3,
          maxLength: 20,
        ),
        stepLogits: scriptedLogits(rule),
      );
      expect(banned.tokens, <int>[2, 3, 4, 2, 3, 5]);

      // 对照组：不启用 ngram 屏蔽时会一直循环 2,3,4 直到 maxLength。
      final BeamSearchResult looped = await beamSearchDecode(
        config: const BeamSearchConfig(
          startTokenId: kStart,
          eosTokenId: kEos,
          numBeams: 4,
          lengthPenalty: 1.0,
          noRepeatNgramSize: 0,
          maxLength: 10,
        ),
        stepLogits: scriptedLogits(rule),
      );
      expect(looped.tokens, <int>[2, 3, 4, 2, 3, 4, 2, 3, 4]);
    });

    test('从不产生 EOS 时在 maxLength 截断', () async {
      final BeamSearchResult result = await beamSearchDecode(
        config: const BeamSearchConfig(
          startTokenId: kStart,
          eosTokenId: kEos,
          numBeams: 2,
          lengthPenalty: 2.0,
          noRepeatNgramSize: 0,
          maxLength: 5,
        ),
        stepLogits: scriptedLogits(
            (List<int> seq, int token) => token == 2 ? 10 : null),
      );
      // 序列长度（含 start）到 5 截断 → 4 个生成 token。
      expect(result.tokens, <int>[2, 2, 2, 2]);
    });

    test('每步回调收到 numBeams 条等长序列', () async {
      final List<int> observedCounts = <int>[];
      await beamSearchDecode(
        config: const BeamSearchConfig(
          startTokenId: kStart,
          eosTokenId: kEos,
          numBeams: 3,
          maxLength: 4,
          noRepeatNgramSize: 0,
        ),
        stepLogits: (List<List<int>> sequences) async {
          observedCounts.add(sequences.length);
          final Set<int> lengths =
              sequences.map((List<int> s) => s.length).toSet();
          expect(lengths, hasLength(1));
          return <Float32List>[
            for (int b = 0; b < sequences.length; b++)
              Float32List.fromList(
                  List<double>.generate(kVocab, (int v) => v == 2 ? 5 : 0)),
          ];
        },
      );
      expect(observedCounts, everyElement(3));
      expect(observedCounts, isNotEmpty);
    });
  });
}
