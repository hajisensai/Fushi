// TODO-2487 放送日历：周窗口/时区纯函数单测。放送时刻是 AniList 的 epoch 秒，
// 展示按设备本地时区——测试用「本地时间 → epoch 秒」构造输入，不依赖测试机
// 所在时区，三端 CI 均可跑。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/airing_week.dart';
import 'package:fushi/src/media/video/anilist_client.dart';

AniListAiringEpisode _episode(int mediaId, DateTime local, {int episode = 1}) =>
    AniListAiringEpisode(
      mediaId: mediaId,
      episode: episode,
      airingAtSeconds: local.millisecondsSinceEpoch ~/ 1000,
      media: AniListMedia(id: mediaId),
    );

void main() {
  group('airingAtToLocal', () {
    test('round-trips a local wall-clock time through epoch seconds', () {
      final DateTime local = DateTime(2026, 8, 5, 21, 30);
      final int seconds = local.millisecondsSinceEpoch ~/ 1000;
      expect(airingAtToLocal(seconds), local);
    });
  });

  group('localWeekStart', () {
    test('maps every weekday of one week to the same Monday midnight', () {
      final DateTime monday = DateTime(2026, 8, 3);
      expect(monday.weekday, DateTime.monday);
      for (int offset = 0; offset < 7; offset++) {
        final DateTime day = DateTime(2026, 8, 3 + offset, 15, 42);
        expect(localWeekStart(day), monday, reason: 'offset $offset');
      }
    });

    test('normalizes across a month boundary', () {
      // 2026-08-01 是周六 → 所在周的周一是 2026-07-27。
      expect(localWeekStart(DateTime(2026, 8, 1, 9)), DateTime(2026, 7, 27));
    });

    test('returns local midnight Monday, with zero time components', () {
      final DateTime start = localWeekStart(DateTime(2026, 8, 6, 23, 59));
      expect(start.weekday, DateTime.monday);
      expect(start.hour, 0);
      expect(start.minute, 0);
      expect(start.second, 0);
    });
  });

  group('daysBetweenLocalDates', () {
    test('ignores time-of-day components', () {
      expect(
        daysBetweenLocalDates(
          DateTime(2026, 8, 3, 23),
          DateTime(2026, 8, 4, 0, 1),
        ),
        1,
      );
    });

    test('is negative when b precedes a', () {
      expect(
        daysBetweenLocalDates(DateTime(2026, 8, 3), DateTime(2026, 8, 1)),
        -2,
      );
    });
  });

  group('groupEpisodesByLocalWeekday', () {
    test('buckets by local weekday and sorts within a day', () {
      final DateTime monday = DateTime(2026, 8, 3);
      final AniListAiringEpisode late1 = _episode(1, DateTime(2026, 8, 3, 22));
      final AniListAiringEpisode early = _episode(2, DateTime(2026, 8, 3, 9));
      final AniListAiringEpisode sunday =
          _episode(3, DateTime(2026, 8, 9, 23, 30));
      final List<List<AniListAiringEpisode>> buckets =
          groupEpisodesByLocalWeekday(
        episodes: <AniListAiringEpisode>[late1, early, sunday],
        weekStartLocal: monday,
      );
      expect(buckets, hasLength(7));
      expect(
        buckets[0].map((AniListAiringEpisode e) => e.mediaId).toList(),
        <int>[2, 1],
      );
      expect(buckets[6].single.mediaId, 3);
      for (int i = 1; i < 6; i++) {
        expect(buckets[i], isEmpty, reason: 'day $i');
      }
    });

    test('drops entries outside the 7-day window', () {
      final DateTime monday = DateTime(2026, 8, 3);
      final AniListAiringEpisode before =
          _episode(1, DateTime(2026, 8, 2, 23, 59));
      final AniListAiringEpisode after =
          _episode(2, DateTime(2026, 8, 10, 0, 1));
      final List<List<AniListAiringEpisode>> buckets =
          groupEpisodesByLocalWeekday(
        episodes: <AniListAiringEpisode>[before, after],
        weekStartLocal: monday,
      );
      expect(buckets.expand((List<AniListAiringEpisode> b) => b), isEmpty);
    });
  });
}
