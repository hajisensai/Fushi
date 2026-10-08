import 'package:fushi_engine/leaderboard/local_shelf.dart';
import 'package:test/test.dart';

/// 书架汇总里与服务端 shelf.js normalizeEntry / normalizeDaily 同口径的纯规则。
void main() {
  group('leaderboardUnattributedOwner（BUG-2870）', () {
    test('开着上传且仍存在的 Profile 里取 id 最小', () {
      expect(
        leaderboardUnattributedOwner(
          uploading: <int>[3, 2, 5],
          existing: <int>[1, 2, 3, 5],
        ),
        2,
      );
    });

    test('已删除的 Profile 留下的账户文件不当代表', () {
      expect(
        leaderboardUnattributedOwner(
          uploading: <int>[1, 4],
          existing: <int>[2, 3, 4],
        ),
        4,
      );
    });

    test('没有候选返回 null', () {
      expect(
        leaderboardUnattributedOwner(uploading: <int>[], existing: <int>[1, 2]),
        isNull,
      );
    });
  });

  group('每日字数窗口（DAILY_WINDOW_DAYS = 3650）', () {
    // 服务端判 too_old：date < utcDateKey(now − 3650 天)。
    String serverFloor(DateTime now) {
      final DateTime d = now.toUtc().subtract(const Duration(days: 3650));
      String two(int v) => v.toString().padLeft(2, '0');
      return '${d.year}-${two(d.month)}-${two(d.day)}';
    }

    test('按天数算、留一天余量；十年里有两三个闰日也不会越过服务端下界', () {
      for (final (DateTime now, String from) in <(DateTime, String)>[
        // 2016-09-28 → 2026-09-28 含 2020、2024 两个闰日：按「年 −10」算会得到
        // 2016-09-29，早于服务端下界 2016-09-30，整批 400。
        (DateTime.utc(2026, 9, 28, 12), '2016-10-01'),
        (DateTime.utc(2028, 3, 1, 0, 30), '2018-03-05'),
        // 窗口跨 2020-02-29、2024-02-29、2028-02-29 三个闰日。
        (DateTime.utc(2030, 2, 28, 23), '2020-03-03'),
      ]) {
        expect(leaderboardDailyFrom(now), from, reason: '$now');
        expect(
          leaderboardDailyFrom(now).compareTo(serverFloor(now)),
          greaterThan(0),
          reason: '$now',
        );
      }
    });

    test('上界 = UTC now + 36 小时所在日（服务端 future 判据）', () {
      expect(leaderboardDailyTo(DateTime.utc(2026, 9, 28, 11)), '2026-09-29');
      expect(leaderboardDailyTo(DateTime.utc(2026, 9, 28, 13)), '2026-09-30');
    });
  });

  group('sanitizeFinishedAt', () {
    final int now = DateTime.utc(2026, 9, 28).millisecondsSinceEpoch;

    test('早于 2000-01-01 或晚于 now + 5 分钟 → null（降级为日期未知）', () {
      expect(
        sanitizeFinishedAt(
          DateTime.utc(1999, 12, 31).millisecondsSinceEpoch,
          now,
        ),
        isNull,
      );
      expect(sanitizeFinishedAt(0, now), isNull);
      expect(sanitizeFinishedAt(now + 5 * 60 * 1000 + 1, now), isNull);
      expect(sanitizeFinishedAt(now + 5 * 60 * 1000, now), now + 5 * 60 * 1000);
      final int y2k = DateTime.utc(2000).millisecondsSinceEpoch;
      expect(sanitizeFinishedAt(y2k, now), y2k);
      expect(sanitizeFinishedAt(null, now), isNull);
    });
  });

  group('sanitizeShelfText', () {
    test('控制字符换空格后 trim；只有控制字符 / 空白的标题变空（调用方丢弃）', () {
      expect(sanitizeShelfText('a\u0000b\tc', 300), 'a b c');
      expect(sanitizeShelfText('\u0001\u0002 \n', 300), isEmpty);
    });

    test('截到上限且不劈开代理对', () {
      expect(sanitizeShelfText('x' * 400, 300), hasLength(300));
      final String s = '${'x' * 299}😀tail';
      expect(sanitizeShelfText(s, 300), 'x' * 299);
    });
  });
}
