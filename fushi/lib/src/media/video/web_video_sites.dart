// 视频库「在线源 › 网站」：Netflix / YouTube 这类网页视频站的入口。
//
// 站点本身不是一本书：点入口就在原生播放器页的网页档里打开站点（选人 / 选剧 / 选集都是
// 站点自己的页面），不落库。真正播起某一集（进播放器档）时，这一集才按规范化的播放页
// 地址落成一本普通流媒体书（[ensureWebVideoEpisodeBook]）——继续观看、进度、制卡、观看
// 统计都按集记，不会全堆在一本「Netflix」上。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart'
    show youtubeVideoIdOrNull;

import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';

/// 用户自己加的网站（JSON 数组，`[{title, url}]`）。预置站点不存这里。
const String kWebVideoSitesPrefKey = 'video_web_sites';

/// 站点入口的伪书 id 前缀：只活在打开的页面里（[webVideoSiteRow]），从不写库。
const String kWebVideoSiteBookUidPrefix = 'video/site/';

@immutable
class WebVideoSite {
  const WebVideoSite({required this.title, required this.url});

  final String title;
  final String url;

  Map<String, String> toJson() => <String, String>{'title': title, 'url': url};

  @override
  bool operator ==(Object other) =>
      other is WebVideoSite && other.title == title && other.url == url;

  @override
  int get hashCode => Object.hash(title, url);
}

/// 预置站点（不可删）。
const List<WebVideoSite> kWebVideoPresetSites = <WebVideoSite>[
  WebVideoSite(title: 'Netflix', url: 'https://www.netflix.com/browse'),
  WebVideoSite(title: 'YouTube', url: 'https://www.youtube.com/'),
];

/// 「网站」分区在不在：网页档只在 Windows 上有（站点自己的播放器 + WebView2）。
bool webVideoSitesAvailable({TargetPlatform? platform}) =>
    shouldOpenInWebVideoPlayer(
      kWebVideoPresetSites.first.url,
      platform: platform,
    );

/// 偏好里的自加站点；坏数据逐条跳过。
List<WebVideoSite> decodeWebVideoSites(Object? raw) {
  if (raw is! String || raw.isEmpty) return const <WebVideoSite>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <WebVideoSite>[];
  }
  if (decoded is! List) return const <WebVideoSite>[];
  return <WebVideoSite>[
    for (final Object? e in decoded)
      if (e is Map &&
          e['url'] is String &&
          isPlayableStreamUrl(e['url'] as String))
        WebVideoSite(
          title: e['title'] is String && (e['title'] as String).isNotEmpty
              ? e['title'] as String
              : webVideoSiteDefaultTitle(e['url'] as String),
          url: e['url'] as String,
        ),
  ];
}

String encodeWebVideoSites(List<WebVideoSite> sites) =>
    jsonEncode(<Object>[for (final WebVideoSite s in sites) s.toJson()]);

/// 地址栏里随手输的地址：补 `https://`，不是 http(s) / 没有 host 返回 null。
String? normalizeWebVideoSiteInput(String input) {
  String s = input.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'https://$s';
  final Uri? uri = Uri.tryParse(s);
  if (uri == null || !isPlayableStreamUrl(s)) return null;
  return uri.toString();
}

/// 没给名字时的站名：去掉 `www.` 的 host。
String webVideoSiteDefaultTitle(String url) {
  final String host = Uri.tryParse(url)?.host ?? url;
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// 站点入口在页面里用的伪书（不写库；见文件头）。
VideoBookRow webVideoSiteRow(WebVideoSite site) => VideoBookRow(
  bookUid:
      '$kWebVideoSiteBookUidPrefix${Uri.tryParse(site.url)?.host ?? site.url}',
  title: site.title,
  videoPath: site.url,
  lastPositionMs: 0,
  currentEpisode: 0,
  delayMs: 0,
);

bool isWebVideoSiteBookUid(String bookUid) =>
    bookUid.startsWith(kWebVideoSiteBookUidPrefix);

/// 某一集的规范地址（落库身份）：Netflix `https://www.netflix.com/watch/<id>`（去掉
/// trackId 之类的跟踪参数），YouTube `https://www.youtube.com/watch?v=<id>`（与导入同一
/// 身份 `video/stream/yt:<id>`），其它站点去掉 `#` 片段。不是 http(s) 返回 null。
String? webVideoEpisodeUrl(String href) {
  final Uri? uri = Uri.tryParse(href);
  if (uri == null || !isPlayableStreamUrl(href)) return null;
  final String host = uri.host.toLowerCase();
  bool on(String domain) => host == domain || host.endsWith('.$domain');
  if (on('netflix.com')) {
    final RegExpMatch? m = RegExp(r'^/watch/(\d+)').firstMatch(uri.path);
    if (m != null) return 'https://www.netflix.com/watch/${m.group(1)}';
  }
  if (on('youtube.com') || on('youtu.be')) {
    final String? id = youtubeVideoIdOrNull(href);
    if (id != null && id.isNotEmpty) {
      return 'https://www.youtube.com/watch?v=$id';
    }
  }
  return uri.removeFragment().toString();
}

/// 页面标题去掉站名后缀（「… - YouTube」）；站点只给站名（Netflix 播放页的
/// `document.title` 就是「Netflix」）时退回「站名 · 集 id」。
String webVideoEpisodeTitle({
  required String pageTitle,
  required String episodeUrl,
  required String siteTitle,
}) {
  String title = pageTitle.trim();
  for (final String suffix in <String>[' - YouTube', ' | Netflix']) {
    if (title.endsWith(suffix)) {
      title = title.substring(0, title.length - suffix.length).trim();
    }
  }
  final Uri? uri = Uri.tryParse(episodeUrl);
  final String host = webVideoSiteDefaultTitle(episodeUrl);
  if (title.isEmpty ||
      title.toLowerCase() == host.split('.').first.toLowerCase() ||
      title == siteTitle) {
    final String id = uri == null
        ? ''
        : (uri.queryParameters['v'] ??
              (uri.pathSegments.isEmpty ? '' : uri.pathSegments.last));
    return id.isEmpty ? siteTitle : '$siteTitle · $id';
  }
  return title;
}

/// 这一集的书：已有（导入过 / 看过）原样返回；没有就落一本普通流媒体书（与导入对话框
/// 同一身份 [streamVideoBookUid]、同一列），记一条「添加」活动。
Future<VideoBookRow?> ensureWebVideoEpisodeBook(
  VideoBookRepository repo, {
  required String episodeUrl,
  required String title,
}) async {
  final String bookUid = streamVideoBookUid(episodeUrl);
  final VideoBookRow? existing = await repo.getByBookUid(bookUid);
  if (existing != null) return existing;
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(title),
      videoPath: Value(episodeUrl),
      streamSpecJson: Value<String?>(const StreamVideoSpec().toStorageJson()),
      importedAt: Value(DateTime.now().millisecondsSinceEpoch),
    ),
  );
  await repo.recordVideoImportActivity(bookUid: bookUid, title: title);
  return repo.getByBookUid(bookUid);
}
