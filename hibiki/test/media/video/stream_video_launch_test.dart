import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/stream_video_launch.dart';
import 'package:hibiki/src/media/video/url_stream_video.dart';
import 'package:hibiki_core/hibiki_core.dart';

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
}
