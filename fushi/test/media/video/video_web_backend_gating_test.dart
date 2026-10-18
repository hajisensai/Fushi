// 原生播放器页的网页档（站点视频，VideoPlayerController.isWebBackend）：哪些入口画、
// 哪些不画。判据是 web_source.part.dart 里的两个纯函数，页面门控与这里同源调用。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show videoWebBackendSettingsGroups, videoWebBackendSupportsControlItem;
import 'package:fushi/src/settings/settings_destination.dart' show VideoGroup;

void main() {
  test('要 libmpv / 本地媒体的按钮在网页档不画，播放类按钮照常', () {
    const Set<VideoControlItem> unsupported = <VideoControlItem>{
      VideoControlItem.frameBackward,
      VideoControlItem.frameForward,
      VideoControlItem.screenshot,
      VideoControlItem.clipExport,
      VideoControlItem.audioTrack,
      VideoControlItem.previousChapter,
      VideoControlItem.nextChapter,
      VideoControlItem.chapterList,
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
}
