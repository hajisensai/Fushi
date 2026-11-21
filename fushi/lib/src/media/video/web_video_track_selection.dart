// 网页站点视频的选轨状态：两个宿主页（原生播放器页的网页档、内置网页播放器）共用的唯一一份
// （gap-webvideo-11）。站点投来的整轨 / live 轨都登记在这里，选哪条、什么时候要把 cue 重灌进
// 播放器只在这里判；宿主页只负责把 [WebVideoTrackReselect.cues] 灌进自己的 controller。
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart'
    show resolveSubtitleDownloadLanguage;

import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/media/video/web_video_session.dart'
    show webVideoTrackUpdateNeedsReload;

/// 一次重选的结果：[reload] = 宿主页要把 [cues] 灌进 controller（并按当前位置重定位当前句）；
/// [changed] = 当前轨换了（宿主页刷新选轨 UI）。
typedef WebVideoTrackReselect = ({
  bool reload,
  bool changed,
  List<AudioCue> cues,
});

/// 网页视频的默认字幕语言：这本书自己的语言，没有就走与自动下字幕同一条偏好链（字幕工作台
/// 默认语言 > 默认内容语言）。流媒体书的 language 多半是空的，只看它就会落到「第一条整轨」
/// = 站点排在前面的随机语言。
String? webVideoPreferredSubtitleLanguage({
  required String? subtitleWorkbenchLanguage,
  required String? bookLanguage,
  required String? defaultContentLanguage,
}) => resolveSubtitleDownloadLanguage(
  explicitSubtitlePreference: subtitleWorkbenchLanguage,
  videoContentLanguage: bookLanguage,
  globalDefaultContentLanguage: defaultContentLanguage,
);

/// 站点字幕轨集 + 当前选择（两个宿主页各持有一个实例）。
class WebVideoTrackSelection {
  /// store 里所有轨（key = `videoKey|lang`，站点换集后旧集的轨仍留着、按 [videoKey] 过滤）。
  final Map<String, WebVideoTrack> tracks = <String, WebVideoTrack>{};

  /// 站点当前视频身份（glue 的 `videoKey`；SPA 换集即变）。
  String videoKey = '';

  /// 当前显示的轨（[chooseWebVideoTrackKey] 的结果，每次轨集变化重算）。
  String? activeKey;

  /// 显式选定的轨：用户（或手机遥控）点选的，或显式请求后采到的那条（[pendingKey]）。只有它
  /// 钉住选择；自动结果不回写成「选择」，后到的整轨才能取代先到的 live 轨。
  String? pinnedKey;

  /// 显式请求、整轨还没采到的那条（站点播放器轨 / 按需加载的占位轨）：采到即钉住。
  String? pendingKey;

  /// 用户（或手机遥控）显式关了字幕：不再自动挑轨。
  bool subtitlesOff = false;

  /// 站点换了视频：选择从头来（轨集保留，按 [videoKey] 过滤）。
  void beginVideo(String key) {
    videoKey = key;
    activeKey = null;
    pinnedKey = null;
    pendingKey = null;
  }

  /// 轨集整份作废（站内换集落成了另一本书）。
  void clearTracks() {
    tracks.clear();
    activeKey = null;
  }

  /// 用户（或手机遥控）显式选轨；null = 关字幕。随后由 [reselect] 灌进 controller。
  void choose(String? key) {
    subtitlesOff = key == null;
    pendingKey = null;
    pinnedKey = key;
    activeKey = key;
  }

  /// 当前视频名下有 cue 的轨（选轨面板的列表）。
  List<WebVideoTrack> get currentTracks => <WebVideoTrack>[
    for (final WebVideoTrack t in tracks.values)
      if (t.videoKey == videoKey && t.cues.isNotEmpty) t,
  ];

  /// 当前显示的那条轨。
  WebVideoTrack? get activeTrack {
    final String? key = activeKey;
    return key == null ? null : tracks[key];
  }

  /// 轨集 / 当前视频变化后重选当前轨。规则只有一份 [chooseWebVideoTrackKey]（钉住的 > 语言偏好
  /// 的整轨 > 首条整轨 > live）。[updatedKey] = 本次只是这条轨到了 / 长了：选轨没变且它不是
  /// 当前轨时不重灌（[webVideoTrackUpdateNeedsReload]；live 轨边看边长，每采一句都会重投）。
  WebVideoTrackReselect reselect({
    String? updatedKey,
    required String? preferredLanguage,
  }) {
    final String? pending = pendingKey;
    if (pending != null && (tracks[pending]?.cues.isNotEmpty ?? false)) {
      // 显式请求的那条采到了：钉住它。
      pendingKey = null;
      pinnedKey = pending;
    }
    final String? next = subtitlesOff
        ? null
        : chooseWebVideoTrackKey(
            tracks: tracks.values,
            videoKey: videoKey,
            preferredLanguage: preferredLanguage,
            pinned: pinnedKey,
          );
    final bool changed = next != activeKey;
    final bool reload =
        updatedKey == null ||
        webVideoTrackUpdateNeedsReload(
          updatedKey: updatedKey,
          previousActiveKey: activeKey,
          nextActiveKey: next,
        );
    activeKey = next;
    return (
      reload: reload,
      changed: changed,
      cues: next == null
          ? const <AudioCue>[]
          : (tracks[next]?.cues ?? const <AudioCue>[]),
    );
  }
}
