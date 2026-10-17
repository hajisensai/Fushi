// 安装身份：安装统计心跳（`POST /v1/ping`）与反馈附带的安装 id 的密码学身份。
// 服务端对应实现：services/leaderboard/src/installs.js（`verifyInstallProof`），字节格式逐字节一致。
//
// 推导链（全部确定性，同一台机器重装 / 清数据后结果不变）：
//   machineId（系统机器标识，原值**绝不上传**）
//     → seed = HMAC-SHA256(key = "fushi-install-id-v1", machineId)
//     → P-256 私钥 d = (seed mod (n − 1)) + 1          （落在 [1, n−1]，偏差 < 2^-32）
//     → 公钥 SPKI（与 WebCrypto exportKey('spki') 一致，复用 [LeaderboardIdentity]）
//     → installId = SHA-256(spki) 前 16 字节，按 UUID 排版并置 version=4 / variant=10
//
// installId 保持「小写 UUID v4」形状：与已上线的 Worker（只认 UUID v4 正则）和既有列 / 索引兼容，
// 新客户端先于新 Worker 上线也照样被收（按未验证计）。它本身是哈希，形状上与随机 v4 不可区分。
//
// 防伪：请求带 `X-Fushi-Install-Key / -Time / -Sig / -Pow` 四个头。签名覆盖
// `fushi-install-v1\n` + 账户签名同一套签名串（方法 + 路径 + 时刻 + 请求体哈希，见
// leaderboard_signing.dart），服务端核 installId == fp(公钥)、验签、±5 分钟时效、签名串去重。
// 头名与账户签名（X-Fushi-Account / -Time / -Sig）分开：反馈可以同时带账户签名与安装签名。
//
// 工作量证明：sha256("fip1|<installId>|<nonce>") 的前 [kInstallPowBits] 位为 0。前缀 + id + 分隔符
// 共 42 字节，nonce ≤ 13 位时整条输入 ≤ 55 字节、落在一个 SHA-256 块内（18 位难度下实际 nonce
// 通常只有 6–7 位；服务端允许到 15 位，那时是两块，只是慢一点）。installId 已是公钥指纹，
// 不必再把公钥放进去也绑定了钥匙。
// nonce 只依赖 installId，算一次可永久复用（调用方持久化），服务端校验只需一次哈希。
// 它只抬高「批量造新安装」的成本，挡不住决心造假的人——服务端无法核验 machineId 真伪，
// 任何人都能拿随机种子造出新安装；它保证的是**冒充不了已有安装**、且每造一个新 id 都要付出
// 钥匙生成 + PoW + 每 IP 限流的代价。

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart' show ECCurve_secp256r1;

import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_signing.dart';

/// HMAC 的固定 key（版本化：换推导方式时换 key，旧 id 自然作废）。
const String kInstallSeedHmacKey = 'fushi-install-id-v1';

/// 安装签名的域分隔前缀（与账户签名串区分，签名不能跨用途挪用）。
const String kInstallSignaturePrefix = 'fushi-install-v1\n';

/// 工作量证明难度（前导 0 位数，与 installs.js `INSTALL_POW_BITS` 一致）。
/// 2^18 ≈ 26 万次 SHA-256：桌面 AOT 约数百毫秒，移动端一两秒，只在新安装第一次算。
const int kInstallPowBits = 18;

/// 工作量证明输入的域前缀。
const String kInstallPowPrefix = 'fip1|';

/// 请求头名（与 installs.js 一致）。
const String kInstallKeyHeader = 'X-Fushi-Install-Key';
const String kInstallTimeHeader = 'X-Fushi-Install-Time';
const String kInstallSigHeader = 'X-Fushi-Install-Sig';
const String kInstallPowHeader = 'X-Fushi-Install-Pow';

final BigInt _n = ECCurve_secp256r1().n;

Uint8List _hmacSha256(List<int> key, List<int> message) =>
    Uint8List.fromList(crypto.Hmac(crypto.sha256, key).convert(message).bytes);

BigInt _bytesToBigInt(List<int> bytes) {
  BigInt out = BigInt.zero;
  for (final int b in bytes) {
    out = (out << 8) | BigInt.from(b);
  }
  return out;
}

Uint8List _bigIntTo32(BigInt value) {
  final Uint8List out = Uint8List(32);
  BigInt v = value;
  for (int i = 31; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

/// **纯函数**：机器标识的规范化（去首尾空白、转小写）。同一台机器不同 API 给出的大小写
/// 不一（macOS IOPlatformUUID 大写、Windows MachineGuid 小写），规范化后推导才稳定。
String normalizeInstallMachineId(String machineId) =>
    machineId.trim().toLowerCase();

/// 已知在大量设备上相同的机器标识：systemd 首启前的 `uninitialized`、Android 2.2 时代大批
/// 设备共用的 ANDROID_ID `9774d56d682e549c`。
const Set<String> _sharedMachineIds = <String>{
  'uninitialized',
  '9774d56d682e549c',
};

/// **纯函数**：机器标识是否可用作种子。空串、过短、全是同一个字符（全 0 之类的占位值）、
/// [_sharedMachineIds] 都不可用——这些值在大量机器上相同，用了会把它们算成同一个安装。
bool isUsableInstallMachineId(String machineId) {
  final String v = normalizeInstallMachineId(machineId);
  if (v.length < 8 || _sharedMachineIds.contains(v)) return false;
  final String compact = v.replaceAll(RegExp(r'[-{}\s]'), '');
  if (compact.isEmpty) return false;
  return compact.split('').toSet().length > 1;
}

/// **纯函数**：seed = HMAC-SHA256(key = [kInstallSeedHmacKey], [material])。
/// [material] 是规范化后的机器标识（或回退时的本机随机种子，带 `random:` 前缀与之区分）。
Uint8List installSeedFrom(String material) =>
    _hmacSha256(utf8.encode(kInstallSeedHmacKey), utf8.encode(material));

/// **纯函数**：32 字节 seed → P-256 私钥标量（大端 32 字节），d = (seed mod (n−1)) + 1。
Uint8List installPrivateKeyFromSeed(Uint8List seed) {
  if (seed.length != 32) {
    throw ArgumentError.value(seed.length, 'seed', 'must be 32 bytes');
  }
  final BigInt d = (_bytesToBigInt(seed) % (_n - BigInt.one)) + BigInt.one;
  return _bigIntTo32(d);
}

/// **纯函数**：公钥 SPKI → installId（UUID v4 形状的公钥指纹，小写）。
String installIdFromSpki(List<int> spki) {
  final List<int> h = crypto.sha256.convert(spki).bytes.sublist(0, 16);
  h[6] = (h[6] & 0x0f) | 0x40;
  h[8] = (h[8] & 0x3f) | 0x80;
  final String hexStr = h
      .map((int b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hexStr.substring(0, 8)}-${hexStr.substring(8, 12)}-'
      '${hexStr.substring(12, 16)}-${hexStr.substring(16, 20)}-'
      '${hexStr.substring(20)}';
}

/// 前导 0 位数是否 ≥ [bits]。
bool _leadingZeroBits(List<int> digest, int bits) {
  int remaining = bits;
  for (final int b in digest) {
    if (remaining <= 0) return true;
    if (remaining >= 8) {
      if (b != 0) return false;
      remaining -= 8;
    } else {
      return (b >> (8 - remaining)) == 0;
    }
  }
  return remaining <= 0;
}

/// **纯函数**：[nonce] 是否满足 [installId] 的工作量证明。
bool installPowValid(
  String installId,
  String nonce, {
  int bits = kInstallPowBits,
}) {
  if (!RegExp(r'^[0-9]{1,15}$').hasMatch(nonce)) return false;
  final List<int> digest = crypto.sha256
      .convert(utf8.encode('$kInstallPowPrefix$installId|$nonce'))
      .bytes;
  return _leadingZeroBits(digest, bits);
}

/// **纯函数**：从 0 起逐个找满足工作量证明的最小 nonce（十进制串）。同步、CPU 密集：
/// app 里经 [solveInstallPowInBackground] 放后台 isolate 跑，别在 UI isolate 直接调。
String solveInstallPow(String installId, {int bits = kInstallPowBits}) {
  final List<int> prefix = utf8.encode('$kInstallPowPrefix$installId|');
  for (int nonce = 0; ; nonce++) {
    final List<int> digest = crypto.sha256.convert(<int>[
      ...prefix,
      ...ascii.encode('$nonce'),
    ]).bytes;
    if (_leadingZeroBits(digest, bits)) return '$nonce';
  }
}

/// [solveInstallPow] 的后台 isolate 版本（不卡 UI）。
Future<String> solveInstallPowInBackground(
  String installId, {
  int bits = kInstallPowBits,
}) => Isolate.run<String>(() => solveInstallPow(installId, bits: bits));

/// 一个安装的签名身份（私钥只在内存里；推导自 seed，不持久化私钥）。
class InstallIdentity {
  InstallIdentity._(this._key) : installId = installIdFromSpki(_key.spki);

  /// 由 32 字节 seed 确定性推导。
  factory InstallIdentity.fromSeed(Uint8List seed) => InstallIdentity._(
    LeaderboardIdentity.fromPrivateKey(installPrivateKeyFromSeed(seed)),
  );

  /// 由机器标识推导（[isUsableInstallMachineId] 为假时抛 [ArgumentError]）。
  factory InstallIdentity.fromMachineId(String machineId) {
    if (!isUsableInstallMachineId(machineId)) {
      throw ArgumentError.value('<redacted>', 'machineId', 'not usable');
    }
    return InstallIdentity.fromSeed(
      installSeedFrom(normalizeInstallMachineId(machineId)),
    );
  }

  /// 机器标识取不到时的回退：本机持久化的随机种子（现行为：重装即变）。
  factory InstallIdentity.fromLocalRandom(String randomSeed) =>
      InstallIdentity.fromSeed(installSeedFrom('random:${randomSeed.trim()}'));

  final LeaderboardIdentity _key;

  /// UUID v4 形状的公钥指纹。
  final String installId;

  /// base64url(spki)，随请求放在 [kInstallKeyHeader]。
  String get pubkeyBase64Url => _key.pubkeyBase64Url;

  /// SPKI DER（副本）。
  Uint8List get spki => _key.spki;

  /// 安装签名串：[kInstallSignaturePrefix] + 账户签名同一套签名串。
  static String signingString(
    String method,
    String pathWithQuery,
    int timeMs,
    List<int> body,
  ) =>
      '$kInstallSignaturePrefix'
      '${leaderboardSigningString(method, pathWithQuery, timeMs, body)}';

  /// P1363 base64url 签名。
  String sign(String message) => _key.sign(message);
}

/// 随请求出示的安装证明：身份 + 已算好的工作量证明 nonce。
class InstallAttestation {
  InstallAttestation(this.identity, this.powNonce);

  final InstallIdentity identity;
  final String powNonce;

  String get installId => identity.installId;

  /// 给一个具体请求出示的四个头。[pathWithQuery] 必须与服务端看到的
  /// `URL.pathname + URL.search` 一致；[body] 是实际发出的请求体字节。
  Map<String, String> headersFor(
    String method,
    String pathWithQuery,
    int timeMs,
    List<int> body,
  ) => <String, String>{
    kInstallKeyHeader: identity.pubkeyBase64Url,
    kInstallTimeHeader: '$timeMs',
    kInstallSigHeader: identity.sign(
      InstallIdentity.signingString(method, pathWithQuery, timeMs, body),
    ),
    kInstallPowHeader: powNonce,
  };
}
