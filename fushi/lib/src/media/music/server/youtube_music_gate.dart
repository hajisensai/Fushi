/// 音乐模块的 YouTube 内置音源（反馈 0tRY-D2JgG）在 app 侧的装配：合规门与起播期取流。
///
/// 浏览器本体（搜索 / 播放路径 / 标题清洗）在 `fushi_engine/media/music/youtube/`；这里只放
/// 依赖 app 的两样：
/// - **合规门**：iOS 不带这个来源。它与插件音源同一条理由（从未授权的第三方平台串流媒体，
///   App Store 审核指南 5.2.3），判据问 [StoreRestrictedCapability.onlineMusicSource]，不另写
///   `Platform.isIOS`；守卫见 `test/build/ios_store_compliance_guard_test.dart`。
/// - **取流**：mpv 后端打开 `fushi-music-youtube://` 曲目时经 [resolveMusicYoutubeStream] 取
///   audio-only 直链，失败统一抛 [MusicPluginStreamUnavailable]（与插件 / 网络来源同一条「这一首
///   拿不到流」路径：引擎跳下一首、原因带给界面）。
library;

import 'package:fushi_engine/media/video/youtube_source_resolver.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart'
    show MusicPluginStreamUnavailable;
import 'package:fushi/src/models/store_compliance.dart';

/// YouTube 内置音源在目标平台上是否存在（测试显式注入平台用）。
bool youtubeMusicSourceAvailableOn({required bool isIOS}) =>
    StoreRestrictedCapability.onlineMusicSource.availableOn(isIOS: isIOS);

/// 真实平台上的 [youtubeMusicSourceAvailableOn]。消费端（来源列表、「来源」页开关、取流）只问它。
bool get isYoutubeMusicSourceAvailable =>
    StoreRestrictedCapability.onlineMusicSource.isAvailable;

/// 一首 YouTube 曲目此刻可播的地址、请求头与过期时刻（epoch 毫秒，未知为 null）。
typedef MusicYoutubeStream = ({
  String url,
  Map<String, String> headers,
  int? expiresAt,
});

/// 视频 id → 流（mpv 后端 / 制卡取流用；缺省 [resolveMusicYoutubeStream]，测试注入替身）。
/// 失败抛 [MusicPluginStreamUnavailable]。
typedef MusicYoutubeStreamResolver =
    Future<MusicYoutubeStream> Function(String videoId);

/// 生产实现：过合规门后经 `youtube_explode_dart` 取最高码率 audio-only 流。
Future<MusicYoutubeStream> resolveMusicYoutubeStream(String videoId) async {
  if (!isYoutubeMusicSourceAvailable) {
    throw MusicPluginStreamUnavailable(t.music_server_youtube_unavailable);
  }
  final YoutubeAudioStream s;
  try {
    s = await resolveYoutubeAudioStream(videoId);
  } on Object catch (e) {
    // 取 manifest 失败（各 client 都 403 / 私享视频 / 限流超时）：这一首拿不到流，原因给界面。
    throw MusicPluginStreamUnavailable('$e');
  }
  return (url: s.url, headers: s.httpHeaders, expiresAt: s.expiresAt);
}
