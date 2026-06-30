import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart' hide Digest;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// host 自身的 TLS 身份：一对 EC P-256 密钥 + 自签证书，落盘 PEM。
class HibikiTlsIdentity {
  const HibikiTlsIdentity({
    required this.certificatePem,
    required this.privateKeyPem,
    required this.fingerprintSha256,
  });

  final String certificatePem;
  final String privateKeyPem;
  final String fingerprintSha256;
}

/// 用 basic_utils（纯 Dart：pointycastle + asn1lib，无原生）生成自签
/// EC P-256 证书 + 私钥 PEM 的纯函数封装。私钥以 PKCS#8 PEM 输出。
class HibikiSelfSignedCertGenerator {
  HibikiSelfSignedCertGenerator._();

  /// 生成自签 EC P-256 证书 + 私钥 PEM。
  ///
  /// * [commonName]：写进 CN 的设备标识（deviceId / 设备名）。
  /// * [sanIpAddresses]：写进 subjectAltName 的所有本机 IPv4（应含 127.0.0.1）。
  ///   basic_utils 把 SAN 一律编码为 dNSName，IP 串只为兼容/调试展示，真正的
  ///   身份校验走 client 侧指纹钉扎，不依赖 SAN/hostname 匹配。
  /// * [validity]：证书有效期，默认 30 年（按用户决策；指纹钉扎不依赖到期）。
  static ({String certificatePem, String privateKeyPem}) generate({
    required String commonName,
    required List<String> sanIpAddresses,
    Duration validity = const Duration(days: 365 * 30),
  }) {
    final AsymmetricKeyPair<PublicKey, PrivateKey> pair =
        CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
    final privateKey = pair.privateKey as ECPrivateKey;
    final publicKey = pair.publicKey as ECPublicKey;

    final dn = <String, String>{'CN': commonName};
    final sans = <String>[
      commonName,
      ...sanIpAddresses,
    ];

    final String csrPem = X509Utils.generateEccCsrPem(
      dn,
      privateKey,
      publicKey,
      san: sans,
    );

    // basic_utils 用 ASN1UtcTime 编码 notAfter（YYMMDD，2 位年）。UTCTime 只能
    // 表示 1950-2049：notAfter >= 2050 会被 RFC 5280 滑窗解释成 19xx（"已过期"）。
    // 指纹钉扎不看到期，但为不产出对标准校验器/调试糊弄的证书，把 notAfter
    // 上限钳到 2049-12-31。请求 30 年从 notBefore 起算若越过 2049 即取边界。
    final DateTime notBefore = DateTime.now().toUtc();
    final DateTime requestedNotAfter = notBefore.add(validity);
    final DateTime utcTimeCeiling = DateTime.utc(2049, 12, 31, 23, 59, 59);
    final DateTime notAfter = requestedNotAfter.isAfter(utcTimeCeiling)
        ? utcTimeCeiling
        : requestedNotAfter;
    final int days = notAfter.difference(notBefore).inDays;

    final String certificatePem = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csrPem,
      days,
      sans: sans,
      notBefore: notBefore,
    );

    final String privateKeyPem =
        CryptoUtils.encodePrivateEcdsaKeyToPkcs8(privateKey);

    return (certificatePem: certificatePem, privateKeyPem: privateKeyPem);
  }
}

/// 生成 / 加载 / 持久化 host TLS 身份。私钥仅落数据目录下 sync-tls/ 子目录，
/// 靠 OS 文件权限保护（取舍 D：不接系统密钥库）。
class HibikiTlsIdentityStore {
  HibikiTlsIdentityStore({required this.dataDir});

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
  Future<HibikiTlsIdentity> loadOrCreate() async {
    final certFile = File(_certPath);
    final keyFile = File(_keyPath);
    if (await certFile.exists() && await keyFile.exists()) {
      final certificatePem = await certFile.readAsString();
      final privateKeyPem = await keyFile.readAsString();
      return HibikiTlsIdentity(
        certificatePem: certificatePem,
        privateKeyPem: privateKeyPem,
        fingerprintSha256: fingerprintOf(certificatePem),
      );
    }
    return _generateAndPersist();
  }

  /// 强制重新生成（用户重置证书时调用，会使旧指纹钉扎失效）。
  Future<HibikiTlsIdentity> regenerate() => _generateAndPersist();

  Future<HibikiTlsIdentity> _generateAndPersist() async {
    await Directory(_tlsDir).create(recursive: true);

    final String commonName = Platform.localHostname.isNotEmpty
        ? Platform.localHostname
        : 'hibiki-device';
    final List<String> ipv4 = await _localIpv4Addresses();

    final ({String certificatePem, String privateKeyPem}) generated =
        HibikiSelfSignedCertGenerator.generate(
      commonName: commonName,
      sanIpAddresses: ipv4,
    );

    // 私钥先写内容再 chmod 0600（POSIX 有效，Windows 无操作，靠 app 私有目录 + NTFS ACL）。
    final keyFile = File(_keyPath);
    await keyFile.writeAsString(generated.privateKeyPem, flush: true);
    await _tightenPermissions(_keyPath);

    final certFile = File(_certPath);
    await certFile.writeAsString(generated.certificatePem, flush: true);

    return HibikiTlsIdentity(
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
