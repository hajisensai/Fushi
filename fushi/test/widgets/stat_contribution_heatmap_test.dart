import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/utils/components/stat_contribution_heatmap.dart';
import 'package:fushi_core/fushi_core.dart';

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

    test('「今日」重置时刻 = 4：凌晨 2 点的今日格是日历昨日，格子 key 仍是日历日', () {
      FushiDatabase.statDayResetHour = 4;
      addTearDown(() => FushiDatabase.statDayResetHour = 0);
      // 2026-07-16（周四）02:00 → 统计今日 = 07-15（周三）。
      final StatHeatmapModel m = buildStatHeatmap(
        valueByDateKey: <String, int>{'2026-07-15': 7, '2026-07-13': 3},
        now: DateTime(2026, 7, 16, 2),
        weeks: 3,
      );
      final List<StatHeatmapCell> lastCol = m.weeks.last;
      expect(lastCol[2].dateKey, '2026-07-15', reason: '周三 = 统计今日');
      expect(lastCol[2].value, 7);
      expect(lastCol[3].dateKey, isNull, reason: '日历周四还没到统计今日，是未来占位');
      // 周一格的 key 必须是日历日 07-13：若误过 statDateKey，00:00 会被前移成 07-12。
      expect(lastCol[0].dateKey, '2026-07-13');
      expect(lastCol[0].value, 3);
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

    test('单日爆量不再把其余活跃日压成最浅档（BUG-2223：按秩分档）', () {
      // 5 个活跃日：一天 100000，其余 9/10/11/12——旧口径按占最大值比例，四个普通日
      // 全落 1 档；按秩它们分布到 1..4。
      final Map<String, int> values = <String, int>{
        statDateKey(DateTime(2026, 7, 6)): 100000,
        statDateKey(DateTime(2026, 7, 7)): 9,
        statDateKey(DateTime(2026, 7, 8)): 10,
        statDateKey(DateTime(2026, 7, 9)): 11,
        statDateKey(DateTime(2026, 7, 10)): 12,
      };
      final StatHeatmapModel m = buildStatHeatmap(
        valueByDateKey: values,
        now: now,
        weeks: 3,
      );
      final Map<String, int> levels = <String, int>{
        for (final List<StatHeatmapCell> col in m.weeks)
          for (final StatHeatmapCell c in col)
            if (c.dateKey != null && c.value > 0) c.dateKey!: c.level,
      };
      expect(levels[statDateKey(DateTime(2026, 7, 6))], 4);
      expect(levels[statDateKey(DateTime(2026, 7, 7))], 1);
      expect(levels[statDateKey(DateTime(2026, 7, 8))], 2);
      expect(levels[statDateKey(DateTime(2026, 7, 9))], 3);
      expect(levels[statDateKey(DateTime(2026, 7, 10))], 4);
      expect(m.maxValue, 100000);
    });

    test('等级按活跃日数值的秩分 1..4 四档（比例分布的老样例结论不变）', () {
      // 四天不同强度：10/40/60/100 → 秩 1..4 → 档 1..4。
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

  group('statHeatmapRankLevel（纯函数）', () {
    test('零值 / 空表 → 0；唯一活跃日 → 最高档', () {
      expect(statHeatmapRankLevel(0, <int>[1, 2]), 0);
      expect(statHeatmapRankLevel(5, <int>[]), 0);
      expect(statHeatmapRankLevel(7, <int>[7]), 4);
    });

    test('均匀分布时各档人数接近', () {
      final List<int> sorted = List<int>.generate(8, (int i) => (i + 1) * 100);
      final Map<int, int> count = <int, int>{};
      for (final int v in sorted) {
        final int level = statHeatmapRankLevel(v, sorted);
        count[level] = (count[level] ?? 0) + 1;
      }
      expect(count, <int, int>{1: 2, 2: 2, 3: 2, 4: 2});
    });

    test('同值同档；不在表里的值按上秩落档', () {
      const List<int> sorted = <int>[5, 5, 5, 50];
      expect(statHeatmapRankLevel(5, sorted), 3, reason: '上秩 3/4 → ⌈3⌉');
      expect(statHeatmapRankLevel(50, sorted), 4);
      expect(statHeatmapRankLevel(1, sorted), 1, reason: '低于最小值仍至少 1 档');
      expect(statHeatmapRankLevel(6, sorted), 3);
    });

    test('档数可配：levels=5 时最大值落 5 档', () {
      const List<int> sorted = <int>[1, 2, 3, 4, 5];
      expect(statHeatmapRankLevel(5, sorted, levels: 5), 5);
      expect(statHeatmapRankLevel(1, sorted, levels: 5), 1);
      expect(statHeatmapRankLevel(3, sorted, levels: 5), 3);
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
