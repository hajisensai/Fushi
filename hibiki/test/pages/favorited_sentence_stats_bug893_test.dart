import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi_audio/fushi_audio.dart';

// BUG-893：阅读统计「收藏语句」计数恒为 0。根因——reader 书内收藏写入端不带 dateKey，
// 读取端又用 `dateKey != null` 过滤，把所有书内收藏滤光。修复：写入补 dateKey +
// 读取端回退 `dateKey ?? statDateKey(createdAt)`（createdAt 恒非空，已存无 dateKey 收藏也计入）。

/// 复刻 reading_statistics_page._loadData 里收藏语句的分桶映射（read-side 修复逻辑）。
StatActivityBuckets bucketFavoritedSentences(
    List<FavoriteSentence> favSentences, DateTime now) {
  return bucketActivityByDateKey(
    favSentences
        .where((FavoriteSentence s) => s.source != kFavoriteSentenceSourceVideo)
        .map(
            (FavoriteSentence s) => (s.dateKey ?? statDateKey(s.createdAt), 1)),
    now,
  );
}

void main() {
  final DateTime now = DateTime(2026, 7, 18, 20, 0, 0);

  group('favorited sentence bucketing (read-side fallback)', () {
    test('无 dateKey 的书内收藏按 createdAt 计入（修复前恒 0）', () {
      final favs = <FavoriteSentence>[
        FavoriteSentence(
            text: 'あ', bookTitle: 'B', createdAt: DateTime(2026, 7, 18, 9)),
        FavoriteSentence(
            text: 'い', bookTitle: 'B', createdAt: DateTime(2026, 7, 18, 10)),
        FavoriteSentence(
            text: 'う', bookTitle: 'B', createdAt: DateTime(2026, 7, 17, 22)),
      ];
      final b = bucketFavoritedSentences(favs, now);
      expect(b.all, 3, reason: '全部三条都应计入（修复前 dateKey==null 被滤 → 0）');
      expect(b.today, 2, reason: '今日创建两条');
      expect(b.week, 3);
    });

    test('显式 dateKey 优先于 createdAt', () {
      final favs = <FavoriteSentence>[
        FavoriteSentence(
          text: 'x',
          bookTitle: 'B',
          createdAt: DateTime(2026, 7, 10),
          dateKey: '2026-07-18', // 显式今天
        ),
      ];
      final b = bucketFavoritedSentences(favs, now);
      expect(b.today, 1);
    });

    test('视频来源收藏被排除（归视频统计）', () {
      final favs = <FavoriteSentence>[
        FavoriteSentence(
          text: 'v',
          bookTitle: 'V',
          createdAt: DateTime(2026, 7, 18),
          source: kFavoriteSentenceSourceVideo,
          dateKey: '2026-07-18',
        ),
        FavoriteSentence(
            text: 'b', bookTitle: 'B', createdAt: DateTime(2026, 7, 18)),
      ];
      final b = bucketFavoritedSentences(favs, now);
      expect(b.all, 1, reason: '只书内那条计入');
    });

    // REGRESSION：旧读取逻辑（保留 dateKey != null 过滤）会把无 dateKey 的收藏全滤掉 → 0。
    test('旧过滤逻辑复刻：无 dateKey 收藏被滤成 0（坐实根因）', () {
      final favs = <FavoriteSentence>[
        FavoriteSentence(
            text: 'a', bookTitle: 'B', createdAt: DateTime(2026, 7, 18)),
      ];
      final oldBuckets = bucketActivityByDateKey(
        favs
            .where((s) =>
                s.source != kFavoriteSentenceSourceVideo && s.dateKey != null)
            .map((s) => (s.dateKey!, 1)),
        now,
      );
      expect(oldBuckets.all, 0, reason: '旧逻辑漏掉无 dateKey 收藏');
      // 新逻辑修好。
      expect(bucketFavoritedSentences(favs, now).all, 1);
    });
  });

  group('source guards (lock the fix)', () {
    test('reader 书内收藏写入端补了 dateKey', () {
      final String src =
          File('lib/src/pages/implementations/reader_hibiki/chrome.part.dart')
              .readAsStringSync();
      // 锚定方法「定义」（`Future<void> _toggleFavoriteSentence()`），不是它的调用点。
      final int def = src.indexOf('Future<void> _toggleFavoriteSentence(');
      expect(def, greaterThanOrEqualTo(0));
      // 锚定构造赋值（`= FavoriteSentence(`），避开方法名本身含 "FavoriteSentence("。
      final int ctor = src.indexOf('= FavoriteSentence(', def);
      expect(ctor, greaterThanOrEqualTo(0));
      // 构造块内（下一处 `);` 之前）出现 dateKey: statTodayKey()。
      final int ctorEnd = src.indexOf(');', ctor);
      final String region = src.substring(ctor, ctorEnd);
      expect(region.contains('dateKey: statTodayKey()'), isTrue,
          reason: 'BUG-893 回归：书内收藏不带 dateKey → 统计恒 0');
    });

    test('阅读统计读取端回退 createdAt，不再用 dateKey != null 过滤收藏语句', () {
      final String src =
          File('lib/src/pages/implementations/reading_statistics_page.dart')
              .readAsStringSync();
      expect(src.contains('s.dateKey ?? statDateKey(s.createdAt)'), isTrue,
          reason: 'BUG-893：读取端须回退 createdAt，兼容已存无 dateKey 收藏');
    });
  });
}
