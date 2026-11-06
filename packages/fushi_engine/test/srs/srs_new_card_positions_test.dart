// 「按词频重排新卡」在 Fushi 复习下的位置分配（srsMinimalMovePositions）：只移动必须移动的卡。
//
// 根因回归（用户 2026-10-27「电脑上制卡，一自动重排就卡住、白屏、同步也卡」）：旧实现每次都把
// 整个牌组连续重编 1..N，往词频中间插一张新卡 = 它后面每张卡 +1 = 一条 `newPos` 修改记录，
// 2000 张新卡的牌组挖一个词实测 998 条修改记录进发件箱。
import 'dart:math';

import 'package:fushi_engine/srs/srs_new_card_positions.dart';
import 'package:test/test.dart';

/// 结果的基本契约：同长、严格递增、全部 ≥ 1。
void _expectValid(List<int?> current, List<int> out) {
  expect(out, hasLength(current.length));
  for (int i = 0; i < out.length; i++) {
    expect(out[i], greaterThanOrEqualTo(1), reason: 'position $i');
    if (i > 0) {
      expect(
        out[i],
        greaterThan(out[i - 1]),
        reason: 'strictly increasing at $i',
      );
    }
  }
}

int _writes(List<int?> current, List<int> out) {
  int n = 0;
  for (int i = 0; i < out.length; i++) {
    if (current[i] != out[i]) n++;
  }
  return n;
}

/// 穷举最优：最多能有几张卡不动（小规模对拍用）。
int _bruteForceMaxKept(List<int?> current) {
  final int n = current.length;
  int best = 0;
  for (int mask = 0; mask < (1 << n); mask++) {
    int lastIndex = -1;
    int lastPos = 0;
    bool ok = true;
    int kept = 0;
    for (int i = 0; i < n && ok; i++) {
      if (mask & (1 << i) == 0) continue;
      final int? p = current[i];
      // 锚点之间要放得下中间的卡（位置 ≥ 1 的整数）。
      if (p == null || p - lastPos < i - lastIndex) {
        ok = false;
        break;
      }
      lastIndex = i;
      lastPos = p;
      kept++;
    }
    if (ok && kept > best) best = kept;
  }
  return best;
}

void main() {
  test('从没排过：全部按间隙追加', () {
    final List<int?> current = <int?>[null, null, null];
    final List<int> out = srsMinimalMovePositions(current);
    expect(out, <int>[
      kSrsNewPositionGap,
      2 * kSrsNewPositionGap,
      3 * kSrsNewPositionGap,
    ]);
  });

  test('顺序没变：一张都不写', () {
    final List<int?> current = <int?>[3, 10, 11, 500];
    expect(srsMinimalMovePositions(current), current);
  });

  test('2000 张已排好的新卡中间插 1 张：只写这 1 张（旧实现 ~1000 张）', () {
    final List<int?> laid = srsMinimalMovePositions(
      List<int?>.filled(2000, null),
    );
    final List<int?> current = <int?>[
      ...laid.sublist(0, 1000),
      null,
      ...laid.sublist(1000),
    ];
    final List<int> out = srsMinimalMovePositions(current);
    _expectValid(current, out);
    expect(_writes(current, out), 1);
    expect(out[1000], greaterThan(out[999]));
    expect(out[1000], lessThan(out[1001]));
  });

  test('旧版连续编号 1..N 的牌组：头一次插入要挪一段，之后插入都是 O(1)', () {
    List<int?> deck = <int?>[for (int i = 1; i <= 2000; i++) i];
    final Random rng = Random(7);
    final List<int> writes = <int>[];
    for (int round = 0; round < 200; round++) {
      final int at = rng.nextInt(deck.length + 1);
      final List<int?> current = <int?>[
        ...deck.sublist(0, at),
        null,
        ...deck.sublist(at),
      ];
      final List<int> out = srsMinimalMovePositions(current);
      _expectValid(current, out);
      writes.add(_writes(current, out));
      deck = out;
    }
    // 连续编号没有间隙：头一两次插入要把挤在一起的卡铺开（含一次整组重铺）——一次性
    // 代价，合计不超过两个牌组的量。旧实现是每次 O(N)、200 次合计十几万条。
    final int total = writes.fold(0, (int a, int b) => a + b);
    expect(total, lessThan(2 * 2001 + 200), reason: '$writes');
    // 铺开之后：每次插入只写新卡自己（至多顺带一两个邻居）。
    expect(writes.skip(2).every((int w) => w <= 2), isTrue, reason: '$writes');
  });

  test('反复插在同一处（间隙用尽）：只挪附近一小段，不重写整组', () {
    List<int?> deck = srsMinimalMovePositions(List<int?>.filled(2000, null));
    int total = 0;
    for (int round = 0; round < 100; round++) {
      final List<int?> current = <int?>[
        ...deck.sublist(0, 500),
        null,
        ...deck.sublist(500),
      ];
      final List<int> out = srsMinimalMovePositions(current);
      _expectValid(current, out);
      total += _writes(current, out);
      deck = out;
    }
    // 旧实现：每次 ~1500 条（插入点之后全部 +1），100 次合计 15 万条。
    expect(total, lessThan(500), reason: 'total writes $total');
  });

  test('位置重复 / 次序错乱 / ≤ 0：结果仍严格递增且 ≥ 1', () {
    final List<int?> current = <int?>[5, 5, 2, null, 0, -3, 7, 7, 100];
    final List<int> out = srsMinimalMovePositions(current);
    _expectValid(current, out);
  });

  test('随机小规模对拍：要动的不过半时，不动的卡数 = 穷举最优', () {
    final Random rng = Random(42);
    for (int round = 0; round < 400; round++) {
      final int n = 1 + rng.nextInt(9);
      final List<int?> current = <int?>[
        for (int i = 0; i < n; i++)
          rng.nextInt(5) == 0 ? null : rng.nextInt(14) - 2,
      ];
      final List<int> out = srsMinimalMovePositions(current);
      _expectValid(current, out);
      final int kept = current.length - _writes(current, out);
      final int best = _bruteForceMaxKept(current);
      // 要动的不过半时就是最优；过半时整组重铺（kept 可能少于最优，但不会多）。
      if (2 * (current.length - best) <= current.length) {
        expect(kept, best, reason: '$current -> $out');
      } else {
        expect(kept, lessThanOrEqualTo(best), reason: '$current -> $out');
      }
    }
  });
}
