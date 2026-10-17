// 「跟随已配对设备自动登录 Fushi 账户」的互联端点（host = 已登录排行榜 / 社区账户的设备）。
//
// 新设备（client，本机没有账户）**自己生成**设备钥匙，只把公钥 + 持有证明
// （[LeaderboardDeviceLinkRequest]）POST 给已配对的 host；host 用**它自己的**设备钥匙签名调
// 服务端 `POST /v1/me/devices` 把这把公钥挂到同一账户，再把账户信息（非敏感：账户 id、昵称等
// 公开资料 + 服务地址）回给新设备落档。私钥、恢复码绝不经互联传输——载荷里根本没有它们。
//
// 门（与 Profile 传输同一套，见 fushi_sync_server/leaderboard_link.part.dart）：
//   1. 必须 HTTPS：明文局域网上配对令牌可被嗅探，嗅到的人就能把**自己的**钥匙挂进账户；
//   2. 只认已配对设备的 per-peer 令牌（共享 token 一律拒）；
//   3. host 没装配本能力 → 404（旧版 / 无头服务端），`/api/capabilities` 不声明
//      [kInterconnectLeaderboardLinkCapability]；
//   4. host 用户关了「允许已配对设备自动登录我的账户」（总闸）→ 403 `disabled`；
//   5. 发起的 peer 没被 host 标记为「我的设备」→ 403 `not_owner_device`。配对常常只是
//      借电脑查词 / 串流（朋友的手机也会配），代绑出去的钥匙在服务端是满权限，所以只认
//      host 主人在配对审批时选了「这是我的设备」、或之后在已配对设备列表里手动标记的 peer；
//      升级前就配对过的 peer 一律不算（不追溯授权）。

import 'package:fushi_engine/leaderboard/leaderboard_device_link.dart';

/// 端点路径（host / client 共用）。
const String kInterconnectLeaderboardLinkPath =
    '/api/interconnect/leaderboard-link';

/// `/api/capabilities` 顶层布尔位：host 能处理 [kInterconnectLeaderboardLinkPath]
/// （已装配 + HTTPS）。不代表开关开着、也不代表 host 已登录——那两项由端点本身回答。
const String kInterconnectLeaderboardLinkCapability = 'leaderboardDeviceLinkV1';

/// 请求体上限（公钥 + 证明几百字节）。
const int kInterconnectLeaderboardLinkMaxBody = 4 * 1024;

/// 端点的错误码（响应 JSON `error`）。client 据此决定退避，不向用户弹窗。
abstract final class InterconnectLeaderboardLinkError {
  /// host 关了开关（403）。
  static const String disabled = 'disabled';

  /// 发起的已配对设备没有被 host 标记为「我的设备」（403）。
  static const String notOwnerDevice = 'not_owner_device';

  /// host 本机没有登录账户（409）。
  static const String noAccount = 'no_account';

  /// 请求体不是合法的 [LeaderboardDeviceLinkRequest]，或持有证明本地预检不过（400）。
  static const String badRequest = 'bad_request';

  /// 服务端是不认 `POST /v1/me/devices` 的旧版（502）。
  static const String serverUnsupported = 'server_unsupported';

  /// 网络错误 / 服务端 5xx / 超时（502）。
  static const String serverUnavailable = 'server_unavailable';
}

/// host 侧处理失败：[status] / [code] 原样作为 HTTP 状态与 `error` 回给 client。
/// 服务端自己的 4xx（`too_many_devices` / `key_taken` / `stale_time` / `rate_limited` …）
/// 以 409 + 服务端错误码透传。
class InterconnectLeaderboardLinkException implements Exception {
  const InterconnectLeaderboardLinkException(this.status, this.code);

  final int status;
  final String code;

  @override
  String toString() => 'InterconnectLeaderboardLinkException($status $code)';
}

/// 成功结果：[account] 是服务端返回的**新设备视角**账户 JSON（`LeaderboardSelf.toJson`
/// 形状），[serverUrl] 是 host 账户用的服务地址（null = 默认地址）。client 提示
/// 「已用 xx 的账户登录」时用自己配对记录里的对端设备名，不靠 host 自报。
class InterconnectLeaderboardLinkResult {
  const InterconnectLeaderboardLinkResult({
    required this.account,
    this.serverUrl,
  });

  /// 形状不对抛 [FormatException]。
  factory InterconnectLeaderboardLinkResult.fromJson(Map<String, dynamic> j) {
    final Object? account = j['account'];
    final Object? server = j['serverUrl'];
    if (account is! Map<String, dynamic>) {
      throw const FormatException('bad leaderboard link result');
    }
    return InterconnectLeaderboardLinkResult(
      account: account,
      serverUrl: server is String && server.isNotEmpty ? server : null,
    );
  }

  final Map<String, dynamic> account;
  final String? serverUrl;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'account': account,
    if (serverUrl != null) 'serverUrl': serverUrl,
  };
}

/// host 侧能力（app 装配；引擎纯 Dart，不认识排行榜服务的 Flutter 侧状态）。
abstract interface class InterconnectLeaderboardLinkHost {
  /// 「允许已配对设备自动登录我的账户」开关（总闸，默认开）。
  Future<bool> isInterconnectLeaderboardLinkEnabled();

  /// 持 [peerToken]（已通过 per-peer 鉴权的配对凭据）的 peer 是否被标记为「我的设备」。
  Future<bool> isOwnerDevicePeer(String peerToken);

  /// 用本机已登录的账户代绑 [request] 里的新设备钥匙。失败抛
  /// [InterconnectLeaderboardLinkException]。
  Future<InterconnectLeaderboardLinkResult> linkLeaderboardDevice(
    LeaderboardDeviceLinkRequest request,
  );
}
