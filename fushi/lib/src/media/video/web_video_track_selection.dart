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
/// [changed] = 当前轨换了（宿主页刷新选轨 UI）；[secondaryReload] = 副字幕层该换成
/// [secondaryCues]（选了 / 关了 / 换了视频 / 选的那条采到或长了）。
typedef WebVideoTrackReselect = ({
  bool reload,
  bool changed,
  List<AudioCue> cues,
  bool secondaryReload,
  List<AudioCue> secondaryCues,
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

  /// 副字幕（对照层）选的轨；null = 副字幕关。只由用户显式选（[chooseSecondary]），不自动挑；
  /// 站点按需加载的轨可以先选后到，采到时由 [reselect] 交给宿主页。主轨自动挑选避开它
  /// （[chooseWebVideoTrackKey] 的 `exclude`），免得为副字幕取来的整轨抢走主字幕。
  String? secondaryKey;

  /// 上一次交给宿主页的副字幕 cue（[reselect] 只在它换了时要求重灌副层）。
  List<AudioCue> _secondaryShown = const <AudioCue>[];

  /// 站点换了视频：选择从头来（轨集保留，按 [videoKey] 过滤）。副字幕同样不跟到新视频。
  void beginVideo(String key) {
    videoKey = key;
    activeKey = null;
    pinnedKey = null;
    pendingKey = null;
    secondaryKey = null;
  }

  /// 用户（或手机遥控）显式选副字幕轨；null = 关副字幕。随后由 [reselect] 灌进 controller。
  void chooseSecondary(String? key) {
    secondaryKey = key;
  }

  /// 副字幕层该显示的 cue：选的轨属于当前视频且已采到才有，否则为空。
  List<AudioCue> get secondaryCues {
    final String? key = secondaryKey;
    final WebVideoTrack? track = key == null ? null : tracks[key];
    if (track == null || track.videoKey != videoKey) return const <AudioCue>[];
    return track.cues;
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
            exclude: secondaryKey,
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
    // 副字幕：轨对象每次更新都是新的一份 cue 列表，按身份比对就知道换没换（关着恒为同一个
    // 空常量，不会每次重选都重灌一遍副层）。
    final List<AudioCue> secondary = secondaryCues;
    final bool secondaryReload = !identical(secondary, _secondaryShown);
    _secondaryShown = secondary;
    return (
      reload: reload,
      changed: changed,
      cues: next == null
          ? const <AudioCue>[]
          : (tracks[next]?.cues ?? const <AudioCue>[]),
      secondaryReload: secondaryReload,
      secondaryCues: secondary,
    );
  }
}
