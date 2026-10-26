import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/anime_download_subscription.dart';

// 旧版 JSON 番剧订阅只剩一次性迁移（VideoDownloadLegacyImporter）要读它：这里只
// 钉编解码契约。按订阅定时搜索种子站的旧服务已随内置 BT 搜索站一起删除。

AnimeDownloadSubscription _subscription({Set<int> processed = const <int>{}}) =>
    AnimeDownloadSubscription(
      id: 'sub-1',
      createdAtMs: 1000,
      anilistId: 42,
      seriesTitle: 'Example Show',
      nyaaQuery: 'Example Show',
      category: '1_2',
      releaseGroup: 'SubsPlease',
      resolution: '1080p',
      startAfterEpisode: 1,
      processedEpisodes: processed,
      jimakuEntryId: 77,
      jimakuEntryName: 'Complete series',
      jimakuLanguage: 'ja',
      enabled: false,
      lastCheckedAtMs: 123,
      lastMatchedAtMs: 120,
      lastError: 'offline',
    );

void main() {
  test('missing preference resolves to the same usable built-in defaults', () {
    final QbConnectionConfig config = effectiveTorrentConfig(null);
    expect(config.backend, QbConnectionConfig.backendAuto);
    expect(config.isConfigured, isTrue);
    expect(config.category, 'fushi');
  });

  test('subscription JSON remains round-trippable', () {
    final AnimeDownloadSubscription original = _subscription(
      processed: <int>{2, 4},
    );
    final AnimeDownloadSubscription? decoded = decodeAnimeDownloadSubscription(
      encodeAnimeDownloadSubscription(original),
    );
    expect(decoded, isNotNull);
    expect(decoded!.id, original.id);
    expect(decoded.anilistId, 42);
    expect(decoded.nyaaQuery, 'Example Show');
    expect(decoded.releaseGroup, 'SubsPlease');
    expect(decoded.resolution, '1080p');
    expect(decoded.processedEpisodes, <int>{2, 4});
    expect(decoded.jimakuEntryId, 77);
    expect(decoded.jimakuEntryName, 'Complete series');
    expect(decoded.jimakuLanguage, 'ja');
    expect(decoded.enabled, isFalse);
    expect(decoded.lastCheckedAtMs, 123);
    expect(decoded.lastMatchedAtMs, 120);
    expect(decoded.lastError, 'offline');
  });

  test('missing optional fields fall back to legacy defaults', () {
    final AnimeDownloadSubscription? decoded = decodeAnimeDownloadSubscription(
      <String, Object?>{
        'id': 'sub-2',
        'anilistId': 7,
        'seriesTitle': 'Show',
        'nyaaQuery': 'Show',
        'releaseGroup': ' Group ',
        'startAfterEpisode': 3,
        'processedEpisodes': <Object?>[1, -2, 'x', 4],
      },
    );
    expect(decoded, isNotNull);
    expect(decoded!.createdAtMs, 0);
    expect(decoded.category, '1_0');
    expect(decoded.releaseGroup, 'Group');
    expect(decoded.processedEpisodes, <int>{1, 4});
    expect(decoded.enabled, isTrue);
    expect(decoded.trustedOnly, isFalse);
  });

  test('malformed JSON is rejected instead of half-decoded', () {
    expect(decodeAnimeDownloadSubscription(<String, Object?>{}), isNull);
    expect(
      decodeAnimeDownloadSubscription(<String, Object?>{
        'id': 'sub-3',
        'anilistId': 7,
        'seriesTitle': 'Show',
        'nyaaQuery': 'Show',
        'releaseGroup': '   ',
        'startAfterEpisode': 1,
      }),
      isNull,
      reason: '空发布组的旧订阅无法迁移',
    );
  });
}
