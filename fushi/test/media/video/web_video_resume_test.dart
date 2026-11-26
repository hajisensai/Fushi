import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_episode_start_policy.dart';
import 'package:fushi/src/media/video/video_resume.dart';
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

WebVideoResumeSeek? _forBook(
  int lastPositionMs, {
  EpisodeStartIntent intent = EpisodeStartIntent.initialOpen,
  VideoResumeMode mode = VideoResumeMode.all,
}) => WebVideoResumeSeek.forBook(
  episodeUrl: _episode,
  lastPositionMs: lastPositionMs,
  intent: intent,
  mode: mode,
);

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('WebVideoResumeSeek (2ajU2PuEDA)', () {
    test('no meaningful progress: no tracker', () {
      expect(_forBook(0), isNull);
      expect(_forBook(4999), isNull);
    });

    test('site starts from the top: seek to saved progress once', () {
      final WebVideoResumeSeek r = _forBook(600000)!;
      expect(r.step(_state(positionMs: 300)), 600000);
      expect(r.done, isTrue);
      // 一次性：之后用户拖回片头不再被拉回去。
      expect(r.step(_state(positionMs: 0)), isNull);
    });

    test('waits through ads, missing video and unknown position', () {
      final WebVideoResumeSeek r = _forBook(600000)!;
      expect(r.step(_state(ad: true)), isNull);
      expect(r.step(_state(hasVideo: false)), isNull);
      expect(r.step(_state(positionMs: null)), isNull);
      expect(r.done, isFalse);
      expect(r.step(_state()), 600000);
    });

    test('site already resumed (t= / account bookmark): leave it', () {
      final WebVideoResumeSeek r = _forBook(600000)!;
      expect(r.step(_state(positionMs: 120000)), isNull);
      expect(r.done, isTrue);
    });

    test('other video in site: progress does not apply', () {
      final WebVideoResumeSeek r = _forBook(600000)!;
      expect(
        r.step(_state(href: 'https://www.youtube.com/watch?v=aaaaaaaaaaa')),
        isNull,
      );
      expect(r.done, isTrue);
    });

    test('progress at the very end: start over instead', () {
      final WebVideoResumeSeek r = _forBook(3595000)!;
      expect(r.step(_state()), isNull);
      expect(r.done, isTrue);
    });

    test('near end uses the shared >=90% rule (BUG-3491)', () {
      // 1 小时片子看到 55 分（>90%）：从头；看到 50 分（<90%）：续播。
      expect(_forBook(3300000)!.step(_state()), isNull);
      expect(_forBook(3000000)!.step(_state()), 3000000);
    });

    test('resume mode off: never seek (IVRHvZ3pmd)', () {
      final WebVideoResumeSeek r = _forBook(600000, mode: VideoResumeMode.off)!;
      expect(r.step(_state(positionMs: 300)), isNull);
      expect(r.done, isTrue);
      expect(
        _forBook(
          600000,
          intent: EpisodeStartIntent.listSelect,
          mode: VideoResumeMode.off,
        )!.step(_state(positionMs: 300)),
        isNull,
      );
    });

    test('resume mode longVideos: short video not seeked, long one is', () {
      // 5 分钟 MV：不续播。
      expect(
        _forBook(
          120000,
          mode: VideoResumeMode.longVideos,
        )!.step(_state(positionMs: 300, durationMs: 300000)),
        isNull,
      );
      // 1 小时：续播。
      expect(
        _forBook(
          600000,
          intent: EpisodeStartIntent.listSelect,
          mode: VideoResumeMode.longVideos,
        )!.step(_state(positionMs: 300)),
        600000,
      );
    });
  });

  group('liveChatWatchUrl (C7c1ck6RMU)', () {
    const String other = 'https://www.youtube.com/watch?v=aaaaaaaaaaa';
    const String stream = 'https://www.youtube.com/watch?v=bbbbbbbbbbb';

    test('mpv stream wins', () {
      expect(
        liveChatWatchUrl(
          streamUrl: stream,
          boundEpisodeUrl: _episode,
          lastHref: other,
        ),
        stream,
      );
    });

    test('web branch: bound episode still playing', () {
      expect(
        liveChatWatchUrl(
          streamUrl: null,
          boundEpisodeUrl: _episode,
          lastHref: '$_episode&list=PL1',
        ),
        _episode,
      );
      // 站点还没报过状态：先按已落书的这一集。
      expect(
        liveChatWatchUrl(
          streamUrl: null,
          boundEpisodeUrl: _episode,
          lastHref: null,
        ),
        _episode,
      );
    });

    test('site navigated to a not-yet-bound video: null', () {
      expect(
        liveChatWatchUrl(
          streamUrl: null,
          boundEpisodeUrl: _episode,
          lastHref: other,
        ),
        isNull,
      );
    });

    test('nothing bound / non-YouTube: null', () {
      expect(
        liveChatWatchUrl(
          streamUrl: null,
          boundEpisodeUrl: null,
          lastHref: null,
        ),
        isNull,
      );
      expect(
        liveChatWatchUrl(
          streamUrl: null,
          boundEpisodeUrl: 'https://www.netflix.com/watch/1',
          lastHref: 'https://www.netflix.com/watch/1',
        ),
        isNull,
      );
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
      // 两处都带用户续播开关（IVRHvZ3pmd）。
      expect(
        'mode: appModel.videoResumeMode,'.allMatches(web).length,
        greaterThanOrEqualTo(2),
      );
    });

    test('live chat probe sees the web branch YouTube episode', () {
      expect(
        chat,
        contains('final String? watchUrl = _liveChatYoutubeWatchUrl;'),
      );
      expect(chat, contains('liveChatWatchUrl('));
      // 换视频与新一集落书两处都重新探测。
      expect(
        '_loadLiveChatForCurrentVideo()'.allMatches(web).length,
        greaterThanOrEqualTo(2),
      );
    });
  });
}
