import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/media/video/stream_url_resolver.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi_engine/media/video/strm_file.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart';
import 'package:fushi/src/media/video/youtube_stream_cache.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:fushi_engine/utils/net/app_http.dart';

/// 流媒体书判据（TODO-1157）：`videoPath` 是网络流地址，或 `.strm` 流指针。
///
/// 「粘贴 URL 导入」的流媒体书 [VideoBookRow.videoPath] 存原始 URL（YouTube=watch URL，
/// 直链/HLS=直链）；本地文件视频 videoPath 是文件路径 → false。判据唯一、不依赖额外
/// 标记列（[VideoBooks.streamSpecJson] 只在有外挂字幕/防盗链 header 时非空，不当判据）。
///
/// - 网络流按 [isNetworkStreamUrl]：除 http(s) 外还认 IPTV 频道列表常见的
///   rtsp / rtmp / udp 等直播协议（播放内核直接能开，本地文件路径打不开它们）。
/// - `.strm`（[isStrmPath]，本地或来源库网络条目）：`videoPath` 存 `.strm` 自身，
///   真正的流地址起播时经 [resolveStrmStreamTarget] 现读。
bool isStreamVideoBook(VideoBookRow book) =>
    isNetworkStreamUrl(book.videoPath) || isStrmPath(book.videoPath);

/// `.strm` 读不出可播地址的原因（起播失败文案据此分派）。
enum StrmResolveFailure {
  /// 文件里没有任何地址行（空文件 / 只有注释）。
  empty,

  /// 指向本机文件路径——不支持（本地文件请直接放进来源库）。
  localTarget,

  /// 相对路径 / 未知协议（`plugin://`、`smb://` …）。
  unsupportedTarget,

  /// 文件本身读不到（不存在、HTTP 非 2xx、超过 [kStrmMaxBytes]）。
  unreadable,
}

/// [resolveStrmStreamTarget] 的类型化失败。
class StrmResolveException implements Exception {
  const StrmResolveException(this.failure, this.strmPath, [this.detail]);

  final StrmResolveFailure failure;
  final String strmPath;
  final String? detail;

  @override
  String toString() =>
      'StrmResolveException(${failure.name}, $strmPath${detail == null ? '' : ', $detail'})';
}

/// 读取 `.strm` 流指针 [strmPath]，返回它指向的网络流地址。
///
/// - 本地路径：直接读文件；来源库网络条目（http(s)，WebDAV / AList）：经
///   [urlResolver]（AList 换签名直链）后 GET，带 [strmHttpHeaders]——这组头是
///   **按 `.strm` 自身地址**解析、只对来源根内生效的认证头（`.strm` 就在来源根里）。
///   它**不会**被带到返回的目标地址上：目标通常是第三方主机，调用方须按目标地址
///   另行解析（凭据作用域见 stream_auth_scope.dart）。
/// - 内容按 [parseStrmTarget] 取首条地址，[classifyStrmTarget] 分类；只接受网络流，
///   其余抛 [StrmResolveException]（调用方转成用户可见文案）。
Future<String> resolveStrmStreamTarget(
  String strmPath, {
  Map<String, String> strmHttpHeaders = const <String, String>{},
  StreamUrlResolver? urlResolver,
  http.Client? httpClient,
}) async {
  final String content = await _readStrmContent(
    strmPath,
    headers: strmHttpHeaders,
    urlResolver: urlResolver,
    httpClient: httpClient,
  );
  final String? target = parseStrmTarget(content);
  if (target == null) {
    throw StrmResolveException(StrmResolveFailure.empty, strmPath);
  }
  switch (classifyStrmTarget(target)) {
    case StrmTargetKind.networkStream:
      return target;
    case StrmTargetKind.localPath:
      throw StrmResolveException(
          StrmResolveFailure.localTarget, strmPath, target);
    case StrmTargetKind.unsupported:
      throw StrmResolveException(
          StrmResolveFailure.unsupportedTarget, strmPath, target);
  }
}

Future<String> _readStrmContent(
  String strmPath, {
  required Map<String, String> headers,
  required StreamUrlResolver? urlResolver,
  required http.Client? httpClient,
}) async {
  if (!isNetworkStreamUrl(strmPath)) {
    final File file = File(strmPath);
    if (!await file.exists()) {
      throw StrmResolveException(
          StrmResolveFailure.unreadable, strmPath, 'not found');
    }
    if (await file.length() > kStrmMaxBytes) {
      throw StrmResolveException(
          StrmResolveFailure.unreadable, strmPath, 'too large');
    }
    return utf8.decode(await file.readAsBytes(), allowMalformed: true);
  }
  final String url =
      urlResolver == null ? strmPath : await urlResolver.resolve(strmPath);
  final http.Client client = httpClient ?? createAppHttpIoClient();
  try {
    final http.Response res = await client
        .get(Uri.parse(url), headers: headers.isEmpty ? null : headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StrmResolveException(
          StrmResolveFailure.unreadable, strmPath, 'HTTP ${res.statusCode}');
    }
    if (res.bodyBytes.length > kStrmMaxBytes) {
      throw StrmResolveException(
          StrmResolveFailure.unreadable, strmPath, 'too large');
    }
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  } finally {
    if (httpClient == null) client.close();
  }
}

/// TODO-1314：缓存命中后确认流 URL 未失效的 liveness 探测签名。生产走 1 字节 Range GET，
/// 测试注入假件。返回 true=存活（用缓存）/ false=失效（invalidate + 重解析）。
typedef StreamLivenessCheck = Future<bool> Function(
    String streamUrl, Map<String, String> headers);

/// 默认 liveness：对缓存的 googlevideo 流 URL 发 1 字节 Range GET。2xx/206=存活；非 2xx
/// （403 IP 锁不匹配 / 410 过期 / 404）或异常/超时=失效。比全量 resolveYoutubeSource（多次
/// innertube 往返 + 跨 client 403 探测）便宜得多，仍挡住脏 URL 黑屏。异常/超时保守判失效
/// （宁可重解析拿新 URL，也不把可能已死的 URL 交给播放器）。
Future<bool> _defaultStreamLiveness(
    String streamUrl, Map<String, String> headers) async {
  final http.Client client = createAppHttpIoClient();
  try {
    final Map<String, String> h = <String, String>{
      ...headers,
      'Range': 'bytes=0-1',
    };
    final http.Response res = await client
        .get(Uri.parse(streamUrl), headers: h)
        .timeout(const Duration(seconds: 6));
    return res.statusCode >= 200 && res.statusCode < 300;
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}

/// 从流媒体书重建播放所需的 [UrlStreamVideoClient] + [RemoteVideoInfo]（TODO-1157）。
///
/// 让「粘贴 URL 导入」的流媒体像本地视频一样入库、在书架持久、可重复打开：重开时不复用
/// 过期的临时解析结果，而是按 [VideoBookRow.videoPath]（原始 URL）+ [VideoBookRow.streamSpecJson]
/// （外挂字幕 URL / 防盗链 header）重建客户端，与「导入即播」时 dialog 构建客户端的逻辑等价：
/// - YouTube（[isYoutubeUrl]）：TODO-1314 先查 [YoutubeStreamCache] 持久缓存（按 canonical
///   videoId key，由 googlevideo `expire` 派生过期时间）——命中且 liveness 探测存活即直接用
///   缓存重建、跳过全量解析（省慢网下每次开书的 getManifest 往返）；缓存失效（IP 锁不匹配 /
///   提前吊销）先 [YoutubeStreamCache.invalidate] 再重解析（绝不把脏 URL 喂播放器致黑屏）。
///   未命中/过期时走 TODO-1307 快解析 gate（[resolveYoutubeSource] `withCaptions:false`），
///   只取分离视频/音频流 + 防盗链 header 即起播，并把结果按 expire 落缓存；字幕后置——watch
///   URL 存进 [UrlStreamVideoClient.youtubeCaptionsUrl]，由播放页 load 返回后异步
///   [resolveYoutubeCaptions] 灌 1302 的 YouTube 字幕轨。
/// - 直链 / HLS：直接用 videoPath 作流 URL，附上 spec 里的外挂字幕 URL + Referer/User-Agent。
///
/// [RemoteVideoInfo.id] 用 [VideoBookRow.bookUid]（断点 prefs 按它 key，重开续看可对齐）。
/// YouTube 解析失败抛异常（调用方按打开失败处理，与 dialog 即播失败一致）。
Future<({UrlStreamVideoClient client, RemoteVideoInfo info})>
    buildStreamVideoLaunch(
  VideoBookRow book, {
  // TODO-1314：可注入的 YouTube 流缓存 / 解析器 / liveness 探测 / 时钟（默认走生产真身，
  // 测试注入假件以离线覆盖缓存命中/失效/未命中路径）。生产端全 null → 单例缓存 + 快解析 gate。
  YoutubeStreamCache? streamCache,
  Future<YoutubeResolvedSource> Function(String url)? youtubeResolver,
  StreamLivenessCheck? livenessCheck,
  DateTime Function()? now,
  // 用户显式 YouTube 画质目标（设置「YouTube 画质」；null=自动=默认策略）。透传给
  // 默认解析器，并作为缓存条目匹配键——改设置后旧档位缓存视为 miss 重解析。
  int? youtubeTargetHeight,
  // 来源库网络视频（WebDAV）打开时按 sourceId 现解析的认证头（见
  // source_stream_headers.dart 的凭据红线：不落行级 spec）。与 spec 里的防盗链
  // header 合并后同时用于视频流与 spec.subtitleUrl 字幕下载；仅直链分支消费
  // （YouTube 书不出自来源库）。
  Map<String, String> sourceHttpHeaders = const <String, String>{},
  // 来源库 AList 视频：条目地址是稳定的 `<根>/d/<路径>`，起播前经 fs/get 换临期
  // 签名直链（source_stream_headers.dart 的 resolveSourceStreamUrlResolver）。
  // 仅直链分支消费。
  StreamUrlResolver? sourceUrlResolver,
}) async {
  final String url = book.videoPath;
  final StreamVideoSpec spec =
      StreamVideoSpec.fromStorageJson(book.streamSpecJson);
  final UrlStreamVideoClient client;
  if (isYoutubeUrl(url)) {
    // TODO-1314：先查持久缓存（避免每次开书全量 resolve）。命中且 liveness 存活 → 直接用
    // 缓存重建客户端；失效 → invalidate 后落到重解析。未命中/过期 → TODO-1307 快解析 gate
    // （只 getManifest 取流即起播，跳过 videos.get 与字幕解析），并把结果按 expire 落缓存。
    // preresolvedCues 恒空，字幕由播放页 load 返回后异步 resolveYoutubeCaptions 灌 1302 字幕轨。
    final YoutubeStreamCache cache =
        streamCache ?? await YoutubeStreamCache.instance();
    final Future<YoutubeResolvedSource> Function(String) resolve =
        youtubeResolver ??
            ((String u) => resolveYoutubeSource(u,
                withCaptions: false,
                playbackTargetHeight: youtubeTargetHeight));
    final StreamLivenessCheck liveness =
        livenessCheck ?? _defaultStreamLiveness;
    final DateTime Function() clock = now ?? DateTime.now;
    final String? videoId = youtubeVideoIdOrNull(url);

    String streamUrl;
    String? audioStreamUrl;
    String? miningVideoUrl;
    bool miningVideoHasAudio;
    Map<String, String> httpHeaders;

    YoutubeStreamCacheEntry? hit;
    if (videoId != null) {
      final YoutubeStreamCacheEntry? cached = await cache.get(videoId);
      if (cached != null) {
        if (cached.targetHeight != youtubeTargetHeight) {
          // 画质目标变了：缓存的 streamUrl 是旧档位，按 miss 重解析（新结果 put 时覆盖）。
        } else if (await liveness(cached.streamUrl, cached.httpHeaders)) {
          hit = cached;
        } else {
          // 缓存 URL 已失效（IP 锁不匹配 / 提前吊销）：剔除，落到重解析（别喂脏 URL 致黑屏）。
          await cache.invalidate(videoId);
        }
      }
    }

    if (hit != null) {
      streamUrl = hit.streamUrl;
      audioStreamUrl = hit.audioStreamUrl;
      miningVideoUrl = hit.miningVideoUrl;
      miningVideoHasAudio = hit.miningVideoHasAudio;
      httpHeaders = hit.httpHeaders;
    } else {
      final YoutubeResolvedSource resolved = await resolve(url);
      streamUrl = resolved.streamUrl;
      audioStreamUrl = resolved.audioStreamUrl;
      miningVideoUrl = resolved.miningVideoUrl;
      // TODO-1301（BUG-600）：透传 muxed 挖矿流是否自带音轨（播放页据此选制卡音频源）。
      miningVideoHasAudio = resolved.miningVideoHasAudio;
      httpHeaders = resolved.httpHeaders;
      if (videoId != null) {
        final int? expiresAtMs = computeStreamCacheExpiryMs(
          <String?>[
            resolved.streamUrl,
            resolved.audioStreamUrl,
            resolved.miningVideoUrl,
          ],
          clock(),
        );
        // 可判定有效期才缓存；无 expire / 快过期 → 不缓存（下次仍重解析，不劣于旧）。
        if (expiresAtMs != null) {
          await cache.put(
            videoId,
            YoutubeStreamCacheEntry(
              streamUrl: resolved.streamUrl,
              audioStreamUrl: resolved.audioStreamUrl,
              miningVideoUrl: resolved.miningVideoUrl,
              miningVideoHasAudio: resolved.miningVideoHasAudio,
              httpHeaders: resolved.httpHeaders,
              expiresAtMs: expiresAtMs,
              targetHeight: youtubeTargetHeight,
            ),
          );
        }
      }
    }

    client = UrlStreamVideoClient(
      streamUrl: streamUrl,
      audioStreamUrl: audioStreamUrl,
      miningVideoUrl: miningVideoUrl,
      miningVideoHasAudio: miningVideoHasAudio,
      // 字幕后置：起播不带 cue，watch URL 供播放页 load 后异步解析字幕灌 1302 字幕轨。
      youtubeCaptionsUrl: url,
      httpHeaderFields: httpHeaders,
    );
  } else {
    final String? subtitleUrl = spec.subtitleUrl;
    client = UrlStreamVideoClient(
      streamUrl: url,
      subtitleUrl: (subtitleUrl != null && isPlayableStreamUrl(subtitleUrl))
          ? subtitleUrl
          : null,
      subtitleFileName: spec.subtitleFileName,
      // 直链/HLS 是单条 muxed 流（自带音轨）→ 制卡音频从它抽，无分离 audio-only 流。
      miningVideoHasAudio: true,
      httpHeaderFields: <String, String>{
        ...spec.httpHeaderFields,
        ...sourceHttpHeaders,
      },
      urlResolver: sourceUrlResolver,
    );
  }
  final RemoteVideoInfo info =
      RemoteVideoInfo(id: book.bookUid, title: book.title);
  return (client: client, info: info);
}

/// Builds an ephemeral in-app playback target for an online work attachment.
/// Unlike [buildStreamVideoLaunch], this deliberately does not create or
/// require a VideoBook row, so trailers stay attached to their canonical work
/// and never leak into the raw video library.
Future<({UrlStreamVideoClient client, RemoteVideoInfo info})>
    buildOnlineVideoExtraLaunch({
  required String id,
  required String title,
  required String url,
  int? youtubeTargetHeight,
}) async {
  final UrlStreamVideoClient client;
  if (isYoutubeUrl(url)) {
    final YoutubeResolvedSource resolved = await resolveYoutubeSource(url,
        withCaptions: false, playbackTargetHeight: youtubeTargetHeight);
    client = UrlStreamVideoClient(
      streamUrl: resolved.streamUrl,
      audioStreamUrl: resolved.audioStreamUrl,
      miningVideoUrl: resolved.miningVideoUrl,
      miningVideoHasAudio: resolved.miningVideoHasAudio,
      youtubeCaptionsUrl: url,
      httpHeaderFields: resolved.httpHeaders,
    );
  } else {
    client = UrlStreamVideoClient(
      streamUrl: url,
      miningVideoHasAudio: true,
    );
  }
  return (
    client: client,
    info: RemoteVideoInfo(id: 'work-extra:$id', title: title),
  );
}
