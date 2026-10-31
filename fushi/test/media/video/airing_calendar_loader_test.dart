import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/video/airing_calendar_cache.dart';
import 'package:fushi/src/media/video/airing_calendar_loader.dart';
import 'package:fushi/src/media/video/anilist_client.dart';

/// 发现页「今日放送」冷启动只拉今天的窗口，不被整周分页挡住（反馈 L1rmA0Ayuh）。
void main() {
  final DateTime weekStart = DateTime(2026, 10, 26); // 周一
  final DateTime today = DateTime(2026, 10, 29, 15); // 周四
  final int todayStart = DateTime(2026, 10, 29).millisecondsSinceEpoch ~/ 1000;
  final int todayEnd = DateTime(2026, 10, 30).millisecondsSinceEpoch ~/ 1000;
  final int nowMs = today.millisecondsSinceEpoch;

  int secondsAt(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

  AniListAiringEpisode episode(int id, DateTime at) => AniListAiringEpisode(
    mediaId: id,
    episode: 1,
    airingAtSeconds: secondsAt(at),
    media: AniListMedia(id: id, romaji: 'Show $id'),
  );

  String pageBody(List<int> ids, int airingAt, {required bool hasNext}) =>
      jsonEncode(<String, dynamic>{
        'data': <String, dynamic>{
          'Page': <String, dynamic>{
            'pageInfo': <String, dynamic>{'hasNextPage': hasNext},
            'airingSchedules': <Map<String, dynamic>>[
              for (final int id in ids)
                <String, dynamic>{
                  'mediaId': id,
                  'episode': 3,
                  'airingAt': airingAt,
                  'media': <String, dynamic>{
                    'title': <String, dynamic>{'romaji': 'Show $id'},
                  },
                },
            ],
          },
        },
      });

  setUp(AiringMemoryCache.reset);
  tearDown(AiringMemoryCache.reset);

  test('冷启动单日请求只按当天窗口拉取，结果按单日签名落缓存', () async {
    final List<Map<String, dynamic>> variables = <Map<String, dynamic>>[];
    final MockClient mock = MockClient((http.Request request) async {
      final Map<String, dynamic> vars =
          (jsonDecode(request.body) as Map<String, dynamic>)['variables']
              as Map<String, dynamic>;
      variables.add(vars);
      final int page = vars['page'] as int;
      return http.Response(
        pageBody(<int>[page], todayStart + 3600, hasNext: page < 2),
        200,
      );
    });
    String persisted = '';

    final List<AniListAiringEpisode> result = await fetchAiringScheduleEpisodes(
      request: AiringCalendarRequest(weekStart: weekStart, day: today),
      filterIds: null,
      readPersisted: () => persisted,
      writePersisted: (String raw) async => persisted = raw,
      createHttpClient: () async => mock,
      nowMs: nowMs,
      pageInterval: Duration.zero,
    );

    expect(result.map((AniListAiringEpisode e) => e.mediaId), <int>[1, 2]);
    expect(variables, hasLength(2));
    for (final Map<String, dynamic> vars in variables) {
      expect(vars['from'], todayStart - 1);
      expect(vars['to'], todayEnd);
    }
    // 单日结果不能冒充整周缓存：日历页的整周请求必须照常未命中。
    final String weekSignature = airingCacheSignature(
      weekStartEpochSeconds: secondsAt(weekStart),
      mediaIds: null,
    );
    expect(
      decodeAiringScheduleCache(
        persisted,
        signature: weekSignature,
        nowMs: nowMs,
      ),
      isNull,
    );
    expect(
      decodeAiringScheduleCache(
        persisted,
        signature: airingDayCacheSignature(
          dayStartEpochSeconds: todayStart,
          mediaIds: null,
        ),
        nowMs: nowMs,
      )?.episodes,
      hasLength(2),
    );

    // 同一天再取：命中单日缓存，不再发请求。
    AiringMemoryCache.reset();
    final List<AniListAiringEpisode> again = await fetchAiringScheduleEpisodes(
      request: AiringCalendarRequest(weekStart: weekStart, day: today),
      filterIds: null,
      readPersisted: () => persisted,
      writePersisted: (String raw) async => persisted = raw,
      createHttpClient: () async => throw StateError('不应发请求'),
      nowMs: nowMs,
    );
    expect(again, hasLength(2));
  });

  test('整周缓存有效时单日请求直接截取当天，不发请求', () async {
    final String weekSignature = airingCacheSignature(
      weekStartEpochSeconds: secondsAt(weekStart),
      mediaIds: null,
    );
    final String persisted = encodeAiringScheduleCache(
      AiringScheduleCache(
        fetchedAtMs: nowMs,
        signature: weekSignature,
        episodes: <AniListAiringEpisode>[
          episode(10, DateTime(2026, 10, 28, 23, 59)),
          episode(11, DateTime(2026, 10, 29)),
          episode(12, DateTime(2026, 10, 29, 22)),
          episode(13, DateTime(2026, 10, 30)),
        ],
      ),
    );

    final List<AniListAiringEpisode> result = await fetchAiringScheduleEpisodes(
      request: AiringCalendarRequest(weekStart: weekStart, day: today),
      filterIds: null,
      readPersisted: () => persisted,
      writePersisted: (String raw) async => fail('命中缓存不应改写'),
      createHttpClient: () async => throw StateError('不应发请求'),
      nowMs: nowMs,
    );

    expect(result.map((AniListAiringEpisode e) => e.mediaId), <int>[11, 12]);
  });

  test('整周请求仍按整周窗口拉取', () async {
    final List<Map<String, dynamic>> variables = <Map<String, dynamic>>[];
    final MockClient mock = MockClient((http.Request request) async {
      variables.add(
        (jsonDecode(request.body) as Map<String, dynamic>)['variables']
            as Map<String, dynamic>,
      );
      return http.Response(pageBody(<int>[1], todayStart, hasNext: false), 200);
    });

    await fetchAiringScheduleEpisodes(
      request: AiringCalendarRequest(weekStart: weekStart),
      filterIds: null,
      readPersisted: () => '',
      writePersisted: (String raw) async {},
      createHttpClient: () async => mock,
      nowMs: nowMs,
    );

    expect(variables.single['from'], secondsAt(weekStart) - 1);
    expect(variables.single['to'], secondsAt(DateTime(2026, 11, 2)));
  });
}
