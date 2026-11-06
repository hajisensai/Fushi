import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// host 自身的 TLS 身份：一对 EC P-256 密钥 + 自签证书，落盘 PEM。
class FushiTlsIdentity {
  const FushiTlsIdentity({
    required this.certificatePem,
    required this.privateKeyPem,
    required this.fingerprintSha256,
  });

  final String certificatePem;
  final String privateKeyPem;
  final String fingerprintSha256;
}

/// 生成自签 EC P-256 证书 + PKCS#8 私钥 PEM 的纯函数封装。
///
/// DER 在这里手工拼，签名走 native/fushi_compute（`ffc_crypto_p256_sign_sha256`，RFC 6979
/// 确定性 k）。字节布局与原 basic_utils 5.7.0（`X509Utils.generateSelfSignedCertificate` /
/// `CryptoUtils.encodePrivateEcdsaKeyToPkcs8`）逐字节一致——包括它的非标准细节：签名算法
/// 带 `NULL` 参数、IP 也编码成 dNSName、CN 用 PrintableString、证书 PEM 行间是 `\r\n`。
/// 固定向量见 packages/fushi_compute/test/crypto/crypto_vectors_v2.json。
class FushiSelfSignedCertGenerator {
  FushiSelfSignedCertGenerator._();

  /// 生成自签 EC P-256 证书 + 私钥 PEM。
  ///
  /// * [commonName]：写进 CN 的设备标识（deviceId / 设备名）。
  /// * [sanIpAddresses]：写进 subjectAltName 的所有本机 IPv4（应含 127.0.0.1）。
  ///   与旧实现一样把 SAN 一律编码为 dNSName，IP 串只为兼容/调试展示，真正的
  ///   身份校验走 client 侧指纹钉扎，不依赖 SAN/hostname 匹配。
  /// * [validity]：证书有效期，默认 30 年（按用户决策；指纹钉扎不依赖到期）。
  static ({String certificatePem, String privateKeyPem}) generate({
    required String commonName,
    required List<String> sanIpAddresses,
    Duration validity = const Duration(days: 365 * 30),
  }) {
    // BUG-3196：CN 与 SAN 里的名字必须是 ASCII（PrintableString / dNSName）。Windows
    // 计算机名可以是中文（「大祥老师的电脑」），身份校验走指纹钉扎，名字只是标签，归一即可。
    final String safeName = tlsSafeCommonName(commonName);
    final List<String> sans = <String>[safeName, ...sanIpAddresses];

    // notAfter 用 UTCTime（YYMMDD，2 位年），只能表示 1950-2049：>= 2050 会被 RFC 5280
    // 滑窗解释成 19xx（"已过期"）。指纹钉扎不看到期，但为不产出对标准校验器/调试糊弄的
    // 证书，把 notAfter 上限钳到 2049-12-31。请求 30 年从 notBefore 起算若越过 2049 即取边界。
    final DateTime notBefore = DateTime.now().toUtc();
    final DateTime requestedNotAfter = notBefore.add(validity);
    final DateTime utcTimeCeiling = DateTime.utc(2049, 12, 31, 23, 59, 59);
    final DateTime notAfter = requestedNotAfter.isAfter(utcTimeCeiling)
        ? utcTimeCeiling
        : requestedNotAfter;
    final int days = notAfter.difference(notBefore).inDays;

    final ({Uint8List tbsDer, String certificatePem, String privateKeyPem})
    generated = build(
      privateKey: LeaderboardIdentity.generate().privateKey,
      commonName: safeName,
      sans: sans,
      notBefore: notBefore,
      days: days,
    );
    return (
      certificatePem: generated.certificatePem,
      privateKeyPem: generated.privateKeyPem,
    );
  }

  /// 确定性构造（给定私钥 / 时间 / 名字）。[commonName] / [sans] 须已是 ASCII。
  @visibleForTesting
  static ({Uint8List tbsDer, String certificatePem, String privateKeyPem})
  build({
    required Uint8List privateKey,
    required String commonName,
    required List<String> sans,
    required DateTime notBefore,
    required int days,
  }) {
    final FushiComputeCrypto crypto = FushiComputeCrypto.instance;
    final Uint8List point = crypto.p256PublicKey(privateKey);
    final Uint8List name = _der(0x30, <List<int>>[
      _der(0x31, <List<int>>[
        _der(0x30, <List<int>>[
          _oidCommonName,
          _der(0x13, <List<int>>[ascii.encode(commonName)]),
        ]),
      ]),
    ]);
    final Uint8List algorithm = _der(0x30, <List<int>>[
      _oidEcPublicKey,
      _oidPrime256v1,
    ]);
    final Uint8List publicKeyBits = _der(0x03, <List<int>>[
      const <int>[0x00],
      point,
    ]);
    final Uint8List sanList = _der(0x30, <List<int>>[
      for (final String san in sans) _der(0x82, <List<int>>[ascii.encode(san)]),
    ]);
    final Uint8List tbs = _der(0x30, <List<int>>[
      _der(0xa0, <List<int>>[
        _derInteger(const <int>[2]),
      ]),
      _derInteger(const <int>[1]),
      _sigAlg,
      name,
      _der(0x30, <List<int>>[
        _utcTime(notBefore),
        _utcTime(notBefore.add(Duration(days: days))),
      ]),
      name,
      _der(0x30, <List<int>>[algorithm, publicKeyBits]),
      _der(0xa3, <List<int>>[
        _der(0x30, <List<int>>[
          _der(0x30, <List<int>>[
            _oidSubjectAltName,
            _der(0x04, <List<int>>[sanList]),
          ]),
        ]),
      ]),
    ]);
    final Uint8List sig = crypto.p256SignSha256(privateKey, tbs);
    final Uint8List cert = _der(0x30, <List<int>>[
      tbs,
      _sigAlg,
      _der(0x03, <List<int>>[
        const <int>[0x00],
        _der(0x30, <List<int>>[
          _derInteger(sig.sublist(0, 32)),
          _derInteger(sig.sublist(32)),
        ]),
      ]),
    ]);
    final String certBase64 = base64.encode(cert);
    final List<String> lines = <String>[
      for (int i = 0; i < certBase64.length; i += 64)
        certBase64.substring(i, min(i + 64, certBase64.length)),
    ];
    final String certificatePem =
        '-----BEGIN CERTIFICATE-----\n${lines.join('\r\n')}\n'
        '-----END CERTIFICATE-----';

    // PKCS#8 PrivateKeyInfo { 0, {ecPublicKey, prime256v1}, OCTET STRING ECPrivateKey
    // { 1, d, [1] publicKey } }（ECPrivateKey 里不带 [0] 曲线参数，与旧实现同）。
    final Uint8List pkcs8 = _der(0x30, <List<int>>[
      _derInteger(const <int>[0]),
      algorithm,
      _der(0x04, <List<int>>[
        _der(0x30, <List<int>>[
          _derInteger(const <int>[1]),
          _der(0x04, <List<int>>[privateKey]),
          _der(0xa1, <List<int>>[publicKeyBits]),
        ]),
      ]),
    ]);
    final String keyBase64 = base64
        .encode(pkcs8)
        .replaceAllMapped(RegExp(r'.{64}'), (Match m) => '${m.group(0)}\n');
    final String privateKeyPem =
        '-----BEGIN PRIVATE KEY-----\n$keyBase64\n-----END PRIVATE KEY-----';
    return (
      tbsDer: tbs,
      certificatePem: certificatePem,
      privateKeyPem: privateKeyPem,
    );
  }

  // OID 2.5.4.3 / 1.2.840.10045.2.1 / 1.2.840.10045.3.1.7 / 2.5.29.17，以及
  // ecdsa-with-SHA256（1.2.840.10045.4.3.2）后跟 NULL 参数的 AlgorithmIdentifier。
  static const List<int> _oidCommonName = <int>[0x06, 0x03, 0x55, 0x04, 0x03];
  static const List<int> _oidEcPublicKey = <int>[
    0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, //
  ];
  static const List<int> _oidPrime256v1 = <int>[
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, //
  ];
  static const List<int> _oidSubjectAltName = <int>[
    0x06, 0x03, 0x55, 0x1d, 0x11, //
  ];
  static const List<int> _sigAlg = <int>[
    0x30, 0x0c, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02, //
    0x05, 0x00,
  ];

  /// DER TLV：[tag] + 定长长度 + [parts] 拼接。
  static Uint8List _der(int tag, List<List<int>> parts) {
    final BytesBuilder body = BytesBuilder(copy: false);
    for (final List<int> part in parts) {
      body.add(part);
    }
    final int length = body.length;
    final BytesBuilder out = BytesBuilder(copy: false)..addByte(tag);
    if (length < 0x80) {
      out.addByte(length);
    } else if (length < 0x100) {
      out.add(<int>[0x81, length]);
    } else {
      out.add(<int>[0x82, length >> 8, length & 0xff]);
    }
    out.add(body.takeBytes());
    return out.takeBytes();
  }

  /// 无符号大端整数 → DER INTEGER（去前导 0，最高位为 1 时补一个 0）。
  static Uint8List _derInteger(List<int> unsigned) {
    int start = 0;
    while (start < unsigned.length - 1 && unsigned[start] == 0) {
      start++;
    }
    final List<int> trimmed = unsigned.sublist(start);
    return _der(0x02, <List<int>>[
      if (trimmed[0] & 0x80 != 0) const <int>[0x00],
      trimmed,
    ]);
  }

  /// UTCTime `YYMMDDHHMMSSZ`（UTC）。
  static Uint8List _utcTime(DateTime time) {
    final DateTime t = time.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final String text =
        '${two(t.year % 100)}${two(t.month)}${two(t.day)}'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
    return _der(0x17, <List<int>>[ascii.encode(text)]);
  }
}

/// BUG-3196：把任意设备名归一成证书里可编码的名字。
///
/// 证书的 CN 与 dNSName SAN 只能装 ASCII；这里只留主机名字符（字母、数字、`-`、
/// `.`），去掉首尾的 `-` / `.`，截到 63 字符（DNS 单段上限）。一个合法字符都不剩
/// （纯中文计算机名）时退回固定标签——名字不参与任何校验，client 只认指纹。
String tlsSafeCommonName(String name) {
  String cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9.-]'), '');
  cleaned = cleaned.replaceAll(RegExp(r'^[.-]+|[.-]+$'), '');
  if (cleaned.length > 63) {
    cleaned = cleaned.substring(0, 63).replaceAll(RegExp(r'[.-]+$'), '');
  }
  return cleaned.isEmpty ? kTlsFallbackCommonName : cleaned;
}

/// 设备名里一个可用字符都没有时证书用的名字。
const String kTlsFallbackCommonName = 'fushi-host';

/// 生成 / 加载 / 持久化 host TLS 身份。私钥仅落数据目录下 sync-tls/ 子目录，
/// 靠 OS 文件权限保护（取舍 D：不接系统密钥库）。
class FushiTlsIdentityStore {
  FushiTlsIdentityStore({required this.dataDir});

  /// 数据目录（通常是 getApplicationSupportDirectory 的路径）。私钥落
  /// <dataDir>/sync-tls/。
  final String dataDir;

  static const String _subDir = 'sync-tls';
  static const String _certFile = 'identity-cert.pem';
  static const String _keyFile = 'identity-key.pem';

  String get _tlsDir => p.join(dataDir, _subDir);
  String get _certPath => p.join(_tlsDir, _certFile);
  String get _keyPath => p.join(_tlsDir, _keyFile);

  /// 已有则加载，否则生成 EC P-256 自签证书并落盘。
  Future<FushiTlsIdentity> loadOrCreate() async {
    final certFile = File(_certPath);
    final keyFile = File(_keyPath);
    if (await certFile.exists() && await keyFile.exists()) {
      final certificatePem = await certFile.readAsString();
      final privateKeyPem = await keyFile.readAsString();
      return FushiTlsIdentity(
        certificatePem: certificatePem,
        privateKeyPem: privateKeyPem,
        fingerprintSha256: fingerprintOf(certificatePem),
      );
    }
    return _generateAndPersist();
  }

  /// 强制重新生成（用户重置证书时调用，会使旧指纹钉扎失效）。
  Future<FushiTlsIdentity> regenerate() => _generateAndPersist();

  Future<FushiTlsIdentity> _generateAndPersist() async {
    await Directory(_tlsDir).create(recursive: true);

    final String commonName = Platform.localHostname.isNotEmpty
        ? Platform.localHostname
        : 'fushi-device';
    final List<String> ipv4 = await _localIpv4Addresses();

    final ({String certificatePem, String privateKeyPem}) generated =
        FushiSelfSignedCertGenerator.generate(
          commonName: commonName,
          sanIpAddresses: ipv4,
        );

    // 私钥先写内容再 chmod 0600（POSIX 有效，Windows 无操作，靠 app 私有目录 + NTFS ACL）。
    final keyFile = File(_keyPath);
    await keyFile.writeAsString(generated.privateKeyPem, flush: true);
    await _tightenPermissions(_keyPath);

    final certFile = File(_certPath);
    await certFile.writeAsString(generated.certificatePem, flush: true);

    return FushiTlsIdentity(
      certificatePem: generated.certificatePem,
      privateKeyPem: generated.privateKeyPem,
      fingerprintSha256: fingerprintOf(generated.certificatePem),
    );
  }

  /// 计算 PEM 证书的 SHA-256 指纹（DER -> sha256 -> 小写 hex 冒号分隔）。
  static String fingerprintOf(String certificatePem) {
    final List<int> der = _pemToDer(certificatePem);
    final Digest digest = sha256.convert(der);
    return _hexColon(digest.bytes);
  }

  /// 收紧私钥文件权限到 0600（仅属主可读写）。Windows 上 chmod 不存在，
  /// 静默跳过（靠 NTFS per-app ACL + app 私有目录隔离，取舍 D 的已知边界）。
  static Future<void> _tightenPermissions(String path) async {
    if (Platform.isWindows) return;
    try {
      final result = await Process.run('chmod', <String>['600', path]);
      // 失败不致命：私钥仍在 app 私有目录里，最多权限偏宽，不阻断功能。
      if (result.exitCode != 0) return;
    } on ProcessException {
      // chmod 不可用（非 POSIX 环境）时静默放过。
      return;
    }
  }

  /// 枚举所有本机 IPv4（含回环 127.0.0.1），用于写入证书 SAN。
  static Future<List<String>> _localIpv4Addresses() async {
    final List<String> result = <String>['127.0.0.1'];
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              !result.contains(addr.address)) {
            result.add(addr.address);
          }
        }
      }
    } on Object {
      // 枚举失败（受限平台）只用 127.0.0.1；指纹钉扎不依赖 SAN。
    }
    return result;
  }

  /// 把单证书 PEM 解出 DER 字节（取第一个 CERTIFICATE block 的 base64）。
  static List<int> _pemToDer(String pem) {
    const begin = '-----BEGIN CERTIFICATE-----';
    const end = '-----END CERTIFICATE-----';
    final startIdx = pem.indexOf(begin);
    if (startIdx < 0) {
      throw const FormatException('PEM 中未找到 CERTIFICATE block');
    }
    final bodyStart = startIdx + begin.length;
    final endIdx = pem.indexOf(end, bodyStart);
    if (endIdx < 0) {
      throw const FormatException('PEM 中 CERTIFICATE block 未正确闭合');
    }
    final base64Body = pem
        .substring(bodyStart, endIdx)
        .replaceAll('\r', '')
        .replaceAll('\n', '')
        .replaceAll(' ', '');
    return base64.decode(base64Body);
  }

  /// 把字节数组格式化为小写 hex、冒号分隔（aa:bb:cc）。
  static String _hexColon(List<int> bytes) {
    final buf = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      if (i > 0) buf.write(':');
      buf.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }
}
