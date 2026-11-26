import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/media/video/web_video_session.dart'
    show kWebVideoMinPersistPositionMs;
import 'package:fushi/src/media/video/web_video_sites.dart'
    show webVideoEpisodeUrl;
import 'package:fushi_engine/media/video/youtube_source_resolver.dart'
    show isYoutubeUrl, youtubeVideoIdOrNull;

/// 网页档（站点视频）一集打开后续播到 Fushi 记下的进度（反馈 2ajU2PuEDA）。
///
/// 网页档每秒把播放头写进这一集书的 `lastPositionMs`（`_persistWebPosition`），但从前
/// 打开时没有任何一处读它：续播只能靠站点账号自己的书签，不登录 YouTube 就每次从头。
/// 本地 / mpv 流那条路径打开时按 `lastPositionMs` 起播，网页档在这里补上同一口径。
///
/// 一次性：首个「是这一集、不是广告、有视频、位置已知」的站点快照到来时做一次决定——
/// 站点已经自己续播（URL 带 `t=`、登录账号的书签）或用户已经看过片头就不动；站点从片头
/// 起播才 seek 到记下的位置。之后不再干预（用户随后拖回片头不会被拉回去）。
class WebVideoResumeSeek {
  WebVideoResumeSeek({required this.episodeUrl, required this.targetMs});

  /// 按书的 [lastPositionMs] 建；进度不足 [kWebVideoMinPersistPositionMs]（等于没看过）时
  /// 返回 null。
  static WebVideoResumeSeek? forBook({
    required String episodeUrl,
    required int lastPositionMs,
  }) {
    if (lastPositionMs < kWebVideoMinPersistPositionMs) return null;
    return WebVideoResumeSeek(episodeUrl: episodeUrl, targetMs: lastPositionMs);
  }

  /// 要续播的那一集（[webVideoEpisodeUrl] 规范化后的地址）。
  final String episodeUrl;

  /// 记下的进度（毫秒）。
  final int targetMs;

  bool _done = false;

  /// 决定已经做完（seek 过 / 判定不用 seek）：调用方可丢掉本对象。
  bool get done => _done;

  /// 这一拍要 seek 到的位置；null = 这一拍不动（还在等 / 已经做完，看 [done]）。
  int? step(WebVideoPlaybackState state) {
    if (_done) return null;
    // 片头广告、还没有视频、位置未知：等下一拍。
    if (state.ad || !state.hasVideo) return null;
    final int? pos = state.positionMs;
    if (pos == null) return null;
    // 站内已经点去了别的视频：这份进度不属于它。
    if (webVideoEpisodeUrl(state.href) != episodeUrl) {
      _done = true;
      return null;
    }
    _done = true;
    // 站点自己续播了 / 已经看了一会儿：不覆盖。
    if (pos >= kWebVideoMinPersistPositionMs) return null;
    if ((targetMs - pos).abs() <= kWebVideoResumeToleranceMs) return null;
    // 上次已经看到片尾：从头再看，不跳到结尾立刻播完。
    final int? duration = state.durationMs;
    if (duration != null &&
        duration > 0 &&
        targetMs >= duration - kWebVideoResumeTailMs) {
      return null;
    }
    return targetMs;
  }
}

/// [WebVideoResumeSeek] 的位置容差：站点状态 250 ms 一拍，再加 seek 落点误差。
const int kWebVideoResumeToleranceMs = 1500;

/// 进度离片尾不足这么多就算看完了，不续播。
const int kWebVideoResumeTailMs = 10000;

/// 网页档这一集若是 YouTube 视频，返回聊天回放探测用的观看地址；否则 null（反馈
/// C7c1ck6RMU：聊天回放只认 mpv 流的 YouTube 地址，网页档永远探测不到）。
String? webVideoYoutubeWatchUrl(String? boundEpisodeUrl) {
  if (boundEpisodeUrl == null || !isYoutubeUrl(boundEpisodeUrl)) return null;
  final String? id = youtubeVideoIdOrNull(boundEpisodeUrl);
  return id == null || id.isEmpty ? null : boundEpisodeUrl;
}
