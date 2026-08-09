import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/media/video/youtube_source_resolver.dart';
import 'package:fushi/src/media/video/youtube_stream_cache.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;

/// 流媒体书判据（TODO-1157）：`videoPath` 是可播 http/https 流 URL。
///
/// 「粘贴 URL 导入」的流媒体书 [VideoBookRow.videoPath] 存原始 URL（YouTube=watch URL，
/// 直链/HLS=直链）；本地文件视频 videoPath 是文件路径 → false。判据唯一、不依赖额外
/// 标记列（[VideoBooks.streamSpecJson] 只在有外挂字幕/防盗链 header 时非空，不当判据）。
bool isStreamVideoBook(VideoBookRow book) =>
    isPlayableStreamUrl(book.videoPath);

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
  final http.Client client = http.Client();
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
            ((String u) => resolveYoutubeSource(u, withCaptions: false));
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
        if (await liveness(cached.streamUrl, cached.httpHeaders)) {
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
      httpHeaderFields: spec.httpHeaderFields,
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
}) async {
  final UrlStreamVideoClient client;
  if (isYoutubeUrl(url)) {
    final YoutubeResolvedSource resolved =
        await resolveYoutubeSource(url, withCaptions: false);
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
