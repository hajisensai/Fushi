/// 网页模式（站点自己的播放器放在 WebView 里，`VideoFushiPage` 的网页档）这一集的整集音频
/// 从哪里拉，供「生成字幕」完整管线当输入——之后与在线流同一条路：拉成本机副本
/// （`VideoStreamSubtitleAudioStager`）→ `AppVideoSubtitleService.resolveStream`。
///
/// 媒体地址的来源（页面 glue `window.__fushiWebVideo.mediaSource()`，见
/// `assets/web_video/web_video_glue.js`）：
///
/// - **YouTube**：不读页面，按观看页地址的视频 id 现取一条 audio-only 流
///   （`resolveYoutubeAudioStream`，与粘贴的 YouTube 流同一条），经本机中继交给 ffmpeg。
/// - 主视频 `<video>.currentSrc` 是 http(s) 直链（mp4 / m3u8 / mpd）：直接拉。
/// - MSE 播放（`currentSrc` 是 `blob:`）：用页面为**当前这个视频**请求过的 HLS / DASH 清单
///   （glue 从 Resource Timing 里认、按 videoKey 归属），HLS 优先，取最早那条（播放器先取
///   master，再取各档子清单）。
/// - 请求头：页面自己的 UA、观看页作 Referer、WebView cookie 罐里这条地址会带的 Cookie——与
///   页面自己取流同一身份。
///
/// 客观拿不到的两种（[WebVideoSubtitleMediaBlock]）：
/// - EME 加密流（`<video>.mediaKeys` 已挂 / Netflix）：媒体数据只有 CDM 解得开，地址拿到了
///   ffmpeg 也只读到密文（W3C Encrypted Media Extensions 的设计目的）。
/// - MSE 播放而页面没有请求过任何清单：站点脚本自己拼分段喂 SourceBuffer，没有可交给
///   ffmpeg 的地址。
library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:fushi_engine/media/video/youtube_source_resolver.dart'
    show YoutubeAudioStream, resolveYoutubeAudioStream, youtubeVideoIdOrNull;

import 'package:fushi/src/media/video/subtitle/video_stream_subtitle_audio.dart'
    show VideoStreamSubtitleAudioInput;
import 'package:fushi/src/media/video/url_stream_video.dart'
    show YoutubeAudioStreamResolver;
import 'package:fushi/src/media/video/youtube_range_relay.dart'
    show YoutubeStreamRelay, relayYoutubeStreamUrl;

/// 生成字幕在网页档字幕轨里的语言段（store key `videoKey|<段>`）：与站点轨的语言码 / 显示名
/// 都不会撞（站点轨没有带 `fushi-` 前缀的）。
const String kWebVideoGeneratedTrackLang = 'fushi-generated';

/// 当前视频 [videoKey] 下生成字幕那条轨的 key。
String webVideoGeneratedTrackKey(String videoKey) =>
    '$videoKey|$kWebVideoGeneratedTrackLang';

/// 生成字幕文件名里的语言码（导出名 `<主名>.<语言>.srt`）；认不出为 null。
String? webVideoGeneratedSubtitleLanguage(String path) {
  final RegExpMatch? m = RegExp(
    r'\.([A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?)\.[A-Za-z0-9]+$',
  ).firstMatch(path);
  return m?.group(1);
}

/// 网页档这一集能不能跑字幕生成管线（同步判据，决定入口显不显示）：网页档的播放器档里、
/// 这一集已落成书（产物登记与重进恢复都挂在书上，站点入口还没播起任何一集时没有）、主视频
/// 不是 EME 加密流、本机能跑 ASR。媒体地址拿不拿得到要问页面（异步），开拉时判、说明原因。
bool webVideoSubtitlePipelineAvailable({
  required bool webMode,
  required bool playerMode,
  required bool episodeBound,
  required bool encrypted,
  required bool asrSupported,
}) => webMode && playerMode && episodeBound && !encrypted && asrSupported;

/// glue `mediaSource()` 的回执（页面上报，不可信：只当候选地址用，scheme 只认 http(s)）。
@immutable
class WebVideoMediaProbe {
  const WebVideoMediaProbe({
    this.userAgent = '',
    this.hasVideo = false,
    this.src = '',
    this.encrypted = false,
    this.manifests = const <String>[],
  });

  final String userAgent;
  final bool hasVideo;

  /// 主视频的 `currentSrc`（MSE 播放时是 `blob:`）。
  final String src;

  /// 主视频是 EME 加密流。
  final bool encrypted;

  /// 页面为当前视频请求过的 HLS / DASH 清单，按请求先后。
  final List<String> manifests;
}

/// 解析 glue 回执（JSON 字符串或已解码的 Map）；坏形状回 null（与 bridge 的其它载荷同口径）。
WebVideoMediaProbe? parseWebVideoMediaProbe(Object? raw) {
  Object? decoded = raw;
  if (raw is String) {
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }
  if (decoded is! Map) return null;
  final Object? manifests = decoded['manifests'];
  return WebVideoMediaProbe(
    userAgent: (decoded['ua'] ?? '').toString(),
    hasVideo: decoded['hasVideo'] == true,
    src: (decoded['src'] ?? '').toString(),
    encrypted: decoded['eme'] == true,
    manifests: <String>[
      if (manifests is List)
        for (final Object? m in manifests)
          if (m is String && _isHttpUrl(m)) m,
    ],
  );
}

bool _isHttpUrl(String url) {
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return false;
  final String scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

/// 地址指向的媒体形态（按路径后缀）。
WebVideoSubtitleMediaKind _kindOf(String url) {
  final String path = Uri.parse(url).path.toLowerCase();
  if (path.endsWith('.m3u8')) return WebVideoSubtitleMediaKind.hls;
  if (path.endsWith('.mpd')) return WebVideoSubtitleMediaKind.dash;
  return WebVideoSubtitleMediaKind.direct;
}

enum WebVideoSubtitleMediaKind {
  /// YouTube：按视频 id 现取 audio-only 流。
  youtube,

  /// 渐进式直链（mp4 / webm …）。
  direct,
  hls,
  dash,
}

/// 客观拿不到可拉的媒体。
enum WebVideoSubtitleMediaBlock {
  /// 页面上还没有视频。
  noVideo,

  /// EME 加密流。
  encrypted,

  /// MSE 播放、页面没有请求过清单：没有可交给 ffmpeg 的地址。
  noMediaAddress,
}

/// [resolveWebVideoSubtitleMedia] 的结果：[block] 为 null 时 [kind] / [url]（YouTube 为视频
/// id 对应的观看页地址，真正的流在开拉时现取）可用。
@immutable
class WebVideoSubtitleMedia {
  const WebVideoSubtitleMedia.available(this.kind, this.url, {this.youtubeId})
    : block = null;

  const WebVideoSubtitleMedia.blocked(WebVideoSubtitleMediaBlock this.block)
    : kind = null,
      url = '',
      youtubeId = null;

  final WebVideoSubtitleMediaKind? kind;
  final String url;
  final String? youtubeId;
  final WebVideoSubtitleMediaBlock? block;

  /// 有画面可抽（AI 校对的参考画面）：YouTube 现取的是纯音频流，没有画面。
  bool get hasPicture =>
      block == null && kind != WebVideoSubtitleMediaKind.youtube;
}

/// 选这一集整集音频的来源（规则见文件头）。[pageUrl] 是观看页地址（宿主对过主机的可信值，
/// 不取页面回执里的 href）。
WebVideoSubtitleMedia resolveWebVideoSubtitleMedia(
  WebVideoMediaProbe? probe, {
  required String pageUrl,
}) {
  if (probe == null || !probe.hasVideo) {
    return const WebVideoSubtitleMedia.blocked(
      WebVideoSubtitleMediaBlock.noVideo,
    );
  }
  if (probe.encrypted) {
    return const WebVideoSubtitleMedia.blocked(
      WebVideoSubtitleMediaBlock.encrypted,
    );
  }
  final String? youtubeId = youtubeVideoIdOrNull(pageUrl);
  if (youtubeId != null) {
    return WebVideoSubtitleMedia.available(
      WebVideoSubtitleMediaKind.youtube,
      pageUrl,
      youtubeId: youtubeId,
    );
  }
  if (_isHttpUrl(probe.src)) {
    return WebVideoSubtitleMedia.available(_kindOf(probe.src), probe.src);
  }
  final String? hls = probe.manifests.firstWhereOrNull(
    (String m) => _kindOf(m) == WebVideoSubtitleMediaKind.hls,
  );
  if (hls != null) {
    return WebVideoSubtitleMedia.available(WebVideoSubtitleMediaKind.hls, hls);
  }
  final String? dash = probe.manifests.firstWhereOrNull(
    (String m) => _kindOf(m) == WebVideoSubtitleMediaKind.dash,
  );
  if (dash != null) {
    return WebVideoSubtitleMedia.available(
      WebVideoSubtitleMediaKind.dash,
      dash,
    );
  }
  return const WebVideoSubtitleMedia.blocked(
    WebVideoSubtitleMediaBlock.noMediaAddress,
  );
}

/// cookie 列表 → `Cookie` 请求头的值（`a=1; b=2`）；空名字跳过。
String webVideoCookieHeader(Iterable<(String, String)> cookies) => <String>[
  for (final (String name, String value) in cookies)
    if (name.isNotEmpty) '$name=$value',
].join('; ');

/// 在 app 外（ffmpeg）读站点媒体要带的请求头：页面自己的 UA、观看页作 Referer、WebView
/// cookie 罐里的 Cookie。空值不带。
Map<String, String> webVideoMediaRequestHeaders({
  required String userAgent,
  required String referer,
  required String cookie,
}) => <String, String>{
  if (userAgent.isNotEmpty) 'User-Agent': userAgent,
  if (referer.isNotEmpty) 'Referer': referer,
  if (cookie.isNotEmpty) 'Cookie': cookie,
};

/// 拿不到可拉的媒体（[reason] 见 [WebVideoSubtitleMediaBlock]）。
final class WebVideoSubtitleMediaBlocked implements Exception {
  const WebVideoSubtitleMediaBlocked(this.reason);

  final WebVideoSubtitleMediaBlock reason;

  @override
  String toString() => 'web video media blocked: ${reason.name}';
}

/// 问页面要媒体回执（生产 `session.evaluate('window.__fushiWebVideo.mediaSource()')`）。
typedef WebVideoMediaProbeReader = Future<Object?> Function();

/// [url] 的 `Cookie` 请求头（生产 `WebVideoSession.cookieHeaderFor`）。
typedef WebVideoCookieHeaderReader = Future<String> Function(String url);

/// 问页面并选好来源；拿不到时抛 [WebVideoSubtitleMediaBlocked]。
Future<(WebVideoSubtitleMedia, WebVideoMediaProbe)> _probeMedia(
  WebVideoMediaProbeReader probe,
  String pageUrl,
) async {
  final WebVideoMediaProbe? parsed = parseWebVideoMediaProbe(await probe());
  final WebVideoSubtitleMedia media = resolveWebVideoSubtitleMedia(
    parsed,
    pageUrl: pageUrl,
  );
  final WebVideoSubtitleMediaBlock? block = media.block;
  if (block != null || parsed == null) {
    throw WebVideoSubtitleMediaBlocked(
      block ?? WebVideoSubtitleMediaBlock.noVideo,
    );
  }
  return (media, parsed);
}

/// 开拉前现取这一集整集音频的输入（[VideoStreamSubtitleAudioInput]）：YouTube 现取 audio-only
/// 流并登记本机中继（[relay]，与粘贴的 YouTube 流同一条）；其它站点用页面给的直链 / 清单，
/// 带页面同一身份的请求头。拿不到时抛 [WebVideoSubtitleMediaBlocked]。
Future<VideoStreamSubtitleAudioInput> prepareWebVideoSubtitleAudio({
  required WebVideoMediaProbeReader probe,
  required String pageUrl,
  required WebVideoCookieHeaderReader cookieHeader,
  YoutubeAudioStreamResolver? youtubeAudio,
  YoutubeStreamRelay? relay,
}) async {
  final (WebVideoSubtitleMedia media, WebVideoMediaProbe parsed) =
      await _probeMedia(probe, pageUrl);
  final String? youtubeId = media.youtubeId;
  if (youtubeId != null) {
    final YoutubeAudioStream audio =
        await (youtubeAudio ?? resolveYoutubeAudioStream)(youtubeId);
    return VideoStreamSubtitleAudioInput(
      url: await (relay ?? relayYoutubeStreamUrl)(audio.url, audio.httpHeaders),
      headers: audio.httpHeaders,
    );
  }
  return VideoStreamSubtitleAudioInput(
    url: media.url,
    headers: webVideoMediaRequestHeaders(
      userAgent: parsed.userAgent,
      referer: pageUrl,
      cookie: await cookieHeader(media.url),
    ),
  );
}

/// AI 校对「参考画面」从哪条视频地址抽帧（带页面同一身份的请求头）；没有画面可抽（YouTube
/// 现取的是纯音频流）或拿不到媒体时 null。
Future<({String url, Map<String, String> headers})?>
webVideoSubtitleFrameInput({
  required WebVideoMediaProbeReader probe,
  required String pageUrl,
  required WebVideoCookieHeaderReader cookieHeader,
}) async {
  final WebVideoMediaProbe? parsed = parseWebVideoMediaProbe(await probe());
  final WebVideoSubtitleMedia media = resolveWebVideoSubtitleMedia(
    parsed,
    pageUrl: pageUrl,
  );
  if (parsed == null || !media.hasPicture) return null;
  return (
    url: media.url,
    headers: webVideoMediaRequestHeaders(
      userAgent: parsed.userAgent,
      referer: pageUrl,
      cookie: await cookieHeader(media.url),
    ),
  );
}
