// 原生播放器页的网页档（站点视频，VideoPlayerController.isWebBackend）：哪些入口画、
// 哪些不画。判据是 web_source.part.dart 里的两个纯函数，页面门控与这里同源调用。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show
        videoWebBackendSettingsGroups,
        videoWebBackendSupportsControlItem,
        WebVideoBackAction,
        webVideoBackAction,
        webVideoPendingTrackCaptureFailed;
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

  test('返回键：播放器档永远先退回网页档（浏览器交接过来的也一样），网页档再回浏览器 / 后退 / 关页', () {
    for (final bool backToBrowser in <bool>[false, true]) {
      for (final bool canGoBack in <bool>[false, true]) {
        expect(
          webVideoBackAction(
            playerMode: true,
            backToBrowser: backToBrowser,
            canGoBack: canGoBack,
          ),
          WebVideoBackAction.toPageMode,
          reason: 'backToBrowser=$backToBrowser canGoBack=$canGoBack',
        );
      }
    }
    expect(
      webVideoBackAction(
        playerMode: false,
        backToBrowser: true,
        canGoBack: true,
      ),
      WebVideoBackAction.closePage,
    );
    expect(
      webVideoBackAction(
        playerMode: false,
        backToBrowser: false,
        canGoBack: true,
      ),
      WebVideoBackAction.goBack,
    );
    expect(
      webVideoBackAction(
        playerMode: false,
        backToBrowser: false,
        canGoBack: false,
      ),
      WebVideoBackAction.closePage,
    );
  });
}
