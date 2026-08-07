// TODO-2487 放送日历：缓存签名/编解码纯函数 + 进程内缓存命中口径。缓存身份 =
// 周窗口 + 过滤集（绑定合集/订阅的 id 升序），任一变化即未命中；TTL 判定的
// now 由调用方注入，测试不依赖真实时钟。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/airing_calendar_cache.dart';
import 'package:fushi/src/media/video/anilist_client.dart';

AiringScheduleCache _cache({
  int fetchedAtMs = 1000,
  String signature = 'sig',
  List<AniListAiringEpisode> episodes = const <AniListAiringEpisode>[],
}) =>
    AiringScheduleCache(
      fetchedAtMs: fetchedAtMs,
      signature: signature,
      episodes: episodes,
    );

void main() {
  setUp(AiringMemoryCache.reset);

  group('airingCacheSignature', () {
    test('distinguishes all-mode from ids-mode and sorts ids', () {
      const int week = 1770000000;
      expect(
        airingCacheSignature(weekStartEpochSeconds: week, mediaIds: null),
        '$week|all',
      );
      expect(
        airingCacheSignature(
          weekStartEpochSeconds: week,
          mediaIds: <int>[9, 5, 7],
        ),
        '$week|ids:5,7,9',
      );
      expect(
        airingCacheSignature(weekStartEpochSeconds: week, mediaIds: <int>[]),
        '$week|ids:',
      );
    });
  });

  group('encode/decode round-trip', () {
    test('round-trips episodes with titles', () {
      final AiringScheduleCache cache = _cache(
        episodes: <AniListAiringEpisode>[
          const AniListAiringEpisode(
            mediaId: 42,
            episode: 7,
            airingAtSeconds: 1770000000,
            media: AniListMedia(
              id: 42,
              romaji: 'Frieren',
              native: '葬送のフリーレン',
              coverUrl: 'https://x/c.png',
            ),
          ),
        ],
      );
      final AiringScheduleCache? decoded = decodeAiringScheduleCache(
        encodeAiringScheduleCache(cache),
        signature: 'sig',
        nowMs: 2000,
      );
      expect(decoded, isNotNull);
      final AniListAiringEpisode episode = decoded!.episodes.single;
      expect(episode.mediaId, 42);
      expect(episode.episode, 7);
      expect(episode.airingAtSeconds, 1770000000);
      expect(episode.media.displayTitle, 'Frieren');
      expect(episode.media.native, '葬送のフリーレン');
      expect(episode.media.coverUrl, 'https://x/c.png');
    });

    test('misses on mismatched signature', () {
      final String raw = encodeAiringScheduleCache(_cache());
      expect(
        decodeAiringScheduleCache(raw, signature: 'other', nowMs: 2000),
        isNull,
      );
    });

    test('misses past TTL but hits inside it', () {
      final String raw = encodeAiringScheduleCache(_cache(fetchedAtMs: 1000));
      const Duration ttl = Duration(hours: 3);
      final int justInside = 1000 + ttl.inMilliseconds;
      final int justPast = 1000 + ttl.inMilliseconds + 1;
      expect(
        decodeAiringScheduleCache(raw, signature: 'sig', nowMs: justInside),
        isNotNull,
      );
      expect(
        decodeAiringScheduleCache(raw, signature: 'sig', nowMs: justPast),
        isNull,
      );
    });

    test('rejects malformed payloads without throwing', () {
      expect(
        decodeAiringScheduleCache('', signature: 'sig', nowMs: 0),
        isNull,
      );
      expect(
        decodeAiringScheduleCache('not json', signature: 'sig', nowMs: 0),
        isNull,
      );
      expect(
        decodeAiringScheduleCache('[]', signature: 'sig', nowMs: 0),
        isNull,
      );
    });
  });

  group('AiringMemoryCache', () {
    test('hits on same signature inside TTL, misses otherwise', () {
      AiringMemoryCache.put(_cache(fetchedAtMs: 1000));
      expect(AiringMemoryCache.get('sig', nowMs: 2000), isNotNull);
      expect(AiringMemoryCache.get('other', nowMs: 2000), isNull);
      final int past = 1000 + kAiringCalendarCacheTtl.inMilliseconds + 1;
      expect(AiringMemoryCache.get('sig', nowMs: past), isNull);
    });

    test('reset clears the cache', () {
      AiringMemoryCache.put(_cache());
      AiringMemoryCache.reset();
      expect(AiringMemoryCache.get('sig', nowMs: 1001), isNull);
    });
  });
}
