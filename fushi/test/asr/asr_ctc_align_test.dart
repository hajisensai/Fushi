import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_ctc_align.dart';
import 'package:fushi/src/asr/asr_types.dart';

/// Omnilingual 形态的词表：`<s>`=blank(0)、`<pad>`、`</s>`、`<unk>`、空格 token、字符。
const String _kTokens = '<s> 0\n<pad> 1\n</s> 2\n<unk> 3\n  4\na 5\nb 6\nc 7\n';
const int _kVocab = 8;
const int _kBlank = 0;
const int _kSpace = 4;
const int _kA = 5;
const int _kB = 6;
const int _kC = 7;

/// 合成 `[frames × vocab]` 原始 logit：帧 t 的目标 id 为 [plan]`[t]`，
/// 目标给 [high]、其余给 [low]。
Float32List _synthLogits(List<int> plan, {double high = 3, double low = -3}) {
  final Float32List logits = Float32List(plan.length * _kVocab);
  for (int t = 0; t < plan.length; t++) {
    for (int v = 0; v < _kVocab; v++) {
      logits[t * _kVocab + v] = v == plan[t] ? high : low;
    }
  }
  return logits;
}

/// 把 `[(id, 帧数), ...]` 展开成逐帧计划。
List<int> _plan(List<(int, int)> runs) {
  final List<int> out = <int>[];
  for (final (int id, int count) in runs) {
    out.addAll(List<int>.filled(count, id));
  }
  return out;
}

/// `blank×2, a×3, blank, b×2, blank×3, c×4, blank`（16 帧）。
final List<int> _kAbcPlan = _plan(<(int, int)>[
  (_kBlank, 2),
  (_kA, 3),
  (_kBlank, 1),
  (_kB, 2),
  (_kBlank, 3),
  (_kC, 4),
  (_kBlank, 1),
]);

AsrCtcAlignment? _align(
  List<int> plan,
  List<int> targets, {
  double high = 3,
  double low = -3,
  int maxCells = 50000000,
}) {
  return ctcForcedAlign(
    logits: _synthLogits(plan, high: high, low: low),
    frames: plan.length,
    vocab: _kVocab,
    targets: targets,
    blankId: _kBlank,
    maxCells: maxCells,
  );
}

List<(int, int, int)> _spans(AsrCtcAlignment a) => a.tokens
    .map((AsrCtcAlignedToken t) => (t.id, t.startFrame, t.endFrame))
    .toList();

void main() {
  final AsrTokenTable tokens = AsrTokenTable.parse(_kTokens, blankToken: '<s>');

  group('AsrCtcTextEncoder', () {
    test('字符级词表：逐 rune 查表，空格也是 token', () {
      final AsrCtcTextEncoder enc = AsrCtcTextEncoder(tokens);
      expect(enc.isSupported, isTrue);
      final AsrCtcEncodedText out = enc.encode('ab c');
      expect(out.ids, <int>[_kA, _kB, _kSpace, _kC]);
      expect(out.charOffsets, <int>[0, 1, 2, 3]);
      expect(out.length, 4);
      expect(out.isEmpty, isFalse);
    });

    test('未知字符跳过而不是填 <unk>；偏移仍指向原文', () {
      final AsrCtcEncodedText out = AsrCtcTextEncoder(tokens).encode('axb');
      expect(out.ids, <int>[_kA, _kB]);
      expect(out.charOffsets, <int>[0, 2]);
      expect(out.ids, isNot(contains(tokens.unkId)));
    });

    test('增补平面字符占两个 UTF-16 码元', () {
      final AsrCtcEncodedText out = AsrCtcTextEncoder(tokens).encode('𝄞a');
      expect(out.ids, <int>[_kA]);
      expect(out.charOffsets, <int>[2]);
    });

    test('空文本 → 空编码', () {
      final AsrCtcEncodedText out = AsrCtcTextEncoder(tokens).encode('');
      expect(out.isEmpty, isTrue);
      expect(out.length, 0);
    });

    test('SentencePiece 词表不支持', () {
      final AsrTokenTable sp = AsrTokenTable.parse(
        '<blk> 0\n<unk> 1\n▁a 2\nb 3\n',
      );
      expect(sp.isSentencePiece, isTrue);
      final AsrCtcTextEncoder enc = AsrCtcTextEncoder(sp);
      expect(enc.isSupported, isFalse);
      expect(enc.encode('ab').isEmpty, isTrue);
    });
  });

  group('ctcForcedAlign', () {
    test('合成 logits：abc 边界精确，blank 帧不属于任何 token', () {
      final AsrCtcAlignment? a = _align(_kAbcPlan, <int>[_kA, _kB, _kC]);
      expect(a, isNotNull);
      expect(_spans(a!), <(int, int, int)>[
        (_kA, 2, 5),
        (_kB, 6, 8),
        (_kC, 11, 15),
      ]);
      for (final AsrCtcAlignedToken t in a.tokens) {
        expect(t.meanLogProb, lessThanOrEqualTo(0));
        expect(t.frameCount, t.endFrame - t.startFrame);
      }
      expect(a.totalLogProb, lessThanOrEqualTo(0));
      expect(a.totalLogProb.isFinite, isTrue);
    });

    test('重复 label aa：中间 blank 必经，两个 a 各占一段', () {
      final List<int> plan = _plan(<(int, int)>[
        (_kA, 3),
        (_kBlank, 1),
        (_kA, 2),
      ]);
      final AsrCtcAlignment? a = _align(plan, <int>[_kA, _kA]);
      expect(a, isNotNull);
      expect(_spans(a!), <(int, int, int)>[(_kA, 0, 3), (_kA, 4, 6)]);
    });

    test('帧数不足 → null；maxCells 预算超限 → null', () {
      // aa 需要 3 帧（a, blank, a），只给 2 帧。
      expect(_align(<int>[_kA, _kA], <int>[_kA, _kA]), isNull);
      // abc 在 16 帧上是 16 × 7 = 112 格，预算 100 不够。
      expect(_align(_kAbcPlan, <int>[_kA, _kB, _kC], maxCells: 100), isNull);
      // 刚好够就不 null。
      expect(_align(_kAbcPlan, <int>[_kA, _kB, _kC], maxCells: 112), isNotNull);
    });

    test('空 targets → 零 token，totalLogProb 为全 blank 路径分数且有限', () {
      final AsrCtcAlignment? a = _align(_kAbcPlan, const <int>[]);
      expect(a, isNotNull);
      expect(a!.tokens, isEmpty);
      expect(a.totalLogProb.isFinite, isTrue);
      expect(a.totalLogProb, lessThan(0));
      // 零帧 + 空 targets：空路径，log 1 = 0。
      final AsrCtcAlignment? empty = ctcForcedAlign(
        logits: Float32List(0),
        frames: 0,
        vocab: _kVocab,
        targets: const <int>[],
        blankId: _kBlank,
      );
      expect(empty, isNotNull);
      expect(empty!.tokens, isEmpty);
      expect(empty.totalLogProb, 0);
      // 零帧但有 targets：装不下。
      expect(
        ctcForcedAlign(
          logits: Float32List(0),
          frames: 0,
          vocab: _kVocab,
          targets: <int>[_kA],
          blankId: _kBlank,
        ),
        isNull,
      );
    });

    test('抗噪：目标 logit 只比其他高 1.0 也能恢复同样边界', () {
      final AsrCtcAlignment? a = _align(
        _kAbcPlan,
        <int>[_kA, _kB, _kC],
        high: 1,
        low: 0,
      );
      expect(a, isNotNull);
      expect(_spans(a!), <(int, int, int)>[
        (_kA, 2, 5),
        (_kB, 6, 8),
        (_kC, 11, 15),
      ]);
      // log-softmax：每帧目标概率 e/(e+7)，token 均值与整段总分都应等于它的 log。
      final double expected = math.log(math.e / (math.e + 7));
      for (final AsrCtcAlignedToken t in a.tokens) {
        expect(t.meanLogProb, closeTo(expected, 1e-6));
        expect(t.meanLogProb, lessThanOrEqualTo(0));
      }
      expect(a.totalLogProb, closeTo(expected * _kAbcPlan.length, 1e-6));
      expect(a.totalLogProb, lessThanOrEqualTo(0));
    });

    test('文本比声学多出的字符会被挤成单帧，而不是丢掉', () {
      // 声学只有 a、c，文本是 abc：b 必须占至少一帧且三段按序不重叠。
      final List<int> plan = _plan(<(int, int)>[
        (_kA, 3),
        (_kBlank, 2),
        (_kC, 3),
      ]);
      final AsrCtcAlignment? a = _align(plan, <int>[_kA, _kB, _kC]);
      expect(a, isNotNull);
      expect(a!.tokens, hasLength(3));
      expect(a.tokens[1].id, _kB);
      expect(a.tokens[1].frameCount, 1);
      expect(a.tokens[0].startFrame, 0);
      expect(a.tokens[2].endFrame, plan.length);
      expect(a.tokens[0].endFrame, lessThanOrEqualTo(a.tokens[1].startFrame));
      expect(a.tokens[1].endFrame, lessThanOrEqualTo(a.tokens[2].startFrame));
    });

    test('越界：targets 含 ≥ vocab 的 id / blank、logits 长度不符、blankId 越界都抛', () {
      final Float32List logits = _synthLogits(_kAbcPlan);
      expect(
        () => ctcForcedAlign(
          logits: logits,
          frames: _kAbcPlan.length,
          vocab: _kVocab,
          targets: <int>[_kA, _kB, _kVocab],
          blankId: _kBlank,
        ),
        throwsArgumentError,
      );
      expect(
        () => ctcForcedAlign(
          logits: logits,
          frames: _kAbcPlan.length,
          vocab: _kVocab,
          targets: <int>[_kA, _kBlank],
          blankId: _kBlank,
        ),
        throwsArgumentError,
      );
      expect(
        () => ctcForcedAlign(
          logits: logits,
          frames: _kAbcPlan.length + 1,
          vocab: _kVocab,
          targets: <int>[_kA],
          blankId: _kBlank,
        ),
        throwsArgumentError,
      );
      expect(
        () => ctcForcedAlign(
          logits: logits,
          frames: _kAbcPlan.length,
          vocab: _kVocab,
          targets: <int>[_kA],
          blankId: _kVocab,
        ),
        throwsArgumentError,
      );
    });

    test('编码器 + 对齐端到端：ab c 的四个字符各得一段且映射回原文偏移', () {
      final List<int> plan = _plan(<(int, int)>[
        (_kBlank, 1),
        (_kA, 2),
        (_kB, 2),
        (_kSpace, 1),
        (_kBlank, 1),
        (_kC, 2),
      ]);
      final AsrCtcEncodedText text = AsrCtcTextEncoder(tokens).encode('ab c');
      final AsrCtcAlignment? a = _align(plan, text.ids);
      expect(a, isNotNull);
      expect(_spans(a!), <(int, int, int)>[
        (_kA, 1, 3),
        (_kB, 3, 5),
        (_kSpace, 5, 6),
        (_kC, 7, 9),
      ]);
      expect(text.charOffsets, <int>[0, 1, 2, 3]);
    });
  });
}
