import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show FfmpegRemoteInputRoute, ffmpegSupportsHlsSegmentExtensionOptions;

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
/// 按输入地址查这里；与中继自己按原点登记同构。只留最近几条：制卡是一次一张卡。
const int _kMaxRelayedInputs = 16;

final LinkedHashMap<String, FfmpegRemoteInputRoute> _routes =
    LinkedHashMap<String, FfmpegRemoteInputRoute>();

/// 引擎装配点的实现：[inputPath] 登记过就返回它的连接方式，否则 null（直连）。
FfmpegRemoteInputRoute? ffmpegRelayRouteFor(String inputPath) =>
    _routes[inputPath];

/// 把制卡输入 [url] 改走本机中继。
///
/// 立即返回改写后的地址（同步，调用方据此当场组请求、当场入队）；登记本身是异步的
/// （[isHls] 要读播放器、中继端点要验活、ffmpeg 能力要探测），完成信号是返回值的
/// `ready`——交给 `ImmersionMiningRequest.mediaSourceRouteReady`，引擎在构造参数前等它。
/// `ready` 从不失败：中继起不来时记日志、不登记，ffmpeg 按改写后的地址直连并以看得见的
/// 抽取失败收场（中继起不来时播放本身也不可用）。
({String url, Future<void> ready}) relayFfmpegRemoteInput(
  String url, {
  required Future<bool> isHls,
}) {
  final String relayed = nativePlaybackUri(url);
  final Future<void> ready = () async {
    try {
      final Uri endpoint = await ensureAppNativeProxyEndpoint();
      final bool relax =
          await isHls && await ffmpegSupportsHlsSegmentExtensionOptions();
      _routes.remove(relayed);
      _routes[relayed] = FfmpegRemoteInputRoute(
        httpProxy: endpoint.toString(),
        relaxHlsSegmentExtensions: relax,
      );
      while (_routes.length > _kMaxRelayedInputs) {
        _routes.remove(_routes.keys.first);
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('relayFfmpegRemoteInput', error, stack);
    }
  }();
  return (url: relayed, ready: ready);
}

@visibleForTesting
void debugClearFfmpegRelayRoutes() => _routes.clear();
