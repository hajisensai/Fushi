import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/io_client.dart';

/// 把 [InternetAddress]/证书 DER 的 SHA-256 算成小写 hex、冒号分隔（aa:bb:..）。
/// 与 [HibikiTlsIdentityStore.fingerprintOf] 同算法，供钉扎比对。
String fingerprintOfDer(List<int> der) {
  final Digest digest = sha256.convert(der);
  final buf = StringBuffer();
  for (var i = 0; i < digest.bytes.length; i++) {
    if (i > 0) buf.write(':');
    buf.write(digest.bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

/// 归一化指纹串以便比对：去冒号、转小写、去空白。
String _normalizeFingerprint(String fp) =>
    fp.replaceAll(':', '').replaceAll(RegExp(r'\s'), '').toLowerCase();

/// 唯一接受自签证书的判据：证书 DER 的 SHA-256 是否等于钉扎指纹。
///
/// 这是 [HttpClient.badCertificateCallback] 的全部逻辑。**绝不无条件
/// return true**，绝不放行任何其它证书错误——指纹不等就握手失败。
bool certificateMatchesFingerprint(
  X509Certificate cert,
  String expectedFingerprint,
) {
  final String actual = fingerprintOfDer(cert.der);
  return _normalizeFingerprint(actual) ==
      _normalizeFingerprint(expectedFingerprint);
}

/// 构造一个只接受 证书 SHA-256 指纹 == [expectedFingerprint] 的 dart:io
/// [HttpClient]。这是唯一的接受自签证书入口；[HttpClient.badCertificateCallback]
/// 仅在指纹相等时返回 true，其余一律 false（握手失败），绝不无条件放行。
HttpClient createPinnedHttpClient({
  required String expectedFingerprint,
  Duration? connectionTimeout,
}) {
  final HttpClient client = HttpClient();
  if (connectionTimeout != null) {
    client.connectionTimeout = connectionTimeout;
  }
  client.badCertificateCallback =
      (X509Certificate cert, String host, int port) =>
          certificateMatchesFingerprint(cert, expectedFingerprint);
  return client;
}

/// package:http 版本：把 [createPinnedHttpClient] 包成 [IOClient]，供 lookup /
/// pair POST 等用 package:http 的调用点复用同一钉扎判据。
IOClient createPinnedHttpPackageClient({
  required String expectedFingerprint,
  Duration? connectionTimeout,
}) {
  return IOClient(
    createPinnedHttpClient(
      expectedFingerprint: expectedFingerprint,
      connectionTimeout: connectionTimeout,
    ),
  );
}
