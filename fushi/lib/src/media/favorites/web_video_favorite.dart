// 反馈 KGC1ifR1a3：浏览器扩展看网页视频时，用 App 本体的「收藏」收藏当前句 / 视频本身。
//
// 数据就是 App 收藏夹那一份：收藏句存进 [FavoriteSentenceRepository]（与视频页 / 阅读器
// 的收藏句同一个偏好键、同一套同步与删除墓碑），来源标 [kFavoriteSentenceSourceWeb]。
// 本文件是纯 Dart（URL 规范化 / 跳回地址生成 / 扩展请求体解析 / 读写收藏），不碰 UI：
//   · 扩展 → `/api/extension/video-favorite`（fushi_api_server.dart）→ [handleExtensionVideoFavorite]
//   · 收藏夹「打开网页」→ [webVideoJumpTarget]
//
// 身份口径：bookKey = [canonicalWebVideoUrl]（去掉时间参数 / 追踪参数 / 片段），所以同一个
// 视频从「带 t= 的分享链接」与「直接打开」进来是同一条；句子再加 cue 文本 + 起点毫秒。
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';

/// 跳回地址知道怎么带时间点的站点；其余一律 [other]（只打开原网页）。
enum WebVideoSite { youtube, niconico, bilibili, netflix, other }

/// 收藏的是哪种东西：当前字幕句 / 视频本身。
enum WebVideoFavoriteKind { sentence, video }

String _host(Uri uri) => uri.host.toLowerCase();

bool _hostIs(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

/// 站点判定（只看域名）。
WebVideoSite webVideoSiteOf(Uri uri) {
  final String host = _host(uri);
  if (_hostIs(host, 'youtube.com') || host == 'youtu.be') {
    return WebVideoSite.youtube;
  }
  if (_hostIs(host, 'nicovideo.jp') || host == 'nico.ms') {
    return WebVideoSite.niconico;
  }
  if (_hostIs(host, 'bilibili.com') || host == 'b23.tv') {
    return WebVideoSite.bilibili;
  }
  if (_hostIs(host, 'netflix.com')) return WebVideoSite.netflix;
  return WebVideoSite.other;
}

/// 收藏夹里标明的「来源网站」：认得的站点用品牌名，其余用去掉 `www.` 的域名。
String webVideoSiteLabel(Uri uri) => switch (webVideoSiteOf(uri)) {
  WebVideoSite.youtube => 'YouTube',
  WebVideoSite.niconico => 'niconico',
  WebVideoSite.bilibili => 'bilibili',
  WebVideoSite.netflix => 'Netflix',
  WebVideoSite.other =>
    _host(uri).startsWith('www.') ? _host(uri).substring(4) : _host(uri),
};

/// 通用站点上表示「从第几秒开始」的查询参数——规范化时去掉（身份不含时间点）。
const Set<String> _kTimeParams = <String>{
  't',
  'start',
  'time_continue',
  'from',
};

/// 只接受 http / https 网页地址；其余（chrome-extension://、file://、空串、乱码）返回 null。
Uri? _parseWebUrl(String raw) {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return uri;
}

/// 网页视频的规范地址（收藏身份）。null = 不是可收藏的网页地址。
///
/// - YouTube：`youtu.be/<id>`、`m.` / `music.` 子域、`/watch?v=<id>&t=…&list=…` 一律归成
///   `https://www.youtube.com/watch?v=<id>`；`/shorts/<id>` 保留 shorts 形态。
/// - niconico：`nico.ms/<id>`、`sp.` 子域归成 `https://www.nicovideo.jp/watch/<id>`，去掉查询。
/// - bilibili：`/video/<BV号>` 只保留分 P 参数 `p`。
/// - Netflix：`/watch/<id>` 去掉全部查询（trackId / tctx / t 都是会话噪声）。
/// - 其余站点：去掉片段与时间参数（t / start / time_continue / from），其余查询原样保留
///   （不知道哪个参数是视频身份，宁可多留）。
String? canonicalWebVideoUrl(String raw) {
  final Uri? uri = _parseWebUrl(raw);
  if (uri == null) return null;
  final String host = _host(uri);
  final List<String> segs = uri.pathSegments
      .where((String s) => s.isNotEmpty)
      .toList(growable: false);
  switch (webVideoSiteOf(uri)) {
    case WebVideoSite.youtube:
      String? id;
      if (host == 'youtu.be' && segs.isNotEmpty) {
        id = segs.first;
      } else if (segs.length >= 2 && segs.first == 'shorts') {
        return 'https://www.youtube.com/shorts/${segs[1]}';
      } else if (segs.length >= 2 &&
          (segs.first == 'live' || segs.first == 'embed')) {
        id = segs[1];
      } else {
        id = uri.queryParameters['v'];
      }
      if (id != null && id.isNotEmpty) {
        return Uri.https('www.youtube.com', '/watch', <String, String>{
          'v': id,
        }).toString();
      }
    case WebVideoSite.niconico:
      if (host == 'nico.ms' && segs.isNotEmpty) {
        return 'https://www.nicovideo.jp/watch/${segs.first}';
      }
      final int watch = segs.indexOf('watch');
      if (watch >= 0 && watch + 1 < segs.length) {
        return 'https://www.nicovideo.jp/watch/${segs[watch + 1]}';
      }
    case WebVideoSite.bilibili:
      final int video = segs.indexOf('video');
      if (video >= 0 && video + 1 < segs.length) {
        final String? part = uri.queryParameters['p'];
        return Uri.https(
          'www.bilibili.com',
          '/video/${segs[video + 1]}',
          part == null || part.isEmpty || part == '1'
              ? null
              : <String, String>{'p': part},
        ).toString();
      }
    case WebVideoSite.netflix:
      final int watch = segs.indexOf('watch');
      if (watch >= 0 && watch + 1 < segs.length) {
        return 'https://www.netflix.com/watch/${segs[watch + 1]}';
      }
    case WebVideoSite.other:
      break;
  }
  final Map<String, List<String>> query = <String, List<String>>{
    for (final MapEntry<String, List<String>> e
        in uri.queryParametersAll.entries)
      if (!_kTimeParams.contains(e.key)) e.key: e.value,
  };
  return Uri(
    scheme: uri.scheme,
    host: host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    queryParameters: query.isEmpty ? null : query,
  ).toString();
}

/// 收藏夹「打开网页」的目标地址。[timed] = 地址本身会让站点从 [positionMs] 起播；
/// false 且 [positionMs] 非空时，调用方要告诉用户「这个站点不能按时间点打开」并把时间
/// 点说出来（用户自己拖）。
class WebVideoJumpTarget {
  const WebVideoJumpTarget({required this.uri, required this.timed});

  final Uri uri;
  final bool timed;
}

/// 按站点生成带时间点的地址：YouTube `t=<秒>s`、niconico `from=<秒>`、bilibili
/// `t=<秒>`。Netflix 与其它站点没有公开、稳定的时间参数 → 只打开原网页（timed=false）。
/// [positionMs] 为 null（收藏的是视频本身）→ 原网页、timed=false。[url] 不是网页地址时
/// 返回 null。
WebVideoJumpTarget? webVideoJumpTarget(String url, int? positionMs) {
  final String? canonical = canonicalWebVideoUrl(url);
  if (canonical == null) return null;
  final Uri uri = Uri.parse(canonical);
  if (positionMs == null || positionMs < 0) {
    return WebVideoJumpTarget(uri: uri, timed: false);
  }
  final int seconds = positionMs ~/ 1000;
  Uri withParam(String key, String value) => uri.replace(
    queryParameters: <String, String>{...uri.queryParameters, key: value},
  );
  return switch (webVideoSiteOf(uri)) {
    // shorts 不认 t=。
    WebVideoSite.youtube when uri.path == '/watch' => WebVideoJumpTarget(
      uri: withParam('t', '${seconds}s'),
      timed: true,
    ),
    WebVideoSite.niconico => WebVideoJumpTarget(
      uri: withParam('from', '$seconds'),
      timed: true,
    ),
    WebVideoSite.bilibili => WebVideoJumpTarget(
      uri: withParam('t', '$seconds'),
      timed: true,
    ),
    _ => WebVideoJumpTarget(uri: uri, timed: false),
  };
}

/// 时间点的人话格式（`m:ss` / `h:mm:ss`），收藏夹副标题与「不能按时间点打开」提示共用。
String formatWebVideoPosition(int positionMs) {
  final int total = positionMs < 0 ? 0 : positionMs ~/ 1000;
  final int h = total ~/ 3600;
  final int m = (total % 3600) ~/ 60;
  final int s = total % 60;
  final String ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// 网页标题去掉站点后缀与 YouTube 的未读数前缀（`(3) 标题 - YouTube` → `标题`）。
String cleanWebVideoTitle(String title, WebVideoSite site) {
  String out = title.trim().replaceFirst(RegExp(r'^\(\d+\+?\)\s*'), '');
  final List<String> suffixes = switch (site) {
    WebVideoSite.youtube => const <String>[' - YouTube'],
    WebVideoSite.niconico => const <String>[
      ' - ニコニコ動画',
      ' - niconico',
      ' - ニコニコ',
    ],
    WebVideoSite.bilibili => const <String>['_哔哩哔哩_bilibili'],
    WebVideoSite.netflix => const <String>[' | Netflix', ' - Netflix'],
    WebVideoSite.other => const <String>[],
  };
  for (final String suffix in suffixes) {
    if (out.endsWith(suffix)) {
      out = out.substring(0, out.length - suffix.length).trim();
      break;
    }
  }
  return out;
}

/// 扩展请求体（POST `/api/extension/video-favorite`）：
/// `{op: 'toggle'|'state', kind: 'sentence'|'video', url, title?, text?, startMs?, endMs?}`。
class ExtensionVideoFavoriteRequest {
  const ExtensionVideoFavoriteRequest({
    required this.toggle,
    required this.kind,
    required this.url,
    this.title = '',
    this.text = '',
    this.startMs,
    this.endMs,
  });

  /// true = 切换收藏，false = 只读这个视频的收藏状态。
  final bool toggle;
  final WebVideoFavoriteKind kind;

  /// 规范化后的网页地址（[canonicalWebVideoUrl]），即收藏身份。
  final String url;
  final String title;
  final String text;
  final int? startMs;
  final int? endMs;

  /// 体不合契约返回 null：地址不是网页、op 未知、切换句子收藏却没有句子文本。
  static ExtensionVideoFavoriteRequest? tryParse(Map<String, dynamic> body) {
    final Object? rawUrl = body['url'];
    if (rawUrl is! String) return null;
    final String? url = canonicalWebVideoUrl(rawUrl);
    if (url == null) return null;
    final Object? op = body['op'];
    final bool toggle;
    if (op == 'toggle') {
      toggle = true;
    } else if (op == null || op == 'state') {
      toggle = false;
    } else {
      return null;
    }
    final WebVideoFavoriteKind kind = body['kind'] == 'video'
        ? WebVideoFavoriteKind.video
        : WebVideoFavoriteKind.sentence;
    final Object? text = body['text'];
    final String sentence = text is String ? text.trim() : '';
    if (toggle && kind == WebVideoFavoriteKind.sentence && sentence.isEmpty) {
      return null;
    }
    int? ms(Object? v) => v is num && v.isFinite && v >= 0 ? v.round() : null;
    final Object? title = body['title'];
    return ExtensionVideoFavoriteRequest(
      toggle: toggle,
      kind: kind,
      url: url,
      title: title is String
          ? cleanWebVideoTitle(title, webVideoSiteOf(Uri.parse(url)))
          : '',
      text: kind == WebVideoFavoriteKind.sentence ? sentence : '',
      startMs: kind == WebVideoFavoriteKind.sentence
          ? ms(body['startMs'])
          : null,
      endMs: kind == WebVideoFavoriteKind.sentence ? ms(body['endMs']) : null,
    );
  }
}

/// 一句已收藏的字幕（回给扩展画 ★）。
class WebVideoFavoritedLine {
  const WebVideoFavoritedLine({required this.text, required this.startMs});

  final String text;
  final int? startMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    'startMs': startMs,
  };
}

/// 这个视频在收藏夹里的状态。[favorite] 只在切换时有值（切换后的状态）。
class ExtensionVideoFavoriteState {
  const ExtensionVideoFavoriteState({
    required this.video,
    required this.sentences,
    this.favorite,
  });

  final bool? favorite;
  final bool video;
  final List<WebVideoFavoritedLine> sentences;

  Map<String, Object?> toJson() => <String, Object?>{
    if (favorite != null) 'favorite': favorite,
    'video': video,
    'sentences': <Map<String, Object?>>[
      for (final WebVideoFavoritedLine line in sentences) line.toJson(),
    ],
  };
}

/// 扩展网页视频收藏的 app 侧实现（[handleExtensionVideoFavorite] 绑好仓库后的形状）。
typedef ExtensionVideoFavoriteHandler =
    Future<ExtensionVideoFavoriteState> Function(
      ExtensionVideoFavoriteRequest request,
    );

/// 读写收藏夹（扩展端点的 app 侧实现）。切换：已收藏 → 删（写删除墓碑，跨设备同步删除），
/// 未收藏 → 加（今日 dateKey 计入视频统计）；只读：回这个视频的状态。
Future<ExtensionVideoFavoriteState> handleExtensionVideoFavorite({
  required FavoriteSentenceRepository repository,
  required ExtensionVideoFavoriteRequest request,
  DateTime? now,
}) async {
  bool? favorite;
  if (request.toggle) {
    final bool isVideo = request.kind == WebVideoFavoriteKind.video;
    final String? existing = await repository.matchedFavoriteId(
      text: request.text,
      bookKey: request.url,
      sectionIndex: null,
      normCharOffset: isVideo ? null : request.startMs,
    );
    if (existing != null) {
      await repository.removeById(existing);
      favorite = false;
    } else {
      final DateTime at = now ?? DateTime.now();
      final int? start = request.startMs;
      final int? end = request.endMs;
      await repository.add(
        FavoriteSentence(
          text: request.text,
          bookTitle: request.title.isNotEmpty ? request.title : request.url,
          chapterLabel: webVideoSiteLabel(Uri.parse(request.url)),
          createdAt: at,
          bookKey: request.url,
          normCharOffset: isVideo ? null : start,
          normCharLength:
              !isVideo && start != null && end != null && end > start
              ? end - start
              : null,
          source: kFavoriteSentenceSourceWeb,
          dateKey: FushiDatabase.statDateKeyOf(at),
        ),
      );
      favorite = true;
    }
  }
  bool video = false;
  final List<WebVideoFavoritedLine> lines = <WebVideoFavoritedLine>[];
  for (final FavoriteSentence s in await repository.getAll()) {
    if (s.source != kFavoriteSentenceSourceWeb || s.bookKey != request.url) {
      continue;
    }
    if (s.text.isEmpty) {
      video = true;
    } else {
      lines.add(WebVideoFavoritedLine(text: s.text, startMs: s.normCharOffset));
    }
  }
  return ExtensionVideoFavoriteState(
    favorite: favorite,
    video: video,
    sentences: lines,
  );
}
