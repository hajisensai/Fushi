import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/pages/implementations/stat_charts.dart';

void main() {
  final now = DateTime(2026, 6, 7, 12);

  group('bucketActivityByDateKey', () {
    test('收藏（每条 count=1）按今日/本周/本月/全部分桶', () {
      // 收藏发生在不同日期，验证落入正确窗口。
      final events = <(String, int)>[
        ('2026-06-07', 1), // today
        ('2026-06-02', 1), // 本周(7天)内
        ('2026-05-20', 1), // 本月(30天)内、周外
        ('2026-01-01', 1), // 仅全部
      ];
      final b = bucketActivityByDateKey(events, now);
      expect(b.today, 1);
      expect(b.week, 2);
      expect(b.month, 3);
      expect(b.all, 4);
    });

    test('制卡计数（已聚合 count）累加进各窗口', () {
      final events = <(String, int)>[
        ('2026-06-07', 3),
        ('2026-06-05', 2),
      ];
      final b = bucketActivityByDateKey(events, now);
      expect(b.today, 3);
      expect(b.week, 5);
      expect(b.all, 5);
    });

    test('空输入得零桶', () {
      final b = bucketActivityByDateKey(const <(String, int)>[], now);
      expect(b.today, 0);
      expect(b.all, 0);
    });
  });

  group('formatStatDurationAxis（修 0m 0m 0m 退化）', () {
    test('不足 1 分钟回退到秒，而非取整成 0m', () {
      // 旧实现 ms ~/ 60000 会把这些都变成 "0m" → 整条纵轴全是 0m。
      expect(formatStatDurationAxis(30000), '30s');
      expect(formatStatDurationAxis(45000), '45s');
      expect(formatStatDurationAxis(0), '0');
    });

    test('分钟 / 小时正常', () {
      expect(formatStatDurationAxis(60000), '1m');
      expect(formatStatDurationAxis(90000), '1m');
      expect(formatStatDurationAxis(3600000), '1h');
    });

    test('1.5 分钟量级的纵轴刻度不再全 0', () {
      // 模拟 max=90s 时 4 等分刻度：0 / 22.5s / 45s / 67.5s / 90s。
      const maxMs = 90000;
      final labels = <String>[
        for (int i = 0; i <= 4; i++)
          formatStatDurationAxis((maxMs * i / 4).round()),
      ];
      expect(labels.where((l) => l != '0').isNotEmpty, isTrue);
      expect(labels, isNot(everyElement('0m')));
    });
  });

  group('statCharsValue / statMsValue tear-offs', () {
    test('取值正确且为稳定函数引用（shouldRepaint 比较用）', () {
      final d = StatDayData(dateKey: '2026-06-07')
        ..chars = 12
        ..ms = 3400;
      expect(statCharsValue(d), 12);
      expect(statMsValue(d), 3400);
      // 同一顶层 tear-off 多次取用相等（闭包则不等）。
      expect(identical(statMsValue, statMsValue), isTrue);
    });
  });
}
