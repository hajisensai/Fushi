import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';
import 'package:fushi/src/utils/net/hls_relay_normalizer.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart'
    show kYoutubeStreamReplayUserAgent;
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show
        FfmpegRemoteInputRoute,
        ffmpegSupportsHlsHttpMultipleOption,
        ffmpegSupportsHlsSegmentExtensionOptions;

/// 制卡 ffmpeg 的远端输入改走本机中继的登记表（BUG-2642 残留）。
///
/// 播放器取在线视频源的流时有两道归一化：mpv 关了 hls 的分片扩展名检查，本机中继
/// 把伪装成图片的分片剥掉 PNG 前缀、把播放列表里的 https 分片改写成明文中继形式。
/// 制卡的 ffmpeg 原本直连原始地址，两道都没有——`.jpg` / `.image` 名的分片被
/// FFmpeg 7.1 的扩展名白名单拒掉，带 PNG 前缀的分片在编了 PNG 探测器的构建
/// （Android ffmpeg-kit）上被认成一张图。这里让它走与播放器同一条路：
/// 输入地址改写成 [nativePlaybackUri] 形式、带上中继端点作 `-http_proxy`，
/// 是 HLS 且当前 ffmpeg 认得那几个选项时再放开扩展名检查。
///
/// 引擎经装配点 `ffmpegRemoteInputRouteResolver`（`installEngineHostBindings` 接线）
/// 按输入地址查这里；与中继自己按原点登记同构。只留最近几条：制卡是一次一张卡，
/// 但 master 被解析成变体时一张卡占两条（master 与变体各一条），队列里积压的不同集
/// 若把最早那张的登记挤掉，ffmpeg 就会不带 `-http_proxy` 直连中继形式的明文地址而
/// 失败——所以按「两条一张卡」留足余量。
const int _kMaxRelayedInputs = 32;

/// 预先取 master 播放列表的时限。登记完成前制卡队列在等，所以必须有界；超时就
/// 不解析，ffmpeg 照旧自己读 master（慢，但结果一样）。
const Duration _kMasterPlaylistTimeout = Duration(seconds: 10);

/// master 播放列表的读取上限：正常的只有几 KB，超了就不是 master。
const int _kMasterPlaylistMaxBytes = 1024 * 1024;

final LinkedHashMap<String, FfmpegRemoteInputRoute> _routes =
    LinkedHashMap<String, FfmpegRemoteInputRoute>();

/// 引擎装配点的实现：[inputPath] 登记过就返回它的连接方式，否则 null（直连）。
FfmpegRemoteInputRoute? ffmpegRelayRouteFor(String inputPath) =>
    _routes[inputPath];

/// 把制卡输入 [url] 改走本机中继。
///
/// 立即返回改写后的地址（同步，调用方据此当场组请求、当场入队）；登记本身是异步的
/// （[isHls] 要读播放器、中继端点要验活、ffmpeg 能力要探测、master 要解析），完成
/// 信号是返回值的 `ready`——交给 `ImmersionMiningRequest.mediaSourceRouteReady`，
/// 引擎在构造参数前等它。`ready` 从不失败：中继起不来时记日志、不登记，ffmpeg 按
/// 改写后的地址直连并以看得见的抽取失败收场（中继起不来时播放本身也不可用）。
///
/// 是 HLS 时顺带把 master 播放列表解析成播放器默认选的那一档（见
/// [selectHlsMasterVariant]），经中继、带 [headers]（与 ffmpeg 同一组防盗链头）取，
/// 引擎经 `ffmpegRemoteInputFor` 让 ffmpeg 直接读那一档。这一步失败只是少一个优化，
/// 不影响登记。
({String url, Future<void> ready}) relayFfmpegRemoteInput(
  String url, {
  required Future<bool> isHls,
  Map<String, String> headers = const <String, String>{},
}) {
  final String relayed = nativePlaybackUri(url);
  final Future<void> ready = () async {
    try {
      final Uri endpoint = await ensureAppNativeProxyEndpoint();
      final bool hls = await isHls;
      final bool relax =
          hls && await ffmpegSupportsHlsSegmentExtensionOptions();
      // `-http_multiple` 与扩展名那几个一样是 hls demuxer 私有选项：只给 HLS 输入、
      // 且只在当前 ffmpeg 认得时给，否则 `Option not found` 让整张卡抽取失败。
      final bool noPrefetch =
          hls && await ffmpegSupportsHlsHttpMultipleOption();
      final String? variant = hls
          ? await _resolveMasterVariant(relayed, endpoint, headers)
          : null;
      _register(
        relayed,
        FfmpegRemoteInputRoute(
          httpProxy: endpoint.toString(),
          disableHlsSegmentPrefetch: noPrefetch,
          relaxHlsSegmentExtensions: relax,
          input: variant,
        ),
      );
      if (variant != null) {
        _register(
          variant,
          FfmpegRemoteInputRoute(
            httpProxy: endpoint.toString(),
            disableHlsSegmentPrefetch: noPrefetch,
            relaxHlsSegmentExtensions: relax,
          ),
        );
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('relayFfmpegRemoteInput', error, stack);
    }
  }();
  return (url: relayed, ready: ready);
}

void _register(String input, FfmpegRemoteInputRoute route) {
  _routes.remove(input);
  _routes[input] = route;
  while (_routes.length > _kMaxRelayedInputs) {
    _routes.remove(_routes.keys.first);
  }
}

/// 经中继取 [relayed]；是 master 就返回选中那一档的**中继形式**绝对地址，否则 null。
///
/// 经中继而不是直连：中继会把播放列表里的 https 地址改写成它认识的明文形式，
/// 相对地址按重定向后的最终地址解析（与 ffmpeg 自己解析 master 的基址一致），
/// 得到的变体地址 ffmpeg 经 `-http_proxy` 原样可读。
Future<String?> _resolveMasterVariant(
  String relayed,
  Uri endpoint,
  Map<String, String> headers,
) async {
  final HttpClient client = HttpClient()
    ..findProxy = (Uri _) =>
        'PROXY ${endpoint.userInfo}@${endpoint.host}:${endpoint.port}';
  try {
    return await () async {
      final HttpClientRequest request = await client.getUrl(Uri.parse(relayed));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        kYoutubeStreamReplayUserAgent,
      );
      headers.forEach(request.headers.set);
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final BytesBuilder body = BytesBuilder(copy: false);
      await for (final List<int> chunk in response) {
        body.add(chunk);
        if (body.length > _kMasterPlaylistMaxBytes) return null;
      }
      final String? variant = selectHlsMasterVariant(
        utf8.decode(body.takeBytes(), allowMalformed: true),
      );
      if (variant == null) return null;
      final Uri base = response.redirects.isEmpty
          ? Uri.parse(relayed)
          : response.redirects.last.location;
      return Uri.parse(relayed).resolveUri(base).resolve(variant).toString();
    }().timeout(_kMasterPlaylistTimeout);
  } on Object catch (error) {
    // 取不到 / 超时只是不优化：ffmpeg 照旧读 master。
    debugPrint(
      redactAppNativeProxySecrets(
        'relayFfmpegRemoteInput: master playlist not resolved: $error',
      ),
    );
    return null;
  } finally {
    client.close(force: true);
  }
}

@visibleForTesting
void debugClearFfmpegRelayRoutes() => _routes.clear();
