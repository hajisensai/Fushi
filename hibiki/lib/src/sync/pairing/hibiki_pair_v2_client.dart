import 'dart:convert';

import 'package:hibiki/src/sync/pairing/hibiki_pairing_protocol.dart';
import 'package:hibiki/src/sync/tls/hibiki_pinning_http.dart';
import 'package:http/http.dart' as http;

/// TODO-961 M1: v2 配对的 client 侧驱动（与 server 的 `/api/pair/v2`
/// + `/api/pair/v2/confirm` 对接）。纯传输 + 协议编排，无 UI；M2 的手动 IP / 扫码
/// 配对 UI 调它完成「TOFU 已记录指纹 → pair/v2 → 输 PIN → confirm → 落 token」。
///
/// 走 pinned client（指纹钉扎）：TOFU 首连记录 host 证书指纹后，本次及之后都用
/// 该指纹钉扎，client 只接受指纹相等的自签证书。PIN 绝不过线——只过 HMAC proof。

/// v2 配对一次往返的结果。
sealed class HibikiPairV2Outcome {
  const HibikiPairV2Outcome();
}

/// 配对成功：拿到 host 派发的 token（及可选的 host 指纹回执用于 TOFU 复核）。
class HibikiPairV2Success extends HibikiPairV2Outcome {
  const HibikiPairV2Success({required this.token, this.hostFingerprint});
  final String token;
  final String? hostFingerprint;
}

/// 配对失败：machine-readable [reason]（'pin' = PIN 错；'declined' = host 拒绝；
/// 'unavailable' = host 无审批 UI；'error' = 传输/解析失败）。
class HibikiPairV2Failure extends HibikiPairV2Outcome {
  const HibikiPairV2Failure(this.reason);
  final String reason;
}

/// client 侧 v2 配对驱动。[baseUrl] 应为 https host 根，[expectedFingerprint] 是
/// TOFU 首连记录的 host 证书指纹（用于 pinned client）。
class HibikiPairV2Client {
  HibikiPairV2Client({
    required this.baseUrl,
    required this.expectedFingerprint,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 65),
  })  : _httpClient = httpClient,
        _ownsClient = httpClient == null;

  final String baseUrl;
  final String expectedFingerprint;
  final Duration timeout;
  final http.Client? _httpClient;
  final bool _ownsClient;

  http.Client _client() =>
      _httpClient ??
      createPinnedHttpPackageClient(expectedFingerprint: expectedFingerprint);

  /// 完整一键配对：pair/v2 创建会话 → 用 [pin] + 双 nonce 算 pinProof → confirm。
  /// LAN 免 PIN（host 返回 pinRequired:false）时 [pin] 可为空（confirm 不带 proof）。
  Future<HibikiPairV2Outcome> pair({
    required String deviceName,
    String? pin,
  }) async {
    final http.Client client = _client();
    try {
      final String clientNonce = HibikiPairingProtocol.generateNonce();
      final http.Response startResp = await client
          .post(
            Uri.parse('$baseUrl/api/pair/v2'),
            headers: <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, String>{
              'name': deviceName,
              'clientNonce': clientNonce,
            }),
          )
          .timeout(timeout);
      if (startResp.statusCode == 403) {
        return HibikiPairV2Failure(_reasonOf(startResp.body, 'unavailable'));
      }
      if (startResp.statusCode != 200) {
        return const HibikiPairV2Failure('error');
      }
      final Map<String, dynamic> startBody =
          jsonDecode(startResp.body) as Map<String, dynamic>;
      final String? sessionId = startBody['sessionId'] as String?;
      final String? hostNonce = startBody['hostNonce'] as String?;
      final bool pinRequired = startBody['pinRequired'] as bool? ?? true;
      if (sessionId == null || hostNonce == null) {
        return const HibikiPairV2Failure('error');
      }

      final Map<String, dynamic> confirmBody = <String, dynamic>{
        'sessionId': sessionId,
      };
      if (pinRequired) {
        if (pin == null || pin.isEmpty) {
          return const HibikiPairV2Failure('pin');
        }
        confirmBody['pinProof'] = HibikiPairingProtocol.computePinProof(
          pin: pin,
          clientNonce: clientNonce,
          hostNonce: hostNonce,
        );
      }

      final http.Response confirmResp = await client
          .post(
            Uri.parse('$baseUrl/api/pair/v2/confirm'),
            headers: <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(confirmBody),
          )
          .timeout(timeout);
      if (confirmResp.statusCode == 401) {
        return HibikiPairV2Failure(_reasonOf(confirmResp.body, 'pin'));
      }
      if (confirmResp.statusCode == 403) {
        return HibikiPairV2Failure(_reasonOf(confirmResp.body, 'declined'));
      }
      if (confirmResp.statusCode != 200) {
        return const HibikiPairV2Failure('error');
      }
      final Map<String, dynamic> confirmJson =
          jsonDecode(confirmResp.body) as Map<String, dynamic>;
      final String? token = confirmJson['token'] as String?;
      if (token == null || token.isEmpty) {
        return const HibikiPairV2Failure('error');
      }
      return HibikiPairV2Success(
        token: token,
        hostFingerprint: confirmJson['hostFingerprint'] as String?,
      );
    } catch (_) {
      return const HibikiPairV2Failure('error');
    } finally {
      if (_ownsClient) client.close();
    }
  }

  static String _reasonOf(String body, String fallback) {
    try {
      final dynamic decoded = jsonDecode(body);
      if (decoded is Map && decoded['reason'] is String) {
        return decoded['reason'] as String;
      }
    } catch (_) {
      // 老 peer / 非 JSON body → 用 fallback。
    }
    return fallback;
  }
}
