import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/utils/components/stat_contribution_heatmap.dart';

/// 贡献热力图纯模型 [buildStatHeatmap] 的单测：窗口/周对齐、等级分桶、未来日占位。
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
  });
}
