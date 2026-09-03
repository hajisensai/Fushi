/// bilibili.com（大陆站）的「一句片段制卡」流解析层。与 `YoutubeClipMiner` 同形状、同分工：
/// 把 `{视频身份, 视频时间窗}` 解析成喂给 [ImmersionMiningEngine] 的 ffmpeg 输入。
///
/// **为什么是这条路而不是录屏**：B 站不是 DRM 站点，DASH 分离音轨可以直接按时间窗裁，
/// 拿到的是**原始音轨字节**（实测 `mp4a.40.2` / 48kHz / 立体声），不是对扬声器或标签页的
/// 录音。画面那一半由扩展在页面里取当前解码帧提供（`frame-capture.js`），同样是原始像素而
/// 非截屏。两半合起来，这条链上没有任何一处经过「录」。
///
/// 与 YouTube 那条的两点差异（都已实测，不是推测）：
///   · **不需要 Referer**：mcdn/upos 直链对 ffmpeg 直接放行，带不带 Referer 都成功（各跑
///     两次，产出逐字节一致）。曾经出现的 `-138` 是瞬时 connect 超时，被既有的
///     `-reconnect_on_network_error` 兜住，与鉴权无关。
///   · **不需要 range 物化**：googlevideo 那套 `range=` 查询参数分片是为绕开它的 SABR 限速，
///     B 站没有这个限速，ffmpeg 对 URL 直接 `-ss/-t` 稳定出片（3 秒片段约 1 秒）。见
///     `audioSourceNeedsRangeMaterialization`。
///
/// 只解析**音轨**：封面已由扩展的原始解码帧给出，服务端不必再去碰视频轨——那既省一次解析，
/// 也避开「未登录只能拿到 480P 视频轨」这个限制（音轨码率与清晰度档无关，未登录同样拿得到
/// 最高档音轨）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

/// 一个视频分 P 的身份：切片要用的 `cid` 与用来当 Anki 视频名的标题。
class BilibiliVideoIdentity {
  const BilibiliVideoIdentity({
    required this.cid,
    required this.title,
    this.partTitle,
    this.durationSec,
  });

  /// 分 P 的 cid（playurl 必需）。
  final int cid;

  /// 稿件标题。
  final String title;

  /// 分 P 标题（单 P 稿件通常与 [title] 重复或为空）。
  final String? partTitle;

  /// 分 P 时长（秒），可能缺失。
  final int? durationSec;

  /// Anki「视频名」字段用的显示名：多 P 稿件带上分 P 名，单 P 只用稿件名。
  String get displayTitle {
    final String p = (partTitle ?? '').trim();
    if (p.isEmpty || p == title.trim()) return title;
    return '$title - $p';
  }
}

/// playurl 里挑出来的可裁流。
class BilibiliPlayStreams {
  const BilibiliPlayStreams({required this.audioUrl, this.durationSec});

  /// 最高码率的 audio-only DASH 流（`.m4s`，AAC）。
  final String audioUrl;

  /// dash.duration（秒），可能缺失。
  final int? durationSec;
}

/// 解析好的「一句 bilibili 片段制卡请求」的裸值。与 `YoutubeClipRequest` 同形状。
class BilibiliClipRequest {
  const BilibiliClipRequest({
    required this.audioSource,
    required this.clipStartMs,
    required this.clipEndMs,
    required this.fields,
    required this.sentence,
    required this.cueSentence,
    required this.documentTitle,
  });

  /// 句子音频的 ffmpeg 输入（audio-only DASH URL）。
  final String audioSource;
  final int clipStartMs;
  final int clipEndMs;
  final Map<String, String> fields;
  final String sentence;
  final String? cueSentence;
  final String documentTitle;
}

/// `x/web-interface/view` 响应体 → 指定分 P 的身份。纯函数，便于离线单测。
///
/// [page] 是 1 基的分 P 号（B 站 URL 的 `?p=`）。越界或没有 `pages` 数组时回落到稿件级
/// `data.cid`——单 P 稿件的常态，也是老响应体的兼容路径。
/// 非 JSON / `code != 0` / 缺 cid 一律返回 null（调用方据此判「解析不出这个视频」）。
BilibiliVideoIdentity? parseBilibiliViewResponse(String body, {int page = 1}) {
  final Object? decoded = _tryDecodeJson(body);
  if (decoded is! Map) return null;
  if (decoded['code'] != 0) return null;
  final Object? data = decoded['data'];
  if (data is! Map) return null;
  final String title = '${data['title'] ?? ''}';

  int? cid;
  String? partTitle;
  int? durationSec;
  final Object? pages = data['pages'];
  if (pages is List && pages.isNotEmpty) {
    final int index = (page >= 1 && page <= pages.length) ? page - 1 : 0;
    final Object? entry = pages[index];
    if (entry is Map) {
      cid = _asInt(entry['cid']);
      partTitle = entry['part'] is String ? entry['part'] as String : null;
      durationSec = _asInt(entry['duration']);
    }
  }
  cid ??= _asInt(data['cid']);
  if (cid == null || cid <= 0) return null;
  return BilibiliVideoIdentity(
    cid: cid,
    title: title,
    partTitle: partTitle,
    durationSec: durationSec,
  );
}

/// `x/player/playurl`（DASH）响应体 → 最高码率音轨。纯函数，便于离线单测。
///
/// 只看 `data.dash.audio`：`durl`（非 DASH 的整段 flv/mp4）在这里当作不可用——那条路拿到的
/// 是**混流**，裁音频要先解出音轨，且大陆站未登录时的 durl 档位很低；DASH 拿不到就让调用方
/// 失败，不静默降级成一张没有音频的卡。
BilibiliPlayStreams? parseBilibiliPlayurlResponse(String body) {
  final Object? decoded = _tryDecodeJson(body);
  if (decoded is! Map) return null;
  if (decoded['code'] != 0) return null;
  final Object? data = decoded['data'];
  if (data is! Map) return null;
  final Object? dash = data['dash'];
  if (dash is! Map) return null;
  final Object? audio = dash['audio'];
  if (audio is! List || audio.isEmpty) return null;

  String? bestUrl;
  int bestBandwidth = -1;
  for (final Object? entry in audio) {
    if (entry is! Map) continue;
    final String url = '${entry['baseUrl'] ?? entry['base_url'] ?? ''}';
    if (url.isEmpty) continue;
    final int bandwidth = _asInt(entry['bandwidth']) ?? 0;
    if (bandwidth > bestBandwidth) {
      bestBandwidth = bandwidth;
      bestUrl = url;
    }
  }
  if (bestUrl == null) return null;
  return BilibiliPlayStreams(
    audioUrl: bestUrl,
    durationSec: _asInt(dash['duration']),
  );
}

/// B 站接口要求带浏览器 UA；不带会被部分节点拒。与 playurl 的 Referer 无关（见类注释：
/// 音轨直链本身不校验 Referer，这里的 UA 是给 **API** 用的）。
const String kBilibiliApiUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const String _kBilibiliApiReferer = 'https://www.bilibili.com/';

/// DASH 位掩码：16(DASH) | 64(HDR) | 128(4K) | 256(Dolby音频) | 512(Dolby视界) |
/// 1024(8K) | 2048(AV1) = 4048。与 web 端一致；未登录时服务端自然只返回可得档位。
const int _kBilibiliDashFnval = 4048;

typedef BilibiliJsonFetcher = Future<String?> Function(Uri uri);

/// 批量/单条 bilibili 制卡的流解析层：`{bvid, 分P, 视频时间窗}` → [BilibiliClipRequest]。
///
/// 内置 TTL 缓存，理由与 [YoutubeClipMiner] 相同：一次「生成全部」里同一视频的 N 张卡只解析
/// 一次流（两次网络往返、~1 秒）。缓存的是**进行中的 Future**，并发解析同一视频也只发一轮
/// 请求；解析失败即从缓存剔除，不让 rejected future 卡住 TTL 内的重试。
///
/// TTL 取 3 分钟而不是更长：playurl 给的直链带 `deadline` 查询参数（实测有效期数小时），
/// 但 3 分钟已足够覆盖一次批量生成，且过期链只会让下一次重新解析，不会留下坏卡。
class BilibiliClipMiner {
  BilibiliClipMiner({
    BilibiliJsonFetcher? fetchJson,
    DateTime Function()? now,
    this.ttl = const Duration(minutes: 3),
  })  : _fetchJson = fetchJson ?? _defaultFetchJson,
        _now = now ?? DateTime.now;

  final BilibiliJsonFetcher _fetchJson;
  final DateTime Function() _now;
  final Duration ttl;
  final Map<String, _CachedStreams> _cache = <String, _CachedStreams>{};

  /// 解析出一条可直接喂引擎的请求。视频不可用 / 无 DASH 音轨时抛 [StateError]，
  /// 由调用方收敛成干净的制卡错误（不建无音频的坏卡）。
  Future<BilibiliClipRequest> buildRequest({
    required String bvid,
    required int startMs,
    required int endMs,
    required Map<String, String> fields,
    required String sentence,
    int page = 1,
    String? cueSentence,
    String? documentTitle,
  }) async {
    final _ResolvedBilibili resolved = await _resolvedFor(bvid, page);
    return BilibiliClipRequest(
      audioSource: resolved.streams.audioUrl,
      clipStartMs: startMs,
      clipEndMs: endMs,
      fields: fields,
      sentence: sentence,
      cueSentence: cueSentence,
      // 扩展带上来的页面标题优先（它就是用户此刻看到的那个标题，含番剧/合集语境）；
      // 没带才用稿件标题。
      documentTitle: (documentTitle != null && documentTitle.trim().isNotEmpty)
          ? documentTitle
          : resolved.identity.displayTitle,
    );
  }

  Future<_ResolvedBilibili> _resolvedFor(String bvid, int page) {
    final String key = '$bvid|p$page';
    final DateTime t = _now();
    final _CachedStreams? hit = _cache[key];
    if (hit != null && t.difference(hit.at) < ttl) return hit.future;
    final Future<_ResolvedBilibili> fut = _resolveNow(bvid, page);
    _cache[key] = _CachedStreams(fut, t);
    // 失败即从缓存剔除（否则 TTL 内都返回同一个 rejected future，卡住重试）。这个独立监听器
    // 自己吞掉清理分支的错误（不 rethrow），调用方仍从 await fut 拿到原始异常。
    unawaited(fut.then<void>((_) {}, onError: (Object e, StackTrace s) {
      if (identical(_cache[key]?.future, fut)) _cache.remove(key);
    }));
    return fut;
  }

  Future<_ResolvedBilibili> _resolveNow(String bvid, int page) async {
    final String? viewBody = await _fetchJson(Uri.parse(
        'https://api.bilibili.com/x/web-interface/view?bvid=$bvid'));
    if (viewBody == null) {
      throw StateError('bilibili view request failed (bvid=$bvid)');
    }
    final BilibiliVideoIdentity? identity =
        parseBilibiliViewResponse(viewBody, page: page);
    if (identity == null) {
      throw StateError('bilibili view unparsable (bvid=$bvid, p=$page)');
    }
    final String? playBody = await _fetchJson(Uri.parse(
        'https://api.bilibili.com/x/player/playurl?bvid=$bvid'
        '&cid=${identity.cid}&fnval=$_kBilibiliDashFnval&fourk=1'));
    if (playBody == null) {
      throw StateError('bilibili playurl request failed (bvid=$bvid)');
    }
    final BilibiliPlayStreams? streams =
        parseBilibiliPlayurlResponse(playBody);
    if (streams == null) {
      throw StateError('bilibili playurl has no DASH audio (bvid=$bvid)');
    }
    return _ResolvedBilibili(identity, streams);
  }
}

Future<String?> _defaultFetchJson(Uri uri) async {
  final http.Client client = createAppHttpIoClient();
  try {
    final http.Response res = await client.get(uri, headers: <String, String>{
      'User-Agent': kBilibiliApiUserAgent,
      'Referer': _kBilibiliApiReferer,
    });
    if (res.statusCode != 200) return null;
    // B 站 API 是 UTF-8；用 bodyBytes 显式解码，避免 http 包按 content-type 猜成 latin1
    // 把中文标题变成乱码（那会一路进到 Anki 的视频名字段）。
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

Object? _tryDecodeJson(String body) {
  try {
    return jsonDecode(body);
  } catch (_) {
    return null;
  }
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

class _ResolvedBilibili {
  const _ResolvedBilibili(this.identity, this.streams);
  final BilibiliVideoIdentity identity;
  final BilibiliPlayStreams streams;
}

class _CachedStreams {
  const _CachedStreams(this.future, this.at);
  final Future<_ResolvedBilibili> future;
  final DateTime at;
}
