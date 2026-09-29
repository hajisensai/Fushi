import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/beam_search.dart';

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

    test('并列候选保持 beam 顺序与 token 顺序', () async {
      final List<List<List<int>>> observed = <List<List<int>>>[];
      final BeamSearchResult result = await beamSearchDecode(
        config: const BeamSearchConfig(
          startTokenId: kStart,
          eosTokenId: kEos,
          numBeams: 2,
          noRepeatNgramSize: 0,
          maxLength: 3,
        ),
        stepLogits: (List<List<int>> sequences) async {
          observed.add(sequences);
          return <Float32List>[
            for (final List<int> sequence in sequences)
              Float32List.fromList(<double>[
                for (int token = 0; token < kVocab; token++)
                  token >= (sequence.length == 1 ? 2 : 4)
                      ? 0
                      : double.negativeInfinity,
              ]),
          ];
        },
      );
      expect(observed[1], <List<int>>[
        <int>[kStart, 2],
        <int>[kStart, 3],
      ]);
      expect(result.tokens, <int>[2, 4]);
      expect(result.score, closeTo(-math.log(8) / 9, 1e-12));
    });

    test('不同 beam 各自归一化，不让 logits 绝对值影响选路', () async {
      final BeamSearchResult result = await beamSearchDecode(
        config: const BeamSearchConfig(
          startTokenId: kStart,
          eosTokenId: kEos,
          numBeams: 2,
          noRepeatNgramSize: 0,
          maxLength: 3,
        ),
        stepLogits: scriptedLogits((List<int> sequence, int token) {
          if (sequence.length == 1) {
            if (token == 2) return math.log(0.6);
            if (token == 3) return math.log(0.4);
          } else if (sequence.last == 2 && (token == 4 || token == 5)) {
            return 100;
          } else if (sequence.last == 3 && token == 4) {
            return 0;
          }
          return null;
        }, defaultLogit: double.negativeInfinity),
      );
      // 2→4 / 2→5 各 0.3；3→4 为 0.4，尽管前者原始 logit 高出 100。
      expect(result.tokens, <int>[3, 4]);
      expect(result.score, closeTo(math.log(0.4) / 9, 1e-8));
    });

    test('禁止 token 仍参与 softmax，且不修改调用方的 logits', () async {
      final Float32List start = Float32List.fromList(<double>[
        double.negativeInfinity,
        double.negativeInfinity,
        math.log(0.6),
        math.log(0.4),
        double.negativeInfinity,
        double.negativeInfinity,
      ]);
      final Float32List repeat = Float32List.fromList(<double>[
        double.negativeInfinity,
        double.negativeInfinity,
        20,
        double.negativeInfinity,
        0,
        double.negativeInfinity,
      ]);
      final Float32List continuation = Float32List.fromList(<double>[
        double.negativeInfinity,
        double.negativeInfinity,
        double.negativeInfinity,
        double.negativeInfinity,
        0,
        double.negativeInfinity,
      ]);
      final List<List<double>> original = <List<double>>[
        start.toList(),
        repeat.toList(),
        continuation.toList(),
      ];
      final BeamSearchResult result = await beamSearchDecode(
        config: const BeamSearchConfig(
          startTokenId: kStart,
          eosTokenId: kEos,
          numBeams: 2,
          noRepeatNgramSize: 1,
          maxLength: 3,
        ),
        stepLogits: (List<List<int>> sequences) async => <Float32List>[
          for (final List<int> sequence in sequences)
            sequence.length == 1
                ? start
                : sequence.last == 2
                    ? repeat
                    : continuation,
        ],
      );
      // 路径 2 的概率质量集中在被禁的 2 上；不能先屏蔽再归一化，使其
      // 唯一可行后继 4 变成概率 1，否则首步较低的正确路径 3 会被误淘汰。
      expect(result.tokens, <int>[3, 4]);
      expect(<Float32List>[start, repeat, continuation], original);
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

      // 钉的是 ngram 规则本身，用穷尽语义（earlyStopping=false）看完整偏好链；
      // 默认的 early_stopping=true 会在 5→EOS 的旁路凑满 4 条完成假设时提前停
      // （得到同样不含重复 3-gram 的 [2,3,4,5]），那属于 BUG-2457 的用例。
      final BeamSearchResult banned = await beamSearchDecode(
        config: const BeamSearchConfig(
          startTokenId: kStart,
          eosTokenId: kEos,
          numBeams: 4,
          lengthPenalty: 1.0,
          noRepeatNgramSize: 3,
          maxLength: 20,
          earlyStopping: false,
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
          earlyStopping: false,
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

    test('BUG-2457 early_stopping：凑齐 numBeams 条完成假设即停，false 会追到 maxLength',
        () async {
      // 每步 EOS 都是最优、token 2 紧随其后：第 1 步 beam0 的 EOS 完成 1 条，
      // 第 2 步 [0,2] 的 EOS 再完成 1 条 → 完成集凑满 numBeams=2。此后存活 beam
      // 的累计 logprob 仍很高（p(2)≈0.47/步），false 语义下「最差完成分 >= 存活
      // 上限」迟迟不成立，只能一路追到 maxLength；true 语义第 2 步就该停。
      double? rule(List<int> seq, int token) => switch (token) {
            kEos => 5.0,
            2 => 4.9,
            _ => null,
          };
      Future<int> stepsWith({required bool earlyStopping}) async {
        int steps = 0;
        final BeamStepLogits scripted = scriptedLogits(rule);
        await beamSearchDecode(
          config: BeamSearchConfig(
            startTokenId: kStart,
            eosTokenId: kEos,
            numBeams: 2,
            lengthPenalty: 1.0,
            noRepeatNgramSize: 0,
            maxLength: 10,
            earlyStopping: earlyStopping,
          ),
          stepLogits: (List<List<int>> sequences) {
            steps++;
            return scripted(sequences);
          },
        );
        return steps;
      }

      expect(await stepsWith(earlyStopping: true), 2,
          reason: '完成集凑满 numBeams 后必须立刻停');
      expect(await stepsWith(earlyStopping: false), 9,
          reason: '对照：旧语义要跑到 maxLength（curLen 1→10 共 9 步）');
      // 默认值必须是 true：原版 generation_config 如此，false 只留给对拍。
      expect(
          const BeamSearchConfig(startTokenId: kStart, eosTokenId: kEos)
              .earlyStopping,
          isTrue);
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
