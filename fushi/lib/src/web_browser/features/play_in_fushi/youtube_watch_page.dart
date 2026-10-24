/// 浏览器里的 YouTube「观看页」判定（「用 Fushi 播放」与 YouTube 字幕查词共用）。
///
/// 纯函数、不联网。只认**一条视频**的页面：首页 / 搜索 / 频道 / 播放列表总览
/// （`/playlist?list=`）都不是观看页，动作不出现。
library;

/// YouTube 视频 id 的形状（11 位 `[A-Za-z0-9_-]`）。
final RegExp _kYoutubeVideoIdShape = RegExp(r'^[A-Za-z0-9_-]{11}$');

/// 观看页所在的主机（去掉 `www.` 前缀、转小写后比较）。
const Set<String> kYoutubeWatchHosts = <String>{
  'youtube.com',
  'm.youtube.com',
  'music.youtube.com',
};

/// 路径形式的观看页前缀：`/shorts/<id>`、`/live/<id>`、`/embed/<id>`。
const Set<String> kYoutubeWatchPathPrefixes = <String>{
  'shorts',
  'live',
  'embed',
};

String _normalizedHost(Uri uri) {
  String host = uri.host.toLowerCase();
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  if (host.startsWith('www.')) host = host.substring(4);
  return host;
}

String? _idOrNull(String? raw) {
  if (raw == null) return null;
  final String id = raw.trim();
  return _kYoutubeVideoIdShape.hasMatch(id) ? id : null;
}

/// [uri] 是 YouTube 某一条视频的观看页时返回它的 11 位 videoId，否则 null。
///
/// 认：`youtube.com/watch?v=`（含 `www.` / `m.` / `music.`）、`/shorts/<id>`、
/// `/live/<id>`、`/embed/<id>`、`youtu.be/<id>`、`youtube-nocookie.com/embed/<id>`。
/// 只认 http(s)。
String? youtubeWatchVideoIdOf(Uri? uri) {
  if (uri == null) return null;
  final String scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  final String host = _normalizedHost(uri);
  final List<String> segments = <String>[
    for (final String s in uri.pathSegments)
      if (s.isNotEmpty) s,
  ];
  if (host == 'youtu.be') {
    return segments.isEmpty ? null : _idOrNull(segments.first);
  }
  if (host == 'youtube-nocookie.com') {
    return segments.length >= 2 && segments.first == 'embed'
        ? _idOrNull(segments[1])
        : null;
  }
  if (!kYoutubeWatchHosts.contains(host)) return null;
  if (segments.length == 1 && segments.first == 'watch') {
    return _idOrNull(uri.queryParameters['v']);
  }
  if (segments.length >= 2 &&
      kYoutubeWatchPathPrefixes.contains(segments.first)) {
    return _idOrNull(segments[1]);
  }
  return null;
}

/// 规范化的观看页地址（`https://www.youtube.com/watch?v=<id>`）：同一视频的任意
/// 写法（短链 / shorts / 手机版 / 带 `&t=` `&list=` 追踪参数）收敛到同一个地址，
/// 交给播放器解析、也作为落库身份（`streamVideoBookUid`）。
String youtubeCanonicalWatchUrl(String videoId) =>
    'https://www.youtube.com/watch?v=$videoId';

/// [uri] 是不是视频站的「观看页」（一条视频在播的页面）。网页漫画「阅读本章」、网页
/// 小说「阅读（小说）」这类按正文 / 图片抽内容的动作在观看页上没有意义，据此不出现。
/// 目前只认 YouTube（[youtubeWatchVideoIdOf]）；别的视频站有观看页判据时加在这里。
bool isWebBrowserVideoWatchPage(Uri? uri) => youtubeWatchVideoIdOf(uri) != null;
