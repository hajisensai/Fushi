import 'package:fushi/src/media/video/web_video_bridge.dart';

/// 网页视频制卡队列重放（`web_video_fushi_page.dart` 的 `_runMineQueue`）前用户的播放状态：
/// 重放结束（跑完 / 让位 / 停止）后原样还给用户。
///
/// 为什么要显式带着走：每次换档（原生播放器页 → 内置档 → 回来）都是站点整页重载，Netflix
/// 按账号默认值重选字幕轨 / 音轨、按服务器书签起播——而书签已经被重放的逐句 seek 改到了
/// 最后一句附近。不带回来，用户回到的就是「别的轨、别的位置」。
class WebMineReturnState {
  const WebMineReturnState({
    required this.videoKey,
    required this.href,
    required this.positionMs,
    required this.siteTextTrack,
    required this.siteAudioTrack,
  });

  /// 从站点状态快照取（[WebVideoPlaybackState.siteTrackCurrent] 等）。
  factory WebMineReturnState.of(WebVideoPlaybackState state) =>
      WebMineReturnState(
        videoKey: state.videoKey,
        href: state.href,
        positionMs: state.positionMs,
        siteTextTrack: state.siteTrackCurrent,
        siteAudioTrack: state.siteAudioTrackCurrent,
      );

  /// 重放前在看的视频（glue 的 videoKey）；重放导航到别的集后据此判断要不要先导航回来。
  final String videoKey;

  /// 那一集的站点地址（导航回去用）；未知为空。
  final String href;

  /// 重放前的播放头；未知为 null（不 seek）。
  final int? positionMs;

  /// 站点字幕轨 id；空串 = 站点字幕关着。只有站点报了轨清单时才有意义（目前只有 Netflix）。
  final String siteTextTrack;

  /// 站点音轨 id；空串 = 未知（不动音轨）。
  final String siteAudioTrack;
}

/// 把 [want] 落到当前站点状态 [now] 上要做的动作；null = 那一项已经一致 / 无从恢复。
typedef WebMineRestorePlan = ({
  String? navigateHref,
  String? selectTextTrack,
  String? selectAudioTrack,
  int? seekMs,
});

/// [planWebMineRestore] 的位置容差：站点状态 250 ms 一拍，再加 seek 落点误差。
const int kWebMineRestoreSeekToleranceMs = 1500;

/// 纯函数：[want] 与 [now] 对比出要下发的动作。
///
/// - 不在同一集（重放导航到了别的集）：只导航回 [WebMineReturnState.href]，其余等到了再说。
/// - 字幕轨：站点没报轨清单（非 Netflix / 还没加载）不动；[want] 是空串（原来关着字幕）而现在
///   开着 → 下发空串（glue 选 none 轨）；[want] 的轨不在清单里（换集了）不动。
/// - 音轨：同上，但空串 = 原来就不知道，永不下发。
/// - 位置：差超过 [kWebMineRestoreSeekToleranceMs] 才 seek。
WebMineRestorePlan planWebMineRestore(
  WebMineReturnState want,
  WebVideoPlaybackState now,
) {
  if (want.videoKey.isNotEmpty && now.videoKey != want.videoKey) {
    return (
      navigateHref: want.href.isEmpty ? null : want.href,
      selectTextTrack: null,
      selectAudioTrack: null,
      seekMs: null,
    );
  }
  String? text;
  if (now.siteTracks.isNotEmpty && want.siteTextTrack != now.siteTrackCurrent) {
    final bool known =
        want.siteTextTrack.isEmpty ||
        now.siteTracks.any((WebVideoSiteTrack t) => t.id == want.siteTextTrack);
    if (known) text = want.siteTextTrack;
  }
  String? audio;
  if (want.siteAudioTrack.isNotEmpty &&
      want.siteAudioTrack != now.siteAudioTrackCurrent &&
      now.siteAudioTracks.any(
        (WebVideoSiteTrack t) => t.id == want.siteAudioTrack,
      )) {
    audio = want.siteAudioTrack;
  }
  int? seek;
  final int? target = want.positionMs;
  final int? pos = now.positionMs;
  if (target != null &&
      (pos == null || (pos - target).abs() > kWebMineRestoreSeekToleranceMs)) {
    seek = target;
  }
  return (
    navigateHref: null,
    selectTextTrack: text,
    selectAudioTrack: audio,
    seekMs: seek,
  );
}

/// [plan] 什么都不用做了（恢复完成）。
bool webMineRestoreDone(WebMineRestorePlan plan) =>
    plan.navigateHref == null &&
    plan.selectTextTrack == null &&
    plan.selectAudioTrack == null &&
    plan.seekMs == null;
