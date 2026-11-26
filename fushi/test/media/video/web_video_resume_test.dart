import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/media/video/web_video_resume.dart';

const String _episode = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

WebVideoPlaybackState _state({
  String href = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL1',
  int? positionMs = 0,
  int? durationMs = 3600000,
  bool hasVideo = true,
  bool ad = false,
}) => WebVideoPlaybackState(
  href: href,
  videoKey: 'yt:1',
  hasVideo: hasVideo,
  positionMs: positionMs,
  paused: false,
  durationMs: durationMs,
  videoWidth: 1920,
  videoHeight: 1080,
  rate: 1,
  fullscreen: false,
  title: 't',
  ad: ad,
);

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('WebVideoResumeSeek (2ajU2PuEDA)', () {
    test('no meaningful progress: no tracker', () {
      expect(
        WebVideoResumeSeek.forBook(episodeUrl: _episode, lastPositionMs: 0),
        isNull,
      );
      expect(
        WebVideoResumeSeek.forBook(episodeUrl: _episode, lastPositionMs: 4999),
        isNull,
      );
    });

    test('site starts from the top: seek to saved progress once', () {
      final WebVideoResumeSeek r = WebVideoResumeSeek.forBook(
        episodeUrl: _episode,
        lastPositionMs: 600000,
      )!;
      expect(r.step(_state(positionMs: 300)), 600000);
      expect(r.done, isTrue);
      // 一次性：之后用户拖回片头不再被拉回去。
      expect(r.step(_state(positionMs: 0)), isNull);
    });

    test('waits through ads, missing video and unknown position', () {
      final WebVideoResumeSeek r = WebVideoResumeSeek.forBook(
        episodeUrl: _episode,
        lastPositionMs: 600000,
      )!;
      expect(r.step(_state(ad: true)), isNull);
      expect(r.step(_state(hasVideo: false)), isNull);
      expect(r.step(_state(positionMs: null)), isNull);
      expect(r.done, isFalse);
      expect(r.step(_state()), 600000);
    });

    test('site already resumed (t= / account bookmark): leave it', () {
      final WebVideoResumeSeek r = WebVideoResumeSeek.forBook(
        episodeUrl: _episode,
        lastPositionMs: 600000,
      )!;
      expect(r.step(_state(positionMs: 120000)), isNull);
      expect(r.done, isTrue);
    });

    test('other video in site: progress does not apply', () {
      final WebVideoResumeSeek r = WebVideoResumeSeek.forBook(
        episodeUrl: _episode,
        lastPositionMs: 600000,
      )!;
      expect(
        r.step(_state(href: 'https://www.youtube.com/watch?v=aaaaaaaaaaa')),
        isNull,
      );
      expect(r.done, isTrue);
    });

    test('progress at the very end: start over instead', () {
      final WebVideoResumeSeek r = WebVideoResumeSeek.forBook(
        episodeUrl: _episode,
        lastPositionMs: 3595000,
      )!;
      expect(r.step(_state()), isNull);
      expect(r.done, isTrue);
    });
  });

  group('webVideoYoutubeWatchUrl (C7c1ck6RMU)', () {
    test('YouTube episode: chat replay probe url', () {
      expect(webVideoYoutubeWatchUrl(_episode), _episode);
    });

    test('non-YouTube / unbound: null', () {
      expect(webVideoYoutubeWatchUrl(null), isNull);
      expect(
        webVideoYoutubeWatchUrl('https://www.netflix.com/watch/1'),
        isNull,
      );
      expect(webVideoYoutubeWatchUrl('https://www.youtube.com/'), isNull);
    });
  });

  group('native player page web branch wiring', () {
    final String web = _read(
      'lib/src/pages/implementations/video_fushi/web_source.part.dart',
    );
    final String chat = _read(
      'lib/src/pages/implementations/video_fushi/live_chat.part.dart',
    );

    test('resume is created on open and on newly bound episode', () {
      expect(
        RegExp(
          r'_webResumeSeek = (?:_webPendingRestore == null\s*\?\s*)?'
          r'WebVideoResumeSeek\.forBook\(',
        ).allMatches(web).length,
        2,
      );
      expect(web, contains('_applyWebResumeSeek(state);'));
    });

    test('live chat probe sees the web branch YouTube episode', () {
      expect(
        chat,
        contains('final String? watchUrl = _liveChatYoutubeWatchUrl;'),
      );
      expect(chat, contains('webVideoYoutubeWatchUrl(bound)'));
      // 换视频与新一集落书两处都重新探测。
      expect(
        '_loadLiveChatForCurrentVideo()'.allMatches(web).length,
        greaterThanOrEqualTo(2),
      );
    });
  });
}
