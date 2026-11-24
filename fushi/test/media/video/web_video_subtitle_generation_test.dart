import 'dart:io';
import 'package:flutter/foundation.dart' show TargetPlatform;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/video_stream_subtitle_audio.dart'
    show videoStreamSubtitleAudioKey;
import 'package:fushi/src/media/video/url_stream_video.dart'
    show isKnownWebPageVideoUrl;
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi/src/media/video/web_video_hosting_default.dart';
import 'package:fushi/src/media/video/web_video_subtitle_generation.dart';
import 'package:fushi/src/media/video/web_video_subtitle_media.dart'
    show WebVideoSubtitleMediaBlock;

WebVideoPlaybackState _state({
  String href = 'https://www.youtube.com/watch?v=abc123DEF45',
  bool hasVideo = true,
  bool encrypted = false,
  String audioTrack = '',
}) => WebVideoPlaybackState(
  href: href,
  videoKey: 'yt:abc123DEF45',
  hasVideo: hasVideo,
  positionMs: 0,
  paused: false,
  durationMs: 600000,
  videoWidth: 1920,
  videoHeight: 1080,
  rate: 1,
  fullscreen: false,
  title: 'clip',
  siteAudioTrackCurrent: audioTrack,
  encrypted: encrypted,
);

void main() {
  // BUG-5419（反馈 lXyoHX1wtr）：Windows 上 YouTube 默认走内置网页播放器页（「Fushi 播放」），
  // 那一页没有生成字幕入口，在线视频就转录不了。
  group('Windows 上 YouTube 默认落在内置网页播放器页', () {
    test('YouTube 书在 Windows 交给网页播放器，默认档是 builtin', () {
      const String url = 'https://www.youtube.com/watch?v=abc123DEF45';
      expect(isKnownWebPageVideoUrl(url), isTrue);
      expect(
        shouldOpenInWebVideoPlayer(url, platform: TargetPlatform.windows),
        isTrue,
      );
      expect(
        resolveWebVideoHosting(
          siteKey: webVideoSiteKey(Uri.parse(url)),
          manualBySite: null,
          legacyGlobal: null,
          learnedBySite: null,
          underlaySupported: true,
          displayHeightPx: 2160,
        ),
        WebVideoHosting.builtin,
      );
    });

    test('内置档、能跑 ASR、不是制卡宿主页时给「生成字幕」钮', () {
      expect(
        webVideoSubtitleGenerationOffered(
          asrSupported: true,
          windowed: false,
          miningHost: false,
        ),
        isTrue,
      );
      expect(
        webVideoSubtitleGenerationOffered(
          asrSupported: false,
          windowed: false,
          miningHost: false,
        ),
        isFalse,
      );
      expect(
        webVideoSubtitleGenerationOffered(
          asrSupported: true,
          windowed: true,
          miningHost: false,
        ),
        isFalse,
      );
      expect(
        webVideoSubtitleGenerationOffered(
          asrSupported: true,
          windowed: false,
          miningHost: true,
        ),
        isFalse,
      );
    });

    test('内置网页播放器页顶栏接上了生成字幕入口', () {
      final String src = File(
        'lib/src/pages/implementations/web_video_fushi_page.dart',
      ).readAsStringSync();
      expect(src, contains('if (_subtitleGenerationOffered)'));
      expect(src, contains('onPressed: () => unawaited(_generateSubtitle())'));
      expect(src, contains('showVideoSubtitleGenerateSheet('));
      expect(src, contains('unawaited(_restoreGeneratedSubtitle(row))'));
      expect(src, contains('webVideoGeneratedTrackReselectOnVideoChange('));
    });
  });

  group('webVideoGeneratedTrackReselectOnVideoChange', () {
    test('换 key 前选着生成字幕（哪怕是用户亲手选的）→ 接着选', () {
      expect(
        webVideoGeneratedTrackReselectOnVideoChange(
          generatedWasActive: true,
          userChosen: true,
          subtitlesOff: false,
        ),
        isTrue,
      );
    });

    test('没选着：用户没亲手选过、没关字幕才替他选', () {
      expect(
        webVideoGeneratedTrackReselectOnVideoChange(
          generatedWasActive: false,
          userChosen: false,
          subtitlesOff: false,
        ),
        isTrue,
      );
      expect(
        webVideoGeneratedTrackReselectOnVideoChange(
          generatedWasActive: false,
          userChosen: true,
          subtitlesOff: false,
        ),
        isFalse,
      );
      expect(
        webVideoGeneratedTrackReselectOnVideoChange(
          generatedWasActive: false,
          userChosen: false,
          subtitlesOff: true,
        ),
        isFalse,
      );
    });
  });

  group('webVideoSubtitleGenerationBlock', () {
    test('没有播放态 / 页面还没有视频 → noVideo', () {
      expect(
        webVideoSubtitleGenerationBlock(null),
        WebVideoSubtitleMediaBlock.noVideo,
      );
      expect(
        webVideoSubtitleGenerationBlock(_state(hasVideo: false)),
        WebVideoSubtitleMediaBlock.noVideo,
      );
    });

    test('EME 加密 → encrypted；普通视频可以开拉', () {
      expect(
        webVideoSubtitleGenerationBlock(_state(encrypted: true)),
        WebVideoSubtitleMediaBlock.encrypted,
      );
      expect(webVideoSubtitleGenerationBlock(_state()), isNull);
    });
  });

  group('webVideoBookSubtitleEpisode', () {
    test('页面还在这本书那一集（地址带跟踪参数也认）', () {
      final WebVideoSubtitleEpisode? ep = webVideoBookSubtitleEpisode(
        bookUid: 'video/stream/yt:abc123DEF45',
        bookVideoPath: 'https://www.youtube.com/watch?v=abc123DEF45',
        title: '番組',
        href: 'https://www.youtube.com/watch?v=abc123DEF45&t=42s&list=PL1',
        audioTrack: '',
      );
      expect(ep, isNotNull);
      expect(ep!.episodeUrl, 'https://www.youtube.com/watch?v=abc123DEF45');
      expect(ep.title, '番組');
      expect(ep.bookUid, 'video/stream/yt:abc123DEF45');
    });

    test('站内点去了别的视频 / 不是观看页 → null（产物不能登记到这本书上）', () {
      expect(
        webVideoBookSubtitleEpisode(
          bookUid: 'b',
          bookVideoPath: 'https://www.youtube.com/watch?v=abc123DEF45',
          title: 't',
          href: 'https://www.youtube.com/watch?v=zzzzzzzzzzz',
          audioTrack: '',
        ),
        isNull,
      );
      expect(
        webVideoBookSubtitleEpisode(
          bookUid: 'b',
          bookVideoPath: 'https://www.youtube.com/watch?v=abc123DEF45',
          title: 't',
          href: 'https://www.youtube.com/',
          audioTrack: '',
        ),
        isNull,
      );
    });

    test('空标题退回地址；键与原生播放器页网页档同一派生（已拉好的副本两页通用）', () {
      final WebVideoSubtitleEpisode ep = webVideoBookSubtitleEpisode(
        bookUid: 'b',
        bookVideoPath: 'https://www.youtube.com/watch?v=abc123DEF45',
        title: '',
        href: 'https://www.youtube.com/watch?v=abc123DEF45',
        audioTrack: 'ja',
      )!;
      expect(ep.title, ep.episodeUrl);
      expect(
        ep.key,
        videoStreamSubtitleAudioKey(
          sourceId: 'web',
          videoId: 'https://www.youtube.com/watch?v=abc123DEF45',
          episode: 0,
          audioTrack: 'ja',
        ),
      );
      expect(
        const WebVideoSubtitleEpisode(
          episodeUrl: 'u',
          title: 't',
          bookUid: 'b',
        ).key,
        videoStreamSubtitleAudioKey(
          sourceId: 'web',
          videoId: 'u',
          episode: 0,
          audioTrack: '-',
        ),
      );
    });
  });
}
