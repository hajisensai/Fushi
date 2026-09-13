import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/youtube_stream_cache.dart';

/// TODO-1314：YouTube 流解析持久缓存的守卫（过期解析 + 文件后端 + 失效剔除）。
void main() {
  group('googleVideoExpiryMs', () {
    test('parses expire unix seconds to ms', () {
      expect(
        googleVideoExpiryMs('https://g/videoplayback?expire=1000&itag=251'),
        1000 * 1000,
      );
    });
    test('missing / malformed expire -> null', () {
      expect(googleVideoExpiryMs('https://g/videoplayback?itag=251'), isNull);
      expect(googleVideoExpiryMs('https://g/v?expire=abc'), isNull);
      expect(googleVideoExpiryMs('https://g/v?expire=0'), isNull);
      expect(googleVideoExpiryMs('::bad::'), isNull);
    });
  });

  group('computeStreamCacheExpiryMs', () {
    final DateTime now = DateTime.fromMillisecondsSinceEpoch(1000 * 1000);

    test('takes earliest expire minus margin', () {
      // stream expire=10000s, audio expire=9000s -> min 9000s; margin 30min.
      final int? e = computeStreamCacheExpiryMs(
        <String?>[
          'https://g/v?expire=10000',
          'https://g/a?expire=9000',
          null,
        ],
        now,
        margin: const Duration(minutes: 30),
      );
      expect(e, 9000 * 1000 - const Duration(minutes: 30).inMilliseconds);
    });

    test('no parseable expire -> null (do not cache)', () {
      expect(
        computeStreamCacheExpiryMs(
            <String?>['https://g/v', 'https://g/a', null], now),
        isNull,
      );
    });

    test('expiry already within margin of now -> null (too close)', () {
      // expire = now + 10min, margin 30min -> withMargin < now -> null.
      final int expireSecs = now.millisecondsSinceEpoch ~/ 1000 + 600;
      expect(
        computeStreamCacheExpiryMs(
          <String?>['https://g/v?expire=$expireSecs'],
          now,
          margin: const Duration(minutes: 30),
        ),
        isNull,
      );
    });
  });

  group('YoutubeStreamCache (file-backed)', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('yt_stream_cache_');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    YoutubeStreamCacheEntry entryExpiringAt(int expiresAtMs) =>
        YoutubeStreamCacheEntry(
          streamUrl: 'https://g/v?itag=137',
          audioStreamUrl: 'https://g/a?itag=251',
          miningVideoUrl: 'https://g/m?itag=18',
          miningVideoHasAudio: true,
          httpHeaders: const <String, String>{'User-Agent': 'Mozilla/5.0'},
          expiresAtMs: expiresAtMs,
        );

    test('put then get returns the entry (persisted across instances)',
        () async {
      final DateTime now = DateTime.fromMillisecondsSinceEpoch(1000);
      final File file = File('${tmp.path}/cache.json');
      final YoutubeStreamCache c1 =
          YoutubeStreamCache(file: file, now: () => now);
      await c1.put('vid1', entryExpiringAt(now.millisecondsSinceEpoch + 60000));
      // 新实例（模拟重启）从同一文件读回。
      final YoutubeStreamCache c2 =
          YoutubeStreamCache(file: file, now: () => now);
      final YoutubeStreamCacheEntry? got = await c2.get('vid1');
      expect(got, isNotNull);
      expect(got!.streamUrl, 'https://g/v?itag=137');
      expect(got.audioStreamUrl, 'https://g/a?itag=251');
      expect(got.miningVideoHasAudio, isTrue);
      expect(got.httpHeaders['User-Agent'], 'Mozilla/5.0');
    });

    test('expired entry is not returned and is pruned on access (get)',
        () async {
      final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(1000);
      final File file = File('${tmp.path}/cache.json');
      final YoutubeStreamCache c1 =
          YoutubeStreamCache(file: file, now: () => t0);
      await c1.put('vid1', entryExpiringAt(t0.millisecondsSinceEpoch + 5000));
      // 时钟推进到过期后（新实例、同文件）。
      final DateTime t1 =
          DateTime.fromMillisecondsSinceEpoch(t0.millisecondsSinceEpoch + 6000);
      final YoutubeStreamCache c2 =
          YoutubeStreamCache(file: file, now: () => t1);
      expect(await c2.get('vid1'), isNull);
      // get 命中过期条目 -> 剔除并落盘（自愈），磁盘不再残留。
      final Map<String, dynamic> onDisk =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect((onDisk['entries'] as Map<String, dynamic>).containsKey('vid1'),
          isFalse);
    });

    test('invalidate removes the entry', () async {
      final DateTime now = DateTime.fromMillisecondsSinceEpoch(1000);
      final File file = File('${tmp.path}/cache.json');
      final YoutubeStreamCache c =
          YoutubeStreamCache(file: file, now: () => now);
      await c.put('vid1', entryExpiringAt(now.millisecondsSinceEpoch + 60000));
      await c.invalidate('vid1');
      expect(await c.get('vid1'), isNull);
    });

    test('BUG-2526 旧 schema 版本（v1 / 缺 version）的整份文件被丢弃，不喂限窗的旧直链', () async {
      // v1 条目全部由 ANDROID client 签流（60s 限窗），liveness `bytes=0-1` 探不出来。
      final DateTime now = DateTime.fromMillisecondsSinceEpoch(1000);
      final File file = File('${tmp.path}/cache.json');
      final Map<String, dynamic> entry =
          entryExpiringAt(now.millisecondsSinceEpoch + 60000).toJson();
      for (final Object? version in <Object?>[1, null, 'x']) {
        file.writeAsStringSync(jsonEncode(<String, dynamic>{
          if (version != null) 'version': version,
          'entries': <String, dynamic>{'vid1': entry},
        }));
        final YoutubeStreamCache c =
            YoutubeStreamCache(file: file, now: () => now);
        expect(await c.get('vid1'), isNull,
            reason: 'version=$version 的旧文件必须整份作废');
      }
      // 当前版本照常读回；put 后磁盘上的版本号就是当前值。
      file.writeAsStringSync(jsonEncode(<String, dynamic>{
        'version': YoutubeStreamCache.schemaVersion,
        'entries': <String, dynamic>{'vid1': entry},
      }));
      final YoutubeStreamCache c =
          YoutubeStreamCache(file: file, now: () => now);
      expect(await c.get('vid1'), isNotNull);
      await c.put('vid2', entryExpiringAt(now.millisecondsSinceEpoch + 60000));
      final Map<String, dynamic> saved =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(saved['version'], YoutubeStreamCache.schemaVersion);
      expect(YoutubeStreamCache.schemaVersion, greaterThanOrEqualTo(2),
          reason: 'v1 = ANDROID 限窗时代，不得回退');
    });

    test('corrupt cache file is treated as empty (never throws)', () async {
      final File file = File('${tmp.path}/cache.json');
      file.writeAsStringSync('{ this is not json');
      final YoutubeStreamCache c = YoutubeStreamCache(
          file: file, now: () => DateTime.fromMillisecondsSinceEpoch(1000));
      expect(await c.get('vid1'), isNull);
    });

    test('entry json round-trips', () {
      final YoutubeStreamCacheEntry e = entryExpiringAt(123456);
      final YoutubeStreamCacheEntry back =
          YoutubeStreamCacheEntry.fromJson(e.toJson());
      expect(back.streamUrl, e.streamUrl);
      expect(back.audioStreamUrl, e.audioStreamUrl);
      expect(back.miningVideoUrl, e.miningVideoUrl);
      expect(back.miningVideoHasAudio, e.miningVideoHasAudio);
      expect(back.expiresAtMs, e.expiresAtMs);
      expect(back.httpHeaders, e.httpHeaders);
      // 无显式画质目标（自动）时不写字段、读回 null。
      expect(e.toJson().containsKey('targetHeight'), isFalse);
      expect(back.targetHeight, isNull);
    });

    test('entry json round-trips targetHeight（显式画质目标）', () {
      const YoutubeStreamCacheEntry e = YoutubeStreamCacheEntry(
        streamUrl: 'https://g/v?itag=308',
        audioStreamUrl: 'https://g/a?itag=251',
        miningVideoUrl: null,
        miningVideoHasAudio: false,
        httpHeaders: <String, String>{},
        expiresAtMs: 123456,
        targetHeight: 1440,
      );
      final YoutubeStreamCacheEntry back =
          YoutubeStreamCacheEntry.fromJson(e.toJson());
      expect(back.targetHeight, 1440);
    });

    test('旧缓存 JSON 无 targetHeight 字段 → 读回 null（自动语义，向后兼容）', () {
      final YoutubeStreamCacheEntry back =
          YoutubeStreamCacheEntry.fromJson(<String, dynamic>{
        'streamUrl': 'https://g/v?itag=137',
        'miningVideoHasAudio': true,
        'httpHeaders': <String, dynamic>{},
        'expiresAtMs': 99,
      });
      expect(back.targetHeight, isNull);
    });
  });
}
