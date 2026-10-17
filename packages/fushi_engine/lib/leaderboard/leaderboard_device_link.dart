// 「已互联配对设备代为登录」的请求体（服务端 POST /v1/me/devices，
// services/leaderboard/src/account.js addDevice）。
//
// 流程：本机没有排行榜账户的新设备（手机）**自己生成**设备钥匙，只把公钥 + 持有证明经已认证的
// 互联通道交给已登录的对端（电脑）；对端用**它自己的**设备钥匙签名调服务端，把这把公钥挂到同一
// 账户，再把账户信息（非敏感）回给新设备落档。私钥与恢复码从不离开各自的设备。
//
// 持有证明串与 auth.js `deviceLinkProofString` 逐字节一致：
//   `fushi-device-link\n${pubkey}\n${time}`，新设备私钥 ECDSA/SHA-256 P1363 base64url。

import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';

/// 持有证明的待签名串（与服务端 auth.js `deviceLinkProofString` 一致）。
String leaderboardDeviceLinkProofString(String pubkeyBase64Url, int timeMs) =>
    'fushi-device-link\n$pubkeyBase64Url\n$timeMs';

/// 新设备交给已登录设备代绑的请求：公钥 + 时刻 + 持有证明。不含任何私钥材料。
class LeaderboardDeviceLinkRequest {
  const LeaderboardDeviceLinkRequest({
    required this.pubkey,
    required this.time,
    required this.proof,
  });

  /// 新设备用自己的钥匙 [identity] 签出持有证明。[serverTimeMs] 应是按服务器时钟校准过的时刻
  /// （服务端要求 ±5 分钟内）；新设备拿不到校准时用本地时钟即可，代绑方也可在过期时让它重签。
  factory LeaderboardDeviceLinkRequest.sign(
    LeaderboardIdentity identity,
    int serverTimeMs,
  ) {
    final String pubkey = identity.pubkeyBase64Url;
    return LeaderboardDeviceLinkRequest(
      pubkey: pubkey,
      time: serverTimeMs,
      proof: identity.sign(
        leaderboardDeviceLinkProofString(pubkey, serverTimeMs),
      ),
    );
  }

  /// 形状不对抛 [FormatException]。
  factory LeaderboardDeviceLinkRequest.fromJson(Map<String, dynamic> j) {
    final Object? pubkey = j['pubkey'];
    final Object? time = j['time'];
    final Object? proof = j['proof'];
    if (pubkey is! String || time is! int || proof is! String) {
      throw const FormatException('bad device link request');
    }
    if (pubkey.length > 200 || proof.length > 200) {
      throw const FormatException('bad device link request');
    }
    return LeaderboardDeviceLinkRequest(
      pubkey: pubkey,
      time: time,
      proof: proof,
    );
  }

  /// base64url(SPKI DER)。
  final String pubkey;

  /// 签证明时的时刻（epoch 毫秒）。
  final int time;

  /// 新设备私钥对 [leaderboardDeviceLinkProofString] 的签名。
  final String proof;

  /// 新设备的钥匙 id（= 它以后发的 X-Fushi-Account）；公钥不是合法 base64url 时为 null。
  String? get keyId {
    try {
      return leaderboardAccountIdFromSpki(leaderboardBase64UrlDecode(pubkey));
    } on FormatException {
      return null;
    }
  }

  /// 本地预检证明（代绑方在打服务端之前先挡掉伪造请求，省一次请求；权威校验在服务端）。
  bool verifyProof() {
    try {
      return LeaderboardIdentity.verify(
        leaderboardBase64UrlDecode(pubkey),
        leaderboardDeviceLinkProofString(pubkey, time),
        proof,
      );
    } on FormatException {
      return false;
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'pubkey': pubkey,
    'time': time,
    'proof': proof,
  };
}
