import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:fushi_engine/media/video/media_server/media_server_route_failover.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/sync/plex_settings_widget.dart'
    show rerouteMediaServerAfterFailure;
import 'package:fushi/src/sync/sync_repository.dart';

/// 媒体服务器线路故障转移器：按服务器（[MediaServerConfig.sourceId]）共享、单飞
/// （拍板台 design-media-server-failover-transport）。
///
/// 协议层（`PlexApi` / `JellyfinApi`）的请求漏斗在传输失败时经 [hookFor] 调到这里
/// （[resolve]），这里决定这台服务器接下来走哪条线路：
///
/// 1. 持久化配置里的当前线路已经不是失败的那条（别处刚换过：另一个浏览器 / 播放页
///    的客户端先撞上并换好了，或用户手动切了）→ 直接给当前线路，不再探测。
/// 2. 同一台服务器已有一次探测在跑 → 等它的结果（单飞：浏览页一屏十几个请求同时
///    失败也只探一次）。
/// 3. 否则在这台服务器已存的线路里探测（[rerouteMediaServerAfterFailure]：Plex 无
///    凭据核对 machineIdentifier，Jellyfin 家族带令牌读一次媒体库），找到另一条可达
///    线路就写回配置，并经 [reroutedSources] 通知清单缓存失效（缓存里的封面 / 流 URL
///    烤着旧线路的 host）。
/// 4. 探过一圈没找到时，同一条失败线路在 [cooldown] 内不再重探：页面上紧接着的
///    一串请求各自超时之后不会一个接一个地再各探一轮。
///
/// 进程里只装一个（[install]，`AppModel.initialise` 打开数据库后装）；没装（测试、
/// 无头服务端）时钩子一律答「不换」，请求按原样报错。
class MediaServerRouteFailover {
  MediaServerRouteFailover({
    required Future<List<MediaServerConfig>> Function() loadConfigs,
    required Future<MediaServerConfig?> Function(
      MediaServerConfig config,
      Object error,
    )
    reroute,
    this.cooldown = const Duration(seconds: 10),
    DateTime Function()? clock,
  }) : _loadConfigs = loadConfigs,
       _reroute = reroute,
       _clock = clock ?? DateTime.now;

  /// 用 [repository] 现取的 [SyncRepository] 读写配置（数据库在备份恢复时可能换实例，
  /// 所以每次现取）。
  /// [httpClientFactory] 只给测试注入探测用的假服务器。
  factory MediaServerRouteFailover.forRepository(
    SyncRepository Function() repository, {
    http.Client Function()? httpClientFactory,
  }) => MediaServerRouteFailover(
    loadConfigs: () => repository().getMediaServers(),
    reroute: (MediaServerConfig config, Object error) =>
        rerouteMediaServerAfterFailure(
          config,
          error,
          repo: repository(),
          httpClientFactory: httpClientFactory,
        ),
  );

  final Future<List<MediaServerConfig>> Function() _loadConfigs;
  final Future<MediaServerConfig?> Function(
    MediaServerConfig config,
    Object error,
  )
  _reroute;
  final DateTime Function() _clock;

  /// 探测没找到可达线路之后，同一条失败线路不再重探的时长。
  final Duration cooldown;

  final Map<String, Future<String?>> _inflight = <String, Future<String?>>{};
  final Map<String, DateTime> _cooldownUntil = <String, DateTime>{};

  static MediaServerRouteFailover? _instance;

  /// 当前装着的故障转移器（没装为 null）。
  static MediaServerRouteFailover? get instance => _instance;

  /// 装上（或用 null 卸下）进程里唯一的故障转移器。
  static void install(MediaServerRouteFailover? failover) {
    _instance = failover;
  }

  static final StreamController<String> _rerouted =
      StreamController<String>.broadcast(sync: true);

  /// 自动换了线路的服务器（[MediaServerConfig.sourceId]）。远端清单缓存订阅它失效
  /// 对应的槽（`remoteLibraryCacheProvider`）。同步派发：换线路后的那次重试返回之前
  /// 缓存已经失效。
  static Stream<String> get reroutedSources => _rerouted.stream;

  /// 给 [sourceId] 那台服务器的协议客户端用的钩子。调用时才看装没装，所以客户端比
  /// [install] 先建也能用上。
  static MediaServerRouteFailoverHook hookFor(String sourceId) =>
      (String failedBaseUrl, Object error) async =>
          _instance?.resolve(sourceId, failedBaseUrl, error);

  /// [sourceId] 那台服务器在线路 [failedBaseUrl] 上以 [error] 失败之后该走的线路；
  /// 不换返回 null。见类文档的四条规则。
  Future<String?> resolve(String sourceId, String failedBaseUrl, Object error) {
    final Future<String?>? pending = _inflight[sourceId];
    if (pending != null) {
      return pending.then(
        (String? next) => next == failedBaseUrl ? null : next,
      );
    }
    final String cooldownKey = '$sourceId\n$failedBaseUrl';
    final DateTime? until = _cooldownUntil[cooldownKey];
    if (until != null && _clock().isBefore(until)) {
      return Future<String?>.value();
    }
    final Future<String?> run = _resolve(
      sourceId,
      failedBaseUrl,
      error,
      cooldownKey,
    );
    _inflight[sourceId] = run;
    return run.whenComplete(() {
      if (identical(_inflight[sourceId], run)) _inflight.remove(sourceId);
    });
  }

  Future<String?> _resolve(
    String sourceId,
    String failedBaseUrl,
    Object error,
    String cooldownKey,
  ) async {
    try {
      MediaServerConfig? config;
      for (final MediaServerConfig candidate in await _loadConfigs()) {
        if (candidate.sourceId == sourceId) {
          config = candidate;
          break;
        }
      }
      // 已登出：不探测、不写回（写回会把登出的服务器又加回来）。
      if (config == null) return null;
      final String current = config.effectiveServerUrl;
      if (current != failedBaseUrl) return current;
      final MediaServerConfig? rerouted = await _reroute(config, error);
      if (rerouted == null) {
        _cooldownUntil[cooldownKey] = _clock().add(cooldown);
        return null;
      }
      _cooldownUntil.remove(cooldownKey);
      debugPrint('[media-server-route] $sourceId switched route');
      _rerouted.add(sourceId);
      return rerouted.effectiveServerUrl;
    } on Object catch (e) {
      debugPrint('[media-server-route] $sourceId failover failed: $e');
      return null;
    }
  }

  /// 测试用：卸下装着的故障转移器。
  @visibleForTesting
  static void resetForTesting() {
    _instance = null;
  }
}

/// 播放器报「播完」时离片尾还差这么多，就当作流在播放途中断了
/// （[isInterruptedStreamEnd]）。
const int kInterruptedStreamEndMarginMs = 15000;

/// 播放器报 EOF 时的位置 [positionMs] 离时长 [durationMs] 还差至少
/// [kInterruptedStreamEndMarginMs]：真播完的 EOF 落在片尾，提前很多就是流断了
/// （HTTP 连接掉了，libmpv 把读到的末尾当成文件结束）。时长 / 位置未知时不判。
bool isInterruptedStreamEnd({
  required int? positionMs,
  required int? durationMs,
}) =>
    positionMs != null &&
    durationMs != null &&
    durationMs > kInterruptedStreamEndMarginMs &&
    positionMs >= 0 &&
    positionMs < durationMs - kInterruptedStreamEndMarginMs;
