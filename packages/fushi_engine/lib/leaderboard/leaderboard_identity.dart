// 排行榜账户身份：ECDSA P-256 设备密钥（设计：docs/specs/2026-09-28-leaderboard-accounts.md §3.1）。
//
// 账户 = 公钥。所有字节格式都要与 Worker（services/leaderboard/src/auth.js，WebCrypto）逐字节一致：
// - 公钥：X.509 SubjectPublicKeyInfo DER（= WebCrypto exportKey('spki')），65 字节未压缩点；
// - 账户 id：base64url(sha256(spki)) 前 16 字符（无填充），同时是好友码；
// - 签名：ECDSA/SHA-256，IEEE P1363（r‖s 各 32 字节大端）→ base64url 无填充。
//   k 用 RFC 6979 确定性派生：同一消息同一钥匙签名恒定，测试向量可复现，也不依赖系统熵。

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// P-256 SPKI DER 的固定前缀（SEQUENCE { AlgorithmIdentifier{ecPublicKey, prime256v1}, BIT STRING }）。
/// 后面紧跟 65 字节未压缩点 `04‖x‖y`，总长 91。
final Uint8List _spkiPrefix = Uint8List.fromList(const <int>[
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, //
  0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
  0x42, 0x00,
]);

const int _scalarBytes = 32;
const String _recoveryPrefix = 'FUSHI1-';
const int _recoveryKeyChars = 43; // base64url(32 字节) 无填充
const int _recoveryChecksumChars = 4;

final ECDomainParameters _p256 = ECCurve_secp256r1();

/// base64url 无填充。
String leaderboardBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// base64url（有无填充都收）；非法输入抛 [FormatException]。
Uint8List leaderboardBase64UrlDecode(String s) =>
    base64Url.decode(base64Url.normalize(s));

Uint8List _sha256(List<int> bytes) =>
    Uint8List.fromList(crypto.sha256.convert(bytes).bytes);

BigInt _bytesToBigInt(List<int> bytes) {
  BigInt out = BigInt.zero;
  for (final int b in bytes) {
    out = (out << 8) | BigInt.from(b);
  }
  return out;
}

/// 大端补零到 [length] 字节；超长抛 [ArgumentError]。
Uint8List _bigIntToBytes(BigInt value, int length) {
  final Uint8List out = Uint8List(length);
  BigInt v = value;
  for (int i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  if (v != BigInt.zero) {
    throw ArgumentError.value(value, 'value', 'does not fit $length bytes');
  }
  return out;
}

bool _validScalar(BigInt d) => d > BigInt.zero && d < _p256.n;

/// 一把排行榜账户钥匙。不可变；私钥只在内存里，持久化由调用方负责（app 按 Profile 存数据目录下的本机文件，不进偏好表 / 备份）。
class LeaderboardIdentity {
  LeaderboardIdentity._(this._d, this._spki);

  /// 生成新钥匙。[random] 缺省用 [Random.secure]（测试可注入确定性源）。
  static LeaderboardIdentity generate({Random? random}) {
    final Random rng = random ?? Random.secure();
    while (true) {
      final Uint8List bytes = Uint8List(_scalarBytes);
      for (int i = 0; i < bytes.length; i++) {
        bytes[i] = rng.nextInt(256);
      }
      // 拒绝采样：落在 [1, n-1] 外就重抽（概率约 2^-32），不取模避免偏差。
      if (_validScalar(_bytesToBigInt(bytes))) {
        return LeaderboardIdentity.fromPrivateKey(bytes);
      }
    }
  }

  /// 由 32 字节大端私钥标量重建。长度不对或不在 [1, n-1] 抛 [ArgumentError]。
  factory LeaderboardIdentity.fromPrivateKey(Uint8List d32) {
    if (d32.length != _scalarBytes) {
      throw ArgumentError.value(d32.length, 'd32', 'must be 32 bytes');
    }
    final BigInt d = _bytesToBigInt(d32);
    if (!_validScalar(d)) {
      throw ArgumentError.value(d32, 'd32', 'scalar out of range');
    }
    final ECPoint q = (_p256.G * d)!;
    final Uint8List spki = Uint8List.fromList(<int>[
      ..._spkiPrefix,
      ...q.getEncoded(false),
    ]);
    return LeaderboardIdentity._(d, spki);
  }

  /// 解析恢复码 `FUSHI1-<base64url(d)>-<base64url(sha256(d))前 4 字符>`。
  /// 容忍首尾空白；前缀 / 长度 / 校验和 / 标量任一不对抛 [FormatException]。
  static LeaderboardIdentity fromRecoveryCode(String code) {
    final String s = code.trim();
    const int bodyLen = _recoveryKeyChars + 1 + _recoveryChecksumChars;
    if (!s.startsWith(_recoveryPrefix) ||
        s.length != _recoveryPrefix.length + bodyLen) {
      throw const FormatException('not a Fushi recovery code');
    }
    final String body = s.substring(_recoveryPrefix.length);
    // base64url 字符集本身含 '-'，所以按定长切，不按分隔符 split。
    if (body[_recoveryKeyChars] != '-') {
      throw const FormatException('not a Fushi recovery code');
    }
    final String keyPart = body.substring(0, _recoveryKeyChars);
    final String checksum = body.substring(_recoveryKeyChars + 1);
    final Uint8List d;
    try {
      d = leaderboardBase64UrlDecode(keyPart);
    } on FormatException {
      throw const FormatException('recovery code is not base64url');
    }
    if (d.length != _scalarBytes || _recoveryChecksum(d) != checksum) {
      throw const FormatException('recovery code checksum mismatch');
    }
    try {
      return LeaderboardIdentity.fromPrivateKey(d);
    } on ArgumentError {
      throw const FormatException('recovery code key out of range');
    }
  }

  final BigInt _d;
  final Uint8List _spki;

  /// 32 字节大端私钥标量（副本）。
  Uint8List get privateKey => _bigIntToBytes(_d, _scalarBytes);

  /// SubjectPublicKeyInfo DER（副本），与 WebCrypto `exportKey('spki')` 逐字节一致。
  Uint8List get spki => Uint8List.fromList(_spki);

  /// 注册时上传的公钥：base64url(spki)。
  String get pubkeyBase64Url => leaderboardBase64Url(_spki);

  /// 账户 id / 好友码：base64url(sha256(spki)) 前 16 字符。
  String get accountId => leaderboardAccountIdFromSpki(_spki);

  /// ECDSA/SHA-256 签 [message] 的 UTF-8 字节，返回 P1363（r‖s）base64url。
  String sign(String message) {
    final ECDSASigner signer = ECDSASigner(
      SHA256Digest(),
      HMac(SHA256Digest(), 64),
    );
    signer.init(
      true,
      PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(_d, _p256)),
    );
    final ECSignature sig =
        signer.generateSignature(Uint8List.fromList(utf8.encode(message)))
            as ECSignature;
    return leaderboardBase64Url(<int>[
      ..._bigIntToBytes(sig.r, _scalarBytes),
      ..._bigIntToBytes(sig.s, _scalarBytes),
    ]);
  }

  /// 导出恢复码（含私钥，换设备用；等同密码，不得进日志 / 备份外传）。
  String toRecoveryCode() {
    final Uint8List d = privateKey;
    return '$_recoveryPrefix${leaderboardBase64Url(d)}-${_recoveryChecksum(d)}';
  }

  /// 用 SPKI 公钥验 P1363 base64url 签名。任何格式错误都返回 false，不抛。
  static bool verify(
    Uint8List spki,
    String message,
    String signatureBase64Url,
  ) {
    final ECPublicKey? key = _publicKeyFromSpki(spki);
    if (key == null) return false;
    final Uint8List sig;
    try {
      sig = leaderboardBase64UrlDecode(signatureBase64Url);
    } on FormatException {
      return false;
    }
    if (sig.length != 2 * _scalarBytes) return false;
    final BigInt r = _bytesToBigInt(sig.sublist(0, _scalarBytes));
    final BigInt s = _bytesToBigInt(sig.sublist(_scalarBytes));
    if (!_validScalar(r) || !_validScalar(s)) return false;
    final ECDSASigner verifier = ECDSASigner(SHA256Digest());
    verifier.init(false, PublicKeyParameter<ECPublicKey>(key));
    return verifier.verifySignature(
      Uint8List.fromList(utf8.encode(message)),
      ECSignature(r, s),
    );
  }
}

/// base64url(sha256(spki)) 前 16 字符（与 auth.js `accountIdFromSpki` 一致）。
String leaderboardAccountIdFromSpki(List<int> spki) =>
    leaderboardBase64Url(_sha256(spki)).substring(0, 16);

String _recoveryChecksum(Uint8List d) =>
    leaderboardBase64Url(_sha256(d)).substring(0, _recoveryChecksumChars);

ECPublicKey? _publicKeyFromSpki(Uint8List spki) {
  if (spki.length != _spkiPrefix.length + 65) return null;
  for (int i = 0; i < _spkiPrefix.length; i++) {
    if (spki[i] != _spkiPrefix[i]) return null;
  }
  try {
    final ECPoint? q = _p256.curve.decodePoint(
      spki.sublist(_spkiPrefix.length),
    );
    if (q == null || q.isInfinity) return null;
    return ECPublicKey(q, _p256);
  } on Object {
    return null;
  }
}
