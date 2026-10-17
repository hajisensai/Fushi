// 互联设备钥匙：client 在 v2 配对里**证明**自己持有一把长期设备私钥，host 只有在验签
// 通过后才承认这台 peer 的「我的设备」资格（可跟随本机账户自动登录 = 满权限）。
//
// 背景（PR #2258 审查）：配对里 client 自报的 `clientDeviceId`（= `sync_device_id`）只是
// 随机串，而且会被这台设备当 host 时的 LAN 广播 TXT `id=` / 无鉴权 `/api/ping` 的
// `hostId` 公开出去——任何人都能拿来冒报。它可以继续当「这台安装」的稳定标识，但不能
// 单独撑起「这是我的设备」这种高价值授权。
//
// 协议（与旧 host / 旧 client 双向兼容，缺字段 = 没有设备钥匙）：
//   pair/v2   body 加 `devicePubkey` = base64url(P-256 SPKI)；
//   confirm   body 加 `deviceProof`  = 设备私钥对 [interconnectPairDeviceProofString]
//             （绑定本次会话的 sessionId + hostNonce + clientNonce + clientDeviceId + 公钥）
//             的 ECDSA/SHA-256 P1363 签名。hostNonce / sessionId 由 host 每会话随机生成，
//             签名无法搬到别的会话或别的 host 上重放。
//
// 密码学与字节格式复用排行榜设备钥匙（[LeaderboardIdentity]：P-256、RFC 6979 确定性 k、
// pointycastle 纯 Dart），不另引依赖；引擎纯度不受影响。

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';

/// 设备公钥字段（base64url SPKI，91 字节 → 122 字符）的长度上限，挡掉超长垃圾输入。
const int kInterconnectDevicePubkeyMaxChars = 200;

/// 签名字段（P1363 64 字节 → 86 字符）的长度上限。
const int kInterconnectDeviceProofMaxChars = 200;

/// 一把互联设备钥匙。私钥只在内存里，持久化由调用方负责（app 存设备本地偏好，
/// 不进备份 / Profile 快照，见 `SyncRepository.getOrCreateInterconnectDeviceKey`）。
class InterconnectDeviceKey {
  InterconnectDeviceKey._(this._identity);

  /// 生成新钥匙（[Random.secure]）。
  factory InterconnectDeviceKey.generate() =>
      InterconnectDeviceKey._(LeaderboardIdentity.generate());

  /// 由 [encodePrivateKey] 的输出重建。格式不对抛 [FormatException]。
  factory InterconnectDeviceKey.decodePrivateKey(String encoded) {
    final Uint8List d;
    try {
      d = leaderboardBase64UrlDecode(encoded.trim());
    } on FormatException {
      throw const FormatException('bad interconnect device key');
    }
    try {
      return InterconnectDeviceKey._(LeaderboardIdentity.fromPrivateKey(d));
    } on ArgumentError {
      throw const FormatException('bad interconnect device key');
    }
  }

  final LeaderboardIdentity _identity;

  /// 私钥的持久化形式：base64url(32 字节标量)。等同密码，不得进日志 / 备份。
  String encodePrivateKey() => leaderboardBase64Url(_identity.privateKey);

  /// 上报给 host 的公钥：base64url(SPKI)。
  String get pubkey => _identity.pubkeyBase64Url;

  /// 公钥指纹（base64url(sha256(spki))，43 字符），host 侧落库 / 比对用。
  String get fingerprint => interconnectDeviceKeyFingerprint(pubkey)!;

  /// 为本次配对会话签持有证明。
  String signPairProof({
    required String sessionId,
    required String hostNonce,
    required String clientNonce,
    required String clientDeviceId,
  }) => _identity.sign(
    interconnectPairDeviceProofString(
      sessionId: sessionId,
      hostNonce: hostNonce,
      clientNonce: clientNonce,
      clientDeviceId: clientDeviceId,
      devicePubkey: pubkey,
    ),
  );
}

/// 待签名串。所有字段都由 host 在本次会话里见过，改任何一个签名都对不上。
String interconnectPairDeviceProofString({
  required String sessionId,
  required String hostNonce,
  required String clientNonce,
  required String clientDeviceId,
  required String devicePubkey,
}) =>
    'fushi-pair-device-v1\n$sessionId\n$hostNonce\n$clientNonce\n'
    '$clientDeviceId\n$devicePubkey';

/// 公钥指纹；[pubkey] 不是合法 base64url 或不是 P-256 SPKI 时返回 null。
String? interconnectDeviceKeyFingerprint(String pubkey) {
  if (pubkey.isEmpty || pubkey.length > kInterconnectDevicePubkeyMaxChars) {
    return null;
  }
  final Uint8List spki;
  try {
    spki = leaderboardBase64UrlDecode(pubkey);
  } on FormatException {
    return null;
  }
  // 只判长度（P-256 SPKI 恒 91 字节）；曲线点合法性由
  // [verifyInterconnectPairDeviceProof] 负责——指纹只在验签通过后才会被落库。
  if (spki.length != 91) return null;
  return leaderboardBase64Url(crypto.sha256.convert(spki).bytes);
}

/// host 侧验签。任何格式错误都返回 false，不抛。
bool verifyInterconnectPairDeviceProof({
  required String sessionId,
  required String hostNonce,
  required String clientNonce,
  required String clientDeviceId,
  required String devicePubkey,
  required String proof,
}) {
  if (devicePubkey.length > kInterconnectDevicePubkeyMaxChars ||
      proof.isEmpty ||
      proof.length > kInterconnectDeviceProofMaxChars) {
    return false;
  }
  final Uint8List spki;
  try {
    spki = leaderboardBase64UrlDecode(devicePubkey);
  } on FormatException {
    return false;
  }
  return LeaderboardIdentity.verify(
    spki,
    interconnectPairDeviceProofString(
      sessionId: sessionId,
      hostNonce: hostNonce,
      clientNonce: clientNonce,
      clientDeviceId: clientDeviceId,
      devicePubkey: devicePubkey,
    ),
    proof,
  );
}
