// 原生播放器页的网页档（站点视频，VideoPlayerController.isWebBackend）：哪些入口画、
// 哪些不画。判据是 web_source.part.dart 里的两个纯函数，页面门控与这里同源调用。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show
        videoWebBackendSettingsGroups,
        videoWebBackendSupportsControlItem,
        webVideoLeavesPlayer,
        webVideoPendingTrackCaptureFailed,
        webVideoShowsPlayer;
import 'package:fushi/src/settings/settings_destination.dart' show VideoGroup;

void main() {
  test('要 libmpv / 本地媒体的按钮在网页档不画，播放类按钮照常', () {
    const Set<VideoControlItem> unsupported = <VideoControlItem>{
      VideoControlItem.frameBackward,
      VideoControlItem.frameForward,
      VideoControlItem.screenshot,
      VideoControlItem.ocrFrame,
      VideoControlItem.clipExport,
      // 音轨只在站点上报了音轨时才画（见下一条测试）。
      VideoControlItem.audioTrack,
      VideoControlItem.danmaku,
    };
    for (final VideoControlItem item in VideoControlItem.values) {
      expect(
        videoWebBackendSupportsControlItem(item),
        !unsupported.contains(item),
        reason: '$item',
      );
    }
    // 站点视频照样能播 / 跳 / 变速 / 切字幕 / 全屏：这些必须留着。
    for (final VideoControlItem item in <VideoControlItem>[
      VideoControlItem.playPause,
      VideoControlItem.seekBackward,
      VideoControlItem.seekForward,
      VideoControlItem.speed,
      VideoControlItem.subtitleTrack,
      VideoControlItem.subtitleList,
      VideoControlItem.fullscreen,
      VideoControlItem.settings,
    ]) {
      expect(videoWebBackendSupportsControlItem(item), isTrue, reason: '$item');
    }
  });

  test('识别画面文字按钮：站点画面能截帧（非 DRM）才画', () {
    expect(
      videoWebBackendSupportsControlItem(
        VideoControlItem.ocrFrame,
        canCaptureFrame: true,
      ),
      isTrue,
    );
    expect(
      videoWebBackendSupportsControlItem(VideoControlItem.ocrFrame),
      isFalse,
    );
  });

  test('音轨按钮跟着站点音轨走；章节按钮交给通用门控（站点给了片头片尾标记才有章节）', () {
    expect(
      videoWebBackendSupportsControlItem(
        VideoControlItem.audioTrack,
        hasSiteAudioTracks: true,
      ),
      isTrue,
    );
    for (final VideoControlItem item in <VideoControlItem>[
      VideoControlItem.previousChapter,
      VideoControlItem.nextChapter,
      VideoControlItem.chapterList,
    ]) {
      expect(videoWebBackendSupportsControlItem(item), isTrue, reason: '$item');
    }
  });

  test('待采整轨的确定失败判据：站点已切到该轨且 live 轨在请求后长出新 cue', () {
    expect(
      webVideoPendingTrackCaptureFailed(
        requestedSiteTrackId: 'T:ja',
        siteTrackCurrent: 'T:ja',
        liveCueCountAtRequest: 3,
        liveCueCountNow: 4,
      ),
      isTrue,
    );
    // 站点还没切过去 / live 轨没长 / 不是站点轨：都不算失败（继续等）。
    expect(
      webVideoPendingTrackCaptureFailed(
        requestedSiteTrackId: 'T:ja',
        siteTrackCurrent: 'T:en',
        liveCueCountAtRequest: 3,
        liveCueCountNow: 9,
      ),
      isFalse,
    );
    expect(
      webVideoPendingTrackCaptureFailed(
        requestedSiteTrackId: 'T:ja',
        siteTrackCurrent: 'T:ja',
        liveCueCountAtRequest: 3,
        liveCueCountNow: 3,
      ),
      isFalse,
    );
    expect(
      webVideoPendingTrackCaptureFailed(
        requestedSiteTrackId: '',
        siteTrackCurrent: '',
        liveCueCountAtRequest: 0,
        liveCueCountNow: 5,
      ),
      isFalse,
    );
  });

  test('设置面板去掉着色器 / mpv / 弹幕分组，其余保持原顺序', () {
    expect(
      videoWebBackendSettingsGroups(<VideoGroup>[
        VideoGroup.playback,
        VideoGroup.shaders,
        VideoGroup.mpv,
        VideoGroup.danmaku,
        VideoGroup.controls,
      ]),
      <VideoGroup>[VideoGroup.playback, VideoGroup.controls],
    );
    expect(
      videoWebBackendSettingsGroups(<VideoGroup>[VideoGroup.subtitle]),
      <VideoGroup>[VideoGroup.subtitle],
    );
  });

  // 用户只看到一个浏览器（docs/specs/2026-11-01-one-browser.md）：播放器层没有「网页档」，
  // 只在观看页有视频时挂控件；站点弹层打断时露出页面让用户点。
  test('播放器层只在观看页有视频、没被站点弹层打断时挂控件', () {
    const String watch = 'https://www.netflix.com/watch/81234567';
    expect(
      webVideoShowsPlayer(hasVideo: true, blocked: false, href: watch),
      isTrue,
    );
    expect(
      webVideoShowsPlayer(hasVideo: false, blocked: false, href: watch),
      isFalse,
    );
    expect(
      webVideoShowsPlayer(hasVideo: true, blocked: true, href: watch),
      isFalse,
    );
    // 浏览页的预告片不是正片。
    expect(
      webVideoShowsPlayer(
        hasVideo: true,
        blocked: false,
        href: 'https://www.netflix.com/browse',
      ),
      isFalse,
    );
    // 没有观看页形状的站点：有视频就算。
    expect(
      webVideoShowsPlayer(
        hasVideo: true,
        blocked: false,
        href: 'https://tver.jp/episodes/ep1',
      ),
      isTrue,
    );
  });

  test('离开观看页就关掉播放器层回浏览器；没导航 / 换集 / 其它站点站内换页不关', () {
    expect(webVideoLeavesPlayer(''), isFalse);
    expect(webVideoLeavesPlayer('https://www.netflix.com/watch/2'), isFalse);
    expect(
      webVideoLeavesPlayer('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
      isFalse,
    );
    expect(webVideoLeavesPlayer('https://www.netflix.com/browse'), isTrue);
    expect(webVideoLeavesPlayer('https://www.netflix.com/login'), isTrue);
    expect(webVideoLeavesPlayer('https://www.youtube.com/'), isTrue);
    expect(webVideoLeavesPlayer('https://tver.jp/'), isFalse);
  });
}
