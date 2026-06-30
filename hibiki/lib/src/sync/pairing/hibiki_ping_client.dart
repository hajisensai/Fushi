import 'dart:convert';

import 'package:hibiki/src/sync/tls/hibiki_pinning_http.dart';
import 'package:http/http.dart' as http;

/// TODO-963 M2: `/api/ping` 的 client 侧响应模型。无鉴权探测，配对前用。
class HibikiPingResult {
  const HibikiPingResult({
    required this.isHibiki,
    required this.supportsPairV2,
    required this.tlsEnabled,
    this.fingerprint,
    this.deviceName,
  });

  /// host 自报为 hibiki（`app == 'hibiki'`）。非 hibiki / 非 JSON → false。
  final bool isHibiki;

  /// host 支持 v2 配对协议（`pairing.v2 == true`）。
  final bool supportsPairV2;

  /// host 已开启 HTTPS（`tls.enabled == true`）。
  final bool tlsEnabled;

  /// host 证书指纹（`tls.fingerprint`，TLS 开时非空），供 client TOFU 记录/核对。
  final String? fingerprint;

  /// host 展示名（`deviceName`，可空）。
  final String? deviceName;
}

/// 向 [baseUrl] 的 `/api/ping` 发一次探测。
///
/// - 明文 http baseUrl：用普通 client。
/// - https baseUrl 且已知 [pinnedFingerprint]：走钉扎 client（指纹必须相等）。
/// - https baseUrl 但 **未知** 指纹（首次 TOFU）：调用方应先用
///   [HibikiTofuProbe.captureFingerprint] 取指纹核对后再传进来；此处不接受裸 https
///   无指纹探测（避免无钉扎读 https）。
///
/// 失败（连不上 / 非 hibiki / 解析失败）返回 null。绝不返回部分可信结果。
Future<HibikiPingResult?> fetchHibikiPing(
  String baseUrl, {
  String? pinnedFingerprint,
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final bool isHttps = baseUrl.toLowerCase().startsWith('https://');
  final bool ownsClient = httpClient == null;
  final http.Client client = httpClient ??
      (isHttps && pinnedFingerprint != null && pinnedFingerprint.isNotEmpty
          ? createPinnedHttpPackageClient(
              expectedFingerprint: pinnedFingerprint)
          : http.Client());
  try {
    final http.Response resp =
        await client.get(Uri.parse('$baseUrl/api/ping')).timeout(timeout);
    if (resp.statusCode != 200) return null;
    final dynamic decoded = jsonDecode(resp.body);
    if (decoded is! Map) return null;
    final Map<String, dynamic> json = decoded.cast<String, dynamic>();
    final bool isHibiki = json['app'] == 'hibiki';
    if (!isHibiki) return null;
    final dynamic pairing = json['pairing'];
    final bool supportsPairV2 = pairing is Map && pairing['v2'] == true;
    final dynamic tls = json['tls'];
    final bool tlsEnabled = tls is Map && tls['enabled'] == true;
    final String? fingerprint =
        tls is Map ? tls['fingerprint'] as String? : null;
    return HibikiPingResult(
      isHibiki: true,
      supportsPairV2: supportsPairV2,
      tlsEnabled: tlsEnabled,
      fingerprint: fingerprint,
      deviceName: json['deviceName'] as String?,
    );
  } on Object {
    return null;
  } finally {
    if (ownsClient) client.close();
  }
}
