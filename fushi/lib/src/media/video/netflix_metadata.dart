// Netflix 网站 metadata 接口（shakti `/nq/website/memberapi/<build>/metadata?movieid=<id>`）的
// 解析：剧集列表（季 / 集号 / 集名 / 剧照）、片头片尾标记。纯函数、无平台依赖——页面 glue 只负责
// 在站点页面里同源带 cookie 取回原文（web_video_glue.js 的 fetchNetflixMetadata）。
//
// 接口是 Netflix 网站自己用的、没有公开契约：字段缺失一律按「没有」处理，整份解析不出来回 null，
// 调用方退回 DOM / og 信息（不抛）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/video/video_player_controller.dart'
    show VideoChapter;
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi_engine/utils/net/app_http.dart' show createAppHttpClient;

/// 一集。
@immutable
class NetflixEpisode {
  const NetflixEpisode({
    required this.id,
    required this.seasonSeq,
    required this.seq,
    required this.title,
    this.seasonTitle = '',
    this.stillUrl = '',
    this.markers = const NetflixSkipMarkers(),
  });

  /// 播放页 `/watch/<id>` 的 id。
  final String id;
  final int seasonSeq;
  final int seq;
  final String title;
  final String seasonTitle;

  /// 剧照（集封面）；没有为空。
  final String stillUrl;
  final NetflixSkipMarkers markers;

  String get watchUrl => 'https://www.netflix.com/watch/$id';
}

/// 片头 / 前情回顾 / 片尾标记（毫秒；没有为 null）。
@immutable
class NetflixSkipMarkers {
  const NetflixSkipMarkers({
    this.recapStartMs,
    this.recapEndMs,
    this.introStartMs,
    this.introEndMs,
    this.creditsStartMs,
  });

  final int? recapStartMs;
  final int? recapEndMs;
  final int? introStartMs;
  final int? introEndMs;
  final int? creditsStartMs;

  bool get isEmpty =>
      recapEndMs == null && introEndMs == null && creditsStartMs == null;
}

/// 一部作品（剧集或电影）的 metadata。
@immutable
class NetflixTitleMetadata {
  const NetflixTitleMetadata({
    required this.id,
    required this.title,
    required this.isShow,
    required this.episodes,
    this.coverUrl = '',
    this.movieMarkers = const NetflixSkipMarkers(),
  });

  /// 作品 id（剧集是 show id，电影就是播放 id）。
  final String id;
  final String title;
  final bool isShow;

  /// 全部集，按季序、集序排好；电影为空。
  final List<NetflixEpisode> episodes;

  /// 作品封面（boxart / artwork 里最大的一张）；没有为空。
  final String coverUrl;

  /// 电影的标记（剧集的标记在每一集上）。
  final NetflixSkipMarkers movieMarkers;

  /// 播放 id 为 [watchId] 的那一集在 [episodes] 里的下标；不在为 -1。
  int indexOfEpisode(String watchId) =>
      episodes.indexWhere((NetflixEpisode e) => e.id == watchId);

  /// [watchId] 这一集（或电影本身）的标记。
  NetflixSkipMarkers markersFor(String watchId) {
    final int i = indexOfEpisode(watchId);
    return i >= 0 ? episodes[i].markers : movieMarkers;
  }

  /// 落库书名：剧集「作品 · S1E2 集名」，电影就是片名。
  String displayTitleFor(String watchId) {
    final int i = indexOfEpisode(watchId);
    if (i < 0) return title;
    final NetflixEpisode e = episodes[i];
    final String code = 'S${e.seasonSeq}E${e.seq}';
    final String episodeTitle = e.title.isEmpty ? code : '$code ${e.title}';
    return title.isEmpty ? episodeTitle : '$title · $episodeTitle';
  }

  /// [watchId] 这一集的封面：剧照优先，退回作品封面。
  String coverFor(String watchId) {
    final int i = indexOfEpisode(watchId);
    if (i >= 0 && episodes[i].stillUrl.isNotEmpty) return episodes[i].stillUrl;
    return coverUrl;
  }
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v);
  return null;
}

String _str(Object? v) => v == null ? '' : v.toString().trim();

/// 图片数组（`[{url, w, h}]`）里面积最大的一张；没有为空。
String _largestImage(Object? raw) {
  if (raw is! List) return '';
  String best = '';
  int bestArea = -1;
  for (final Object? item in raw) {
    if (item is! Map) continue;
    final String url = _str(item['url']);
    if (url.isEmpty) continue;
    final int area = (_int(item['w']) ?? 0) * (_int(item['h']) ?? 0);
    if (area > bestArea) {
      best = url;
      bestArea = area;
    }
  }
  return best;
}

/// `{start, end}`（毫秒）：end > start 才算有。
(int, int)? _span(Object? raw) {
  if (raw is! Map) return null;
  final int? start = _int(raw['start']);
  final int? end = _int(raw['end']);
  if (start == null || end == null || end <= start || start < 0) return null;
  return (start, end);
}

NetflixSkipMarkers _markersOf(Map<dynamic, dynamic> node) {
  final Object? skip = node['skipMarkers'];
  final (int, int)? recap = skip is Map ? _span(skip['recap']) : null;
  final (int, int)? intro = skip is Map ? _span(skip['credit']) : null;
  // creditsOffset 是秒；runtime 也是秒：片尾起点必须落在片长之内才算。
  final int? creditsSec = _int(node['creditsOffset']);
  final int? runtimeSec = _int(node['runtime']);
  final bool creditsValid =
      creditsSec != null &&
      creditsSec > 0 &&
      (runtimeSec == null || creditsSec < runtimeSec);
  return NetflixSkipMarkers(
    recapStartMs: recap?.$1,
    recapEndMs: recap?.$2,
    introStartMs: intro?.$1,
    introEndMs: intro?.$2,
    creditsStartMs: creditsValid ? creditsSec * 1000 : null,
  );
}

/// 解析 metadata 原文；不是这个接口的形状回 null。
NetflixTitleMetadata? parseNetflixMetadata(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final Object? video = decoded['video'];
  if (video is! Map) return null;
  final String id = _str(video['id']);
  if (id.isEmpty) return null;
  final bool isShow = _str(video['type']).toLowerCase() == 'show';
  final List<NetflixEpisode> episodes = <NetflixEpisode>[];
  final Object? seasons = video['seasons'];
  if (isShow && seasons is List) {
    for (final Object? season in seasons) {
      if (season is! Map) continue;
      final int seasonSeq = _int(season['seq']) ?? 0;
      final String seasonTitle = _str(season['title']);
      final Object? eps = season['episodes'];
      if (eps is! List) continue;
      for (final Object? ep in eps) {
        if (ep is! Map) continue;
        final String epId = _str(ep['episodeId'] ?? ep['id']);
        if (epId.isEmpty) continue;
        final String still = _largestImage(ep['stills']);
        episodes.add(
          NetflixEpisode(
            id: epId,
            seasonSeq: seasonSeq,
            seq: _int(ep['seq']) ?? 0,
            title: _str(ep['title']),
            seasonTitle: seasonTitle,
            stillUrl: still.isNotEmpty ? still : _largestImage(ep['thumbs']),
            markers: _markersOf(ep),
          ),
        );
      }
    }
    episodes.sort((NetflixEpisode a, NetflixEpisode b) {
      final int s = a.seasonSeq.compareTo(b.seasonSeq);
      return s != 0 ? s : a.seq.compareTo(b.seq);
    });
  }
  final String boxart = _largestImage(video['boxart']);
  return NetflixTitleMetadata(
    id: id,
    title: _str(video['title']),
    isShow: isShow,
    episodes: List<NetflixEpisode>.unmodifiable(episodes),
    coverUrl: boxart.isNotEmpty ? boxart : _largestImage(video['artwork']),
    movieMarkers: isShow ? const NetflixSkipMarkers() : _markersOf(video),
  );
}

/// 章节名（页面传 i18n 文案）。
@immutable
class NetflixChapterLabels {
  const NetflixChapterLabels({
    required this.recap,
    required this.intro,
    required this.main,
    required this.credits,
  });

  final String recap;
  final String intro;
  final String main;
  final String credits;
}

/// 片头片尾标记 → 章节（前情回顾 / 片头 / 正片 / 片尾）。没有任何标记回空（不造一个只有「正片」
/// 的单章节）。[durationMs] 已知时丢掉越过片长的点。
List<VideoChapter> netflixChaptersFromMarkers(
  NetflixSkipMarkers markers,
  NetflixChapterLabels labels, {
  int? durationMs,
}) {
  if (markers.isEmpty) return const <VideoChapter>[];
  // 起点 → 名字；同一起点后写的覆盖先写的（「片头」盖过「正片」）。
  final Map<int, String> points = <int, String>{0: labels.main};
  void at(int? ms, String label) {
    if (ms == null || ms < 0) return;
    if (durationMs != null && durationMs > 0 && ms >= durationMs) return;
    points[ms] = label;
  }

  at(markers.recapEndMs, labels.main);
  at(markers.introEndMs, labels.main);
  at(markers.recapStartMs, labels.recap);
  at(markers.introStartMs, labels.intro);
  at(markers.creditsStartMs, labels.credits);
  final List<int> starts = points.keys.toList()..sort();
  final List<VideoChapter> out = <VideoChapter>[];
  for (final int start in starts) {
    final String title = points[start]!;
    if (out.isNotEmpty && out.last.title == title) continue;
    out.add(
      VideoChapter(
        index: out.length,
        title: title,
        start: Duration(milliseconds: start),
      ),
    );
  }
  return out.length < 2 ? const <VideoChapter>[] : out;
}

/// 站点剧照（Netflix 的公开图片 CDN）取图器：剧集面板的远端封面经它下载（走全应用代理装配），
/// 磁盘缓存按站点分命名空间。
class WebVideoCoverFetcher implements RemoteCoverFetcher {
  const WebVideoCoverFetcher();

  @override
  String get coverCacheNamespace => 'web_video_site';

  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) async {
    final HttpClient client = createAppHttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(
        Uri.parse(coverUrl),
      );
      final HttpClientResponse response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: request.uri);
      }
      final BytesBuilder bytes = BytesBuilder(copy: false);
      await response.forEach(bytes.add);
      return bytes.takeBytes();
    } finally {
      client.close();
    }
  }
}
