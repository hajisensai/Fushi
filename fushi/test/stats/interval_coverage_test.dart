import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/stats/interval_coverage.dart';

// BUG-2108 起视频只计首次覆盖；2026-09-06 抽成通用 [IntervalCoverage]（阅读三域的
// ReadUnitLedger 也用它）。
// 这里锁定它的代数性质：add 返回的是**新增**毫秒、重叠 / 相邻合并、任意顺序等价、
// JSON 往返无损、脏输入当空。

void main() {
  group('IntervalCoverage（原 WatchCoverage）', () {
    test('空并集：add 返回整段，total 等于区间长', () {
      final IntervalCoverage c = IntervalCoverage();
      expect(c.isEmpty, isTrue);
      expect(c.add(1000, 4000), 3000);
      expect(c.total, 3000);
      expect(c.ranges, <(int, int)>[(1000, 4000)]);
    });

    test('重叠区间只算新增部分：回放 / 重看返回 0', () {
      final IntervalCoverage c = IntervalCoverage()..add(0, 10000);
      expect(c.add(2000, 5000), 0, reason: '整段已覆盖 = 重听，不计');
      expect(c.add(8000, 12000), 2000, reason: '只有 10000..12000 是新的');
      expect(c.ranges, <(int, int)>[(0, 12000)]);
      expect(c.total, 12000);
    });

    test('相邻区间合并成一段；不相邻的保持有序分列', () {
      final IntervalCoverage c = IntervalCoverage()
        ..add(5000, 6000)
        ..add(1000, 2000);
      expect(c.ranges, <(int, int)>[(1000, 2000), (5000, 6000)]);
      expect(c.add(2000, 3000), 1000);
      expect(c.ranges, <(int, int)>[(1000, 3000), (5000, 6000)]);
      // 一段横跨两段的新区间：吸收两段，新增只算中间空洞。
      expect(c.add(2500, 5500), 2000);
      expect(c.ranges, <(int, int)>[(1000, 6000)]);
    });

    test('先跳到片尾看一眼再回头从中间看：中间那段仍按首看计（不是标量水位）', () {
      final IntervalCoverage c = IntervalCoverage()..add(80000, 90000);
      expect(c.add(30000, 40000), 10000);
      expect(c.covered(0, 90000), 20000);
      expect(c.covers(30000, 40000), isTrue);
      expect(c.covers(30000, 40001), isFalse);
    });

    test('空 / 倒序区间是 no-op', () {
      final IntervalCoverage c = IntervalCoverage();
      expect(c.add(5, 5), 0);
      expect(c.add(9, 3), 0);
      expect(c.isEmpty, isTrue);
      expect(c.covers(7, 7), isTrue, reason: '空区间视为已覆盖');
    });

    test('JSON 往返无损；脏输入当空', () {
      final IntervalCoverage c = IntervalCoverage()
        ..add(0, 1000)
        ..add(5000, 7000);
      final String json = c.toJson();
      expect(json, '[[0,1000],[5000,7000]]');
      expect(IntervalCoverage.fromJson(json).ranges, c.ranges);
      expect(IntervalCoverage.fromJson(null).isEmpty, isTrue);
      expect(IntervalCoverage.fromJson('').isEmpty, isTrue);
      expect(IntervalCoverage.fromJson('not json').isEmpty, isTrue);
      expect(IntervalCoverage.fromJson('{"a":1}').isEmpty, isTrue);
      expect(
        IntervalCoverage.fromJson('[[0,10],[1],"x",[5,"y"],[20,30]]').ranges,
        <(int, int)>[(0, 10), (20, 30)],
        reason: '坏元素逐个跳过，好的照收',
      );
    });

    test('copy 是深拷贝：改副本不影响原件', () {
      final IntervalCoverage a = IntervalCoverage()..add(0, 100);
      final IntervalCoverage b = a.copy()..add(100, 200);
      expect(a.total, 100);
      expect(b.total, 200);
    });

    test('addFresh 返回新增子区间：无重叠整段、两侧部分重叠、横跨吞并只剩空洞', () {
      final IntervalCoverage c = IntervalCoverage();
      expect(c.addFresh(100, 200), <(int, int)>[(100, 200)]);
      expect(c.addFresh(150, 300), <(int, int)>[
        (200, 300),
      ], reason: '左侧重叠只剩右半');
      expect(c.addFresh(50, 120), <(int, int)>[(50, 100)], reason: '右侧重叠只剩左半');
      c.addFresh(500, 600);
      expect(c.addFresh(250, 650), <(int, int)>[
        (300, 500),
        (600, 650),
      ], reason: '横跨两段：吸收两段，新增 = 中间空洞 + 右侧尾巴');
      expect(c.ranges, <(int, int)>[(50, 650)]);
      expect(c.addFresh(60, 640), isEmpty, reason: '整段已覆盖');
      expect(c.addFresh(9, 3), isEmpty, reason: '倒序 no-op');
      expect(c.ranges, <(int, int)>[(50, 650)]);
    });

    test('clipBelow：与 (-∞, position) 的交集，区间被截断、不改原件', () {
      final IntervalCoverage c = IntervalCoverage()
        ..add(0, 500)
        ..add(1000, 2000);
      expect(c.clipBelow(0).ranges, isEmpty);
      expect(c.clipBelow(300).ranges, <(int, int)>[(0, 300)]);
      expect(c.clipBelow(1000).ranges, <(int, int)>[(0, 500)]);
      expect(c.clipBelow(1500).ranges, <(int, int)>[(0, 500), (1000, 1500)]);
      expect(c.clipBelow(9999).ranges, <(int, int)>[(0, 500), (1000, 2000)]);
      expect(c.ranges, <(int, int)>[(0, 500), (1000, 2000)]);
    });

    test('subtract：本并集减去另一并集，返回升序不相交子区间', () {
      final IntervalCoverage a = IntervalCoverage()
        ..add(0, 1000)
        ..add(3000, 4000);
      final IntervalCoverage b = IntervalCoverage()
        ..add(200, 300)
        ..add(900, 3200)
        ..add(3900, 5000);
      expect(a.subtract(b), <(int, int)>[(0, 200), (300, 900), (3200, 3900)]);
      expect(b.subtract(a), <(int, int)>[(1000, 3000), (4000, 5000)]);
      expect(a.subtract(IntervalCoverage()), a.ranges);
      expect(IntervalCoverage().subtract(a), isEmpty);
      expect(a.subtract(a), isEmpty);
    });

    test('clear 清空并集', () {
      final IntervalCoverage c = IntervalCoverage()..add(0, 10);
      c.clear();
      expect(c.isEmpty, isTrue);
      expect(c.add(0, 10), 10);
    });
  });
}
