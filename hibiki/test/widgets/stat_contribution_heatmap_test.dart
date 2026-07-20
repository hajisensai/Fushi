import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/utils/components/stat_contribution_heatmap.dart';

/// 贡献热力图纯模型 [buildStatHeatmap] 的单测：窗口/周对齐、等级分桶、未来日占位，
/// 以及翻页偏移 [maxHeatmapPageOffset]、格子命中 [hitStatHeatmapCell]。
void main() {
  group('buildStatHeatmap', () {
    // 固定「现在」= 2026-07-15（周三），避免依赖真实时钟。
    final DateTime now = DateTime(2026, 7, 15, 10, 30);

    test('列数 = weeks，每列 7 天（周一..周日）', () {
      final StatHeatmapModel m = buildStatHeatmap(
        valueByDateKey: const <String, int>{},
        now: now,
        weeks: 10,
      );
      expect(m.weeks.length, 10);
      for (final List<StatHeatmapCell> col in m.weeks) {
        expect(col.length, 7);
      }
      expect(m.maxValue, 0);
    });

    test('空数据全为 level 0', () {
      final StatHeatmapModel m = buildStatHeatmap(
        valueByDateKey: const <String, int>{},
        now: now,
        weeks: 4,
      );
      for (final List<StatHeatmapCell> col in m.weeks) {
        for (final StatHeatmapCell c in col) {
          expect(c.level, 0);
        }
      }
    });

    test('末列今天之后是未来占位格（dateKey=null, level 0）', () {
      final StatHeatmapModel m = buildStatHeatmap(
        valueByDateKey: const <String, int>{},
        now: now,
        weeks: 3,
      );
      final List<StatHeatmapCell> lastCol = m.weeks.last;
      // 2026-07-15 是周三（weekday=3）→ 周一..周三是过去/今天（非 null），
      // 周四..周日是未来（null 占位）。
      expect(lastCol[0].dateKey, isNotNull); // 周一
      expect(lastCol[2].dateKey, isNotNull); // 周三=今天
      expect(lastCol[3].dateKey, isNull); // 周四=未来
      expect(lastCol[6].dateKey, isNull); // 周日=未来
    });

    test('今天的值落进末列对应行并计入 maxValue', () {
      final String todayKey = statDateKey(DateTime(2026, 7, 15));
      final StatHeatmapModel m = buildStatHeatmap(
        valueByDateKey: <String, int>{todayKey: 5000},
        now: now,
        weeks: 3,
      );
      expect(m.maxValue, 5000);
      final StatHeatmapCell todayCell = m.weeks.last[2]; // 周三
      expect(todayCell.dateKey, todayKey);
      expect(todayCell.value, 5000);
      expect(todayCell.level, 4); // 唯一非零值 = 满值 → 最高档
    });

    test('等级按占 maxValue 比例分 1..4 四档', () {
      // 四天不同强度：max=100 → 10%→1, 40%→2, 60%→3, 100%→4。
      final DateTime d1 = DateTime(2026, 7, 13); // 周一
      final DateTime d2 = DateTime(2026, 7, 14); // 周二
      final DateTime d3 = DateTime(2026, 7, 15); // 周三=今天
      final DateTime d0 = DateTime(2026, 7, 12); // 上周日
      final StatHeatmapModel m = buildStatHeatmap(
        valueByDateKey: <String, int>{
          statDateKey(d0): 100,
          statDateKey(d1): 10,
          statDateKey(d2): 40,
          statDateKey(d3): 60,
        },
        now: now,
        weeks: 3,
      );
      expect(m.maxValue, 100);
      int levelForKey(String key) {
        for (final List<StatHeatmapCell> col in m.weeks) {
          for (final StatHeatmapCell c in col) {
            if (c.dateKey == key) return c.level;
          }
        }
        fail('key $key not found in window');
      }

      expect(levelForKey(statDateKey(d0)), 4); // 100%
      expect(levelForKey(statDateKey(d1)), 1); // 10%
      expect(levelForKey(statDateKey(d2)), 2); // 40%
      expect(levelForKey(statDateKey(d3)), 3); // 60%
    });

    test('窗口外的旧日期不影响（只取最近 weeks 周）', () {
      // 20 周前的一天不应出现在 4 周窗口里。
      final String ancient = statDateKey(DateTime(2026, 2, 1));
      final StatHeatmapModel m = buildStatHeatmap(
        valueByDateKey: <String, int>{ancient: 9999},
        now: now,
        weeks: 4,
      );
      expect(m.maxValue, 0); // 窗口内无数据
      for (final List<StatHeatmapCell> col in m.weeks) {
        for (final StatHeatmapCell c in col) {
          expect(c.dateKey == ancient, isFalse);
        }
      }
    });

    test('weekOffset 把窗口整体前移一屏：末列不再含今天、无未来占位', () {
      // now=2026-07-15（周三）。offset=0 时末列含今天且有未来占位；
      // offset=weeks(=3) 时窗口整体前移 3 周，全为过去日、无 null 占位。
      final StatHeatmapModel m = buildStatHeatmap(
        valueByDateKey: const <String, int>{},
        now: now,
        weeks: 3,
        weekOffset: 3,
      );
      final String todayKey = statDateKey(DateTime(2026, 7, 15));
      for (final List<StatHeatmapCell> col in m.weeks) {
        for (final StatHeatmapCell c in col) {
          expect(c.dateKey, isNotNull); // 全在过去 → 无未来占位
          expect(c.dateKey == todayKey, isFalse); // 今天不在此屏
        }
      }
      // 前移一屏后，前一屏（offset=0）的旧日落进本屏：末列末行=前移窗口的末周日。
      final StatHeatmapModel prev = buildStatHeatmap(
        valueByDateKey: const <String, int>{},
        now: now,
        weeks: 3,
      );
      // offset=3 屏的末列周一 = offset=0 屏首列周一往前推 0（相邻拼接），二者不重叠。
      final String prevFirstMonday = prev.weeks.first[0].dateKey!;
      final String offFirstMonday = m.weeks.first[0].dateKey!;
      expect(offFirstMonday.compareTo(prevFirstMonday) < 0, isTrue);
    });
  });

  group('maxHeatmapPageOffset', () {
    final DateTime now = DateTime(2026, 7, 15, 10, 30); // 周三

    test('空数据 → 0（无翻页）', () {
      expect(
        maxHeatmapPageOffset(
          valueByDateKey: const <String, int>{},
          now: now,
          weeks: 17,
        ),
        0,
      );
    });

    test('数据都在首屏内 → 0', () {
      // 2 周前的一天，weeks=17 首屏足以覆盖 → 无需翻页。
      final String k = statDateKey(DateTime(2026, 7, 1));
      expect(
        maxHeatmapPageOffset(
          valueByDateKey: <String, int>{k: 100},
          now: now,
          weeks: 17,
        ),
        0,
      );
    });

    test('最早数据超出一屏 → 返回 weeks 的整数倍', () {
      // weeks=4（一屏 4 周）。最早数据约 10 周前 → weeksBack≈10 → pages=2 → 8。
      final String k = statDateKey(DateTime(2026, 5, 6)); // 距 7-15 约 10 周
      final int off = maxHeatmapPageOffset(
        valueByDateKey: <String, int>{k: 5},
        now: now,
        weeks: 4,
      );
      expect(off % 4, 0);
      expect(off, greaterThan(0));
      // 该偏移的窗口应真的含最早数据周（不早于最早周、覆盖到它）。
      final StatHeatmapModel m = buildStatHeatmap(
        valueByDateKey: <String, int>{k: 5},
        now: now,
        weeks: 4,
        weekOffset: off,
      );
      bool found = false;
      for (final List<StatHeatmapCell> col in m.weeks) {
        for (final StatHeatmapCell c in col) {
          if (c.dateKey == k) found = true;
        }
      }
      expect(found, isTrue);
    });
  });

  group('hitStatHeatmapCell', () {
    const double cell = 12;
    const double spacing = 3;
    const double step = cell + spacing; // 15

    test('格子内部命中对应 (列,行)', () {
      // 第 2 列(索引1) 第 3 行(索引2) 的中心 ≈ (1*15+6, 2*15+6)=(21,36)。
      final ({int col, int row})? hit = hitStatHeatmapCell(
        const Offset(21, 36),
        cell: cell,
        spacing: spacing,
        cols: 5,
      );
      expect(hit, isNotNull);
      expect(hit!.col, 1);
      expect(hit.row, 2);
    });

    test('落在格子间隙 → null', () {
      // x=13 落在第 0 列格子(0..12)右侧的 spacing 间隙(12..15)。
      expect(
        hitStatHeatmapCell(
          const Offset(13, 6),
          cell: cell,
          spacing: spacing,
          cols: 5,
        ),
        isNull,
      );
    });

    test('越界（列 >= cols 或 行 >= 7 或负）→ null', () {
      expect(
        hitStatHeatmapCell(
          const Offset(5 * step + 1, 6),
          cell: cell,
          spacing: spacing,
          cols: 5,
        ),
        isNull,
      );
      expect(
        hitStatHeatmapCell(
          const Offset(6, 7 * step + 1),
          cell: cell,
          spacing: spacing,
          cols: 5,
        ),
        isNull,
      );
      expect(
        hitStatHeatmapCell(
          const Offset(-1, 6),
          cell: cell,
          spacing: spacing,
          cols: 5,
        ),
        isNull,
      );
    });
  });
}
