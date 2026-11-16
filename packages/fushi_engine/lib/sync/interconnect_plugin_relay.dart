/// 互联「插件中继」：没有插件运行时的设备（iOS）经互联让已配对 host 代跑音乐 / 歌词插件
/// （拍板台 wOMR4_Er7s 方案 b，`docs/specs/2026-11-16-interconnect-source-share.md` §5）。
///
/// client 不执行第三方代码、不连插件的平台取流 / 调接口（封面图例外：host 只核对封面地址，图片由
/// client 直接从插件平台的图片 CDN 加载）：能力调用、封面核对、媒体地址解析都在 host 的
/// 插件实例上做，**媒体字节也经 host 转发**（插件给的地址常绑定请求方 IP / 地区、要防盗链
/// 请求头，且请求头里可能带 host 上的登录 Cookie——这些都不该交给另一台设备）。
///
/// 本文件只放 wire 形状、host 侧接口与流票登记表；插件管理器在 app
/// （`fushi/lib/src/media/music/plugin/music_plugin_relay_*.dart`）。
///
/// 路由（门与「来源共享」同一组：HTTPS + per-peer token + host 开关 + 「我的设备」）：
///
/// ```
/// GET  /api/interconnect/plugin-relay              → {plugins: [MusicPluginPackageInfo JSON…]}
/// POST /api/interconnect/plugin-relay/invoke       {plugin, method, args}  → {value}
/// POST /api/interconnect/plugin-relay/covers       {plugin, urls}          → {covers: {原地址: 地址}}
/// POST /api/interconnect/plugin-relay/media        {plugin, url, headers}  → {path}（流票路径，
///                                                   client 拼到本次实际走的 host 地址上）
/// GET  /api/interconnect/plugin-relay/stream/<票>  → 媒体字节（Range 透传；免 Basic，门是流票）
/// ```
///
/// 失败一律 `{error: <短码>, message?: <给用户看的说明>}`（短码见 `kPluginRelay*`）。
library;

import 'dart:convert';
import 'dart:math';

import 'package:meta/meta.dart';

/// 目录端点。
const String kInterconnectPluginRelayPath = '/api/interconnect/plugin-relay';

/// 能力调用端点。
const String kInterconnectPluginRelayInvokePath =
    '$kInterconnectPluginRelayPath/invoke';

/// 封面地址核对端点。
const String kInterconnectPluginRelayCoversPath =
    '$kInterconnectPluginRelayPath/covers';

/// 媒体地址解析端点（回流票地址）。
const String kInterconnectPluginRelayMediaPath =
    '$kInterconnectPluginRelayPath/media';

/// 流票取流路径前缀（后接流票）。
const String kInterconnectPluginRelayStreamPrefix =
    '$kInterconnectPluginRelayPath/stream/';

/// `/api/capabilities` 的 `features` 能力位名。
const String kInterconnectPluginRelayFeature = 'pluginRelay';

/// 插件此刻不在 host 上可用（没装 / 停用 / 不再经中继提供）。
const String kPluginRelayNotAvailable = 'plugin_not_available';

/// 这项能力不经中继（登录）或插件没声明它。
const String kPluginRelayUnsupported = 'capability_unsupported';

/// 插件自己报错 / 返回值不对 / 超时：`message` 是插件宿主给的说明。
const String kPluginRelayPluginError = 'plugin_error';

/// 媒体地址不可用（越权 / 重定向越权 / 请求头不合规 / 探测失败）。
const String kPluginRelayMediaUnavailable = 'media_unavailable';

/// 请求体不对。
const String kPluginRelayBadRequest = 'bad_request';

/// host 代跑失败的分型（app 侧实现抛它，路由折成 `{error, message}`）。
class InterconnectPluginRelayError implements Exception {
  const InterconnectPluginRelayError(this.code, [this.message]);

  final String code;
  final String? message;

  @override
  String toString() => message == null ? code : '$code: $message';
}

/// host 已核对过的一个媒体地址（插件实例的 `resolveMediaStream` 结果）：流票只指向它。
@immutable
class InterconnectPluginRelayMediaTarget {
  const InterconnectPluginRelayMediaTarget({
    required this.pluginId,
    required this.url,
    required this.headers,
  });

  final String pluginId;
  final String url;
  final Map<String, String> headers;
}

/// host 向插件平台取到的一段媒体响应，由路由原样转给 client。
class InterconnectPluginRelayUpstream {
  InterconnectPluginRelayUpstream({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  /// 上游状态码（200 / 206 / 416…）。
  final int statusCode;

  /// 要转给 client 的响应头（只含 [kInterconnectPluginRelayForwardedHeaders]）。
  final Map<String, String> headers;

  /// 响应体（HEAD 时为空流）。client 断开时订阅被取消，上游连接随之关闭。
  final Stream<List<int>> body;
}

/// 从上游转给 client 的响应头（小写）：只要播放器 seek / 识别格式要的那几个，Set-Cookie 等
/// 平台会话信息一概不出 host。
const Set<String> kInterconnectPluginRelayForwardedHeaders = <String>{
  'content-type',
  'content-length',
  'content-range',
  'accept-ranges',
  'last-modified',
  'etag',
};

/// host 侧：由 app 用本机的插件管理器实现。
abstract interface class InterconnectPluginRelayHost {
  /// host 主人的开关「把来源共享给我的设备」（与来源共享同一个，每个请求现读）。
  Future<bool> isPluginRelayEnabled();

  /// [peerToken] 对应的已配对设备被 host 主人标为「我的设备」。
  Future<bool> isOwnerDevicePeer(String peerToken);

  /// 本机已装、启用、可中继的音乐 / 歌词插件（`MusicPluginPackageInfo.toJson()`，清单里已去掉
  /// 不经中继的能力）。
  Future<List<Map<String, Object?>>> pluginRelayCatalog();

  /// 代调插件 [pluginId] 的能力 [method]，返回插件原始返回值（JSON 形状）。失败抛
  /// [InterconnectPluginRelayError]。
  Future<Object?> pluginRelayInvoke(
    String pluginId,
    String method,
    Map<String, Object?> args,
  );

  /// 代核对封面地址（「原地址 → 地址」，越权 / 落私网的不出现）。
  Future<Map<String, String>> pluginRelayCheckCovers(
    String pluginId,
    List<String> urls,
  );

  /// 代解析媒体地址（授权、请求头白名单、逐跳重定向核对）。不可用抛
  /// [InterconnectPluginRelayError]（[kPluginRelayMediaUnavailable]）。
  Future<InterconnectPluginRelayMediaTarget> pluginRelayResolveMedia(
    String pluginId,
    String url,
    Map<String, String> headers,
  );

  /// 向 [target] 取一段媒体（[range] 是 client 的 `Range` 头原文）。连接只连核对过的地址。
  Future<InterconnectPluginRelayUpstream> pluginRelayOpenMedia(
    InterconnectPluginRelayMediaTarget target, {
    String? range,
    required bool head,
  });
}

/// 流票登记表：一张票 = 一个已核对的媒体地址 + 签发它的凭据。
///
/// 播放器拿裸 URL 取流、带不了 Authorization，所以流票本身就是门：32 字节随机、只在
/// 签发时经 HTTPS 交给已认证的「我的设备」。签发凭据被吊销 / 不再是「我的设备」/ host 关了
/// 开关，取流时路由逐个现查，票随之失效。
class InterconnectPluginRelayTickets {
  InterconnectPluginRelayTickets({
    this.ttl = const Duration(hours: 6),
    this.capacity = 256,
    @visibleForTesting DateTime Function()? now,
    @visibleForTesting Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  /// 一张票从签发起多久有效：插件的流地址本身也会过期，播放端每次起播重新解析一张。
  final Duration ttl;

  /// 最多同时有效的票数（超出时作废最早签发的）。
  final int capacity;

  final DateTime Function() _now;
  final Random _random;

  final Map<String, _RelayTicket> _tickets = <String, _RelayTicket>{};

  /// 为 [target] 签一张票（[authorization] 是签发请求的 Authorization 头，取流时据此复核）。
  String issue(
    InterconnectPluginRelayMediaTarget target,
    String authorization,
  ) {
    _prune();
    while (_tickets.length >= capacity) {
      _tickets.remove(_tickets.keys.first);
    }
    final String ticket = base64Url
        .encode(List<int>.generate(32, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    _tickets[ticket] = _RelayTicket(target, authorization, _now());
    return ticket;
  }

  /// 有效的票 → (目标, 签发凭据)；不存在 / 过期 → null。
  ({InterconnectPluginRelayMediaTarget target, String authorization})? lookup(
    String ticket,
  ) {
    _prune();
    final _RelayTicket? t = _tickets[ticket];
    return t == null
        ? null
        : (target: t.target, authorization: t.authorization);
  }

  @visibleForTesting
  int get length => _tickets.length;

  void _prune() {
    final DateTime now = _now();
    _tickets.removeWhere(
      (String _, _RelayTicket t) => now.difference(t.issuedAt) >= ttl,
    );
  }
}

class _RelayTicket {
  const _RelayTicket(this.target, this.authorization, this.issuedAt);

  final InterconnectPluginRelayMediaTarget target;
  final String authorization;
  final DateTime issuedAt;
}
