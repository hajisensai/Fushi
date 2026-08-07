import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/stream_video_launch.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/media/video/youtube_source_resolver.dart';
import 'package:fushi/src/media/video/youtube_stream_cache.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart';

VideoBookRow _row({required String videoPath, String? streamSpecJson}) =>
    VideoBookRow(
      bookUid: 'video/stream/abc',
      title: 'stream',
      videoPath: videoPath,
      lastPositionMs: 0,
      currentEpisode: 0,
      delayMs: 0,
      streamSpecJson: streamSpecJson,
    );

void main() {
  group('isStreamVideoBook (TODO-1157)', () {
    test('http/https videoPath -> stream book', () {
      expect(isStreamVideoBook(_row(videoPath: 'https://x/y.m3u8')), isTrue);
      expect(isStreamVideoBook(_row(videoPath: 'http://1.2.3.4/s')), isTrue);
    });

    test('local file path -> not a stream book', () {
      expect(isStreamVideoBook(_row(videoPath: '/home/u/a.mkv')), isFalse);
      expect(isStreamVideoBook(_row(videoPath: r'D:\a\b.mp4')), isFalse);
    });
  });

  group('buildStreamVideoLaunch (direct stream, no network)', () {
    test('direct stream: client carries url + spec headers + subtitle',
        () async {
      const StreamVideoSpec spec = StreamVideoSpec(
        subtitleUrl: 'https://cdn.example.com/s.srt',
        subtitleFileName: 's.srt',
        referer: 'https://example.com/',
        userAgent: 'HibikiAgent/1.0',
      );
      final launch = await buildStreamVideoLaunch(_row(
        videoPath: 'https://cdn.example.com/live.m3u8',
        streamSpecJson: spec.toStorageJson(),
      ));
      expect(launch.client.streamUrl, 'https://cdn.example.com/live.m3u8');
      expect(launch.client.subtitleUrl, 'https://cdn.example.com/s.srt');
      expect(launch.client.subtitleFileName, 's.srt');
      expect(launch.client.httpHeaderFields, <String, String>{
        'Referer': 'https://example.com/',
        'User-Agent': 'HibikiAgent/1.0',
      });
      expect(launch.info.id, 'video/stream/abc');
      launch.client.close();
    });

    test('direct stream with null spec: bare url, no headers/subtitle',
        () async {
      final launch = await buildStreamVideoLaunch(
          _row(videoPath: 'https://cdn.example.com/live.m3u8'));
      expect(launch.client.streamUrl, 'https://cdn.example.com/live.m3u8');
      expect(launch.client.subtitleUrl, isNull);
      expect(launch.client.httpHeaderFields, isEmpty);
      launch.client.close();
    });
  });

  group('buildStreamVideoLaunch YouTube resolve cache (TODO-1314)', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('yt_launch_cache_');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    // expire 参数远在未来（now + ~10h），保证 resolve 结果可缓存。
    final DateTime now = DateTime.fromMillisecondsSinceEpoch(1000 * 1000);
    final int futureExpire = now.millisecondsSinceEpoch ~/ 1000 + 36000;

    YoutubeResolvedSource fakeResolved(String tag) => YoutubeResolvedSource(
          streamUrl: 'https://g/v?itag=137&expire=$futureExpire&t=$tag',
          audioStreamUrl: 'https://g/a?itag=251&expire=$futureExpire',
          miningVideoUrl: 'https://g/m?itag=18&expire=$futureExpire',
          miningVideoHasAudio: true,
          title: '',
          httpHeaders: const <String, String>{'User-Agent': 'Mozilla/5.0'},
          cues: const <AudioCue>[],
        );

    VideoBookRow ytRow() => VideoBookRow(
          bookUid: 'video/stream/yt:dQw4w9WgXcQ',
          title: 'yt',
          videoPath: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          lastPositionMs: 0,
          currentEpisode: 0,
          delayMs: 0,
          streamSpecJson: null,
        );

    test('cache miss resolves once and stores; second open is a cache hit',
        () async {
      int resolveCalls = 0;
      final YoutubeStreamCache cache =
          YoutubeStreamCache(file: File('${tmp.path}/c.json'), now: () => now);
      final launch1 = await buildStreamVideoLaunch(
        ytRow(),
        streamCache: cache,
        youtubeResolver: (String url) async {
          resolveCalls++;
          return fakeResolved('r$resolveCalls');
        },
        livenessCheck: (String u, Map<String, String> h) async => true,
        now: () => now,
      );
      expect(resolveCalls, 1);
      expect(launch1.client.streamUrl, contains('t=r1'));
      launch1.client.close();

      // 第二次开书：命中缓存、liveness 存活 → 不再 resolve，复用缓存 URL。
      final launch2 = await buildStreamVideoLaunch(
        ytRow(),
        streamCache: cache,
        youtubeResolver: (String url) async {
          resolveCalls++;
          return fakeResolved('r$resolveCalls');
        },
        livenessCheck: (String u, Map<String, String> h) async => true,
        now: () => now,
      );
      expect(resolveCalls, 1); // 未再解析
      expect(launch2.client.streamUrl, contains('t=r1')); // 仍是缓存的那条
      launch2.client.close();
    });

    test('cache hit but liveness dead -> invalidate + re-resolve fresh',
        () async {
      int resolveCalls = 0;
      final YoutubeStreamCache cache =
          YoutubeStreamCache(file: File('${tmp.path}/c.json'), now: () => now);
      // 先种一条缓存。
      await buildStreamVideoLaunch(
        ytRow(),
        streamCache: cache,
        youtubeResolver: (String url) async {
          resolveCalls++;
          return fakeResolved('r$resolveCalls');
        },
        livenessCheck: (String u, Map<String, String> h) async => true,
        now: () => now,
      );
      expect(resolveCalls, 1);

      // 再开：命中缓存但 liveness 判失效 → invalidate + 重解析拿新 URL。
      final launch = await buildStreamVideoLaunch(
        ytRow(),
        streamCache: cache,
        youtubeResolver: (String url) async {
          resolveCalls++;
          return fakeResolved('r$resolveCalls');
        },
        livenessCheck: (String u, Map<String, String> h) async => false,
        now: () => now,
      );
      expect(resolveCalls, 2); // 失效触发重解析
      expect(launch.client.streamUrl, contains('t=r2')); // 新 URL
      launch.client.close();

      // 失效后缓存被新结果覆盖（再开且 liveness 存活 → 不再解析）。
      final launch2 = await buildStreamVideoLaunch(
        ytRow(),
        streamCache: cache,
        youtubeResolver: (String url) async {
          resolveCalls++;
          return fakeResolved('r$resolveCalls');
        },
        livenessCheck: (String u, Map<String, String> h) async => true,
        now: () => now,
      );
      expect(resolveCalls, 2);
      launch2.client.close();
    });

    test('no parseable expire -> not cached (each open re-resolves)', () async {
      int resolveCalls = 0;
      final YoutubeStreamCache cache =
          YoutubeStreamCache(file: File('${tmp.path}/c.json'), now: () => now);
      YoutubeResolvedSource noExpire(String tag) => YoutubeResolvedSource(
            streamUrl: 'https://g/v?itag=137&t=$tag',
            audioStreamUrl: null,
            miningVideoUrl: null,
            miningVideoHasAudio: true,
            title: '',
            httpHeaders: const <String, String>{},
            cues: const <AudioCue>[],
          );
      for (int i = 0; i < 2; i++) {
        final launch = await buildStreamVideoLaunch(
          ytRow(),
          streamCache: cache,
          youtubeResolver: (String url) async {
            resolveCalls++;
            return noExpire('r$resolveCalls');
          },
          livenessCheck: (String u, Map<String, String> h) async => true,
          now: () => now,
        );
        launch.client.close();
      }
      // 无 expire 不缓存 → 两次都重解析。
      expect(resolveCalls, 2);
    });
  });
}
