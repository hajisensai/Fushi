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

void main() {
  // BUG-5419（反馈 lXyoHX1wtr）：Windows 上 YouTube 默认走网页档的可捕获档（原来是内置网页播放器
  // 页，现在是原生播放器页的「制卡优先」档），那一页没有生成字幕入口，在线视频就转录不了。
  group('Windows 上 YouTube 默认落在网页档制卡优先', () {
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

    // 拍板 cbKi3PN0G7-r2（PR #4400）：网页视频两档都在原生播放器页里播，内置网页播放器页只当
    // 制卡重放宿主。生成字幕入口跟着搬到原生播放器页的网页档，两档都给。
    test('原生播放器页网页档的生成字幕入口不看宿主档（制卡优先 / 画质优先都给）', () {
      final String webSource = File(
        'lib/src/pages/implementations/video_fushi/web_source.part.dart',
      ).readAsStringSync();
      final int at = webSource.indexOf('bool get _canRunWebSubtitlePipeline');
      expect(at, greaterThan(-1));
      final String gate = webSource.substring(at, webSource.indexOf(');', at));
      expect(gate, contains('webVideoSubtitlePipelineAvailable('));
      expect(gate, isNot(contains('_webHosting')));
      expect(gate, isNot(contains('windowed')));
      final String subtitle = File(
        'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
      ).readAsStringSync();
      expect(subtitle, contains('_canRunWebSubtitlePipeline;'));
      expect(
        subtitle,
        contains('if (_webMode) return _webSubtitleStudioPanel(controller);'),
      );
      expect(subtitle, contains('await _openWebSubtitlePipeline(controller);'));
    });

    test('制卡重放宿主页不给生成字幕入口，只读回书上登记的生成字幕', () {
      final String src = File(
        'lib/src/pages/implementations/web_video_fushi_page.dart',
      ).readAsStringSync();
      expect(src, isNot(contains('showVideoSubtitleGenerateSheet(')));
      expect(src, isNot(contains('_generateSubtitle(')));
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
