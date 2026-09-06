import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/watch_coverage.dart';

// BUG-2108：观看时长只计首次覆盖。[WatchCoverage] 是「已看过的片内区间并集」，
// 这里锁定它的代数性质：add 返回的是**新增**毫秒、重叠 / 相邻合并、任意顺序等价、
// JSON 往返无损、脏输入当空。

void main() {
  group('WatchCoverage', () {
    test('空并集：add 返回整段，totalMs 等于区间长', () {
      final WatchCoverage c = WatchCoverage();
      expect(c.isEmpty, isTrue);
      expect(c.add(1000, 4000), 3000);
      expect(c.totalMs, 3000);
      expect(c.ranges, <(int, int)>[(1000, 4000)]);
    });

    test('重叠区间只算新增部分：回放 / 重看返回 0', () {
      final WatchCoverage c = WatchCoverage()..add(0, 10000);
      expect(c.add(2000, 5000), 0, reason: '整段已覆盖 = 重听，不计');
      expect(c.add(8000, 12000), 2000, reason: '只有 10000..12000 是新的');
      expect(c.ranges, <(int, int)>[(0, 12000)]);
      expect(c.totalMs, 12000);
    });

    test('相邻区间合并成一段；不相邻的保持有序分列', () {
      final WatchCoverage c = WatchCoverage()
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
      final WatchCoverage c = WatchCoverage()..add(80000, 90000);
      expect(c.add(30000, 40000), 10000);
      expect(c.coveredMs(0, 90000), 20000);
      expect(c.covers(30000, 40000), isTrue);
      expect(c.covers(30000, 40001), isFalse);
    });

    test('空 / 倒序区间是 no-op', () {
      final WatchCoverage c = WatchCoverage();
      expect(c.add(5, 5), 0);
      expect(c.add(9, 3), 0);
      expect(c.isEmpty, isTrue);
      expect(c.covers(7, 7), isTrue, reason: '空区间视为已覆盖');
    });

    test('JSON 往返无损；脏输入当空', () {
      final WatchCoverage c = WatchCoverage()
        ..add(0, 1000)
        ..add(5000, 7000);
      final String json = c.toJson();
      expect(json, '[[0,1000],[5000,7000]]');
      expect(WatchCoverage.fromJson(json).ranges, c.ranges);
      expect(WatchCoverage.fromJson(null).isEmpty, isTrue);
      expect(WatchCoverage.fromJson('').isEmpty, isTrue);
      expect(WatchCoverage.fromJson('not json').isEmpty, isTrue);
      expect(WatchCoverage.fromJson('{"a":1}').isEmpty, isTrue);
      expect(
        WatchCoverage.fromJson('[[0,10],[1],"x",[5,"y"],[20,30]]').ranges,
        <(int, int)>[(0, 10), (20, 30)],
        reason: '坏元素逐个跳过，好的照收',
      );
    });

    test('copy 是深拷贝：改副本不影响原件', () {
      final WatchCoverage a = WatchCoverage()..add(0, 100);
      final WatchCoverage b = a.copy()..add(100, 200);
      expect(a.totalMs, 100);
      expect(b.totalMs, 200);
    });
  });
}
