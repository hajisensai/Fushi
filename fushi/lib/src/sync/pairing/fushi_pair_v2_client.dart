import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi/src/sync/pairing/fushi_pairing_protocol.dart';
import 'package:fushi/src/sync/tls/fushi_pinning_http.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:http/http.dart' as http;

/// TODO-961 M1: v2 配对的 client 侧驱动（与 server 的 `/api/pair/v2`
/// + `/api/pair/v2/confirm` 对接）。纯传输 + 协议编排，无 UI；M2 的手动 IP / 扫码
/// 配对 UI 调它完成「TOFU 已记录指纹 → pair/v2 → 输 PIN → confirm → 落 token」。
///
/// 走 pinned client（指纹钉扎）：TOFU 首连记录 host 证书指纹后，本次及之后都用
/// 该指纹钉扎，client 只接受指纹相等的自签证书。PIN 绝不过线——只过 HMAC proof。

/// v2 配对一次往返的结果。
sealed class FushiPairV2Outcome {
  const FushiPairV2Outcome();
}

/// 配对成功：拿到 host 派发的 token（及可选的 host 指纹回执用于 TOFU 复核）。
class FushiPairV2Success extends FushiPairV2Outcome {
  const FushiPairV2Success({required this.token, this.hostFingerprint});
  final String token;
  final String? hostFingerprint;
}

/// 配对失败：machine-readable [reason]。
///
/// - `'pin'`：PIN 校验未通过。
/// - `'declined'`：host 上的人点了拒绝。
/// - `'unavailable'`：host 没有审批 UI（旧版本 / headless）。
/// - `'rate_limited'`：PIN 连错太多次，该来源被 host 退避锁定（BUG-1553）。
/// - `'tls'`：TLS 握手失败——证书指纹对不上或链路被拦（BUG-1553）。
/// - `'timeout'`：请求超时（BUG-1553）。
/// - `'cancelled'`：用户在 PIN 输入框点了取消。
/// - `'error'`：其余传输 / 解析失败。
///
/// BUG-1553：前面这些分型此前全被压成 `'error'`——server 精心设计的 429
/// `rate_limited` 机器可读原因在 client 一端整个丢掉，用户被锁 15 分钟却只看到
/// 「配对失败」，于是反复重试（每次还要 host 再审批一遍）；TLS 指纹不符这种安全
/// 事件也被降级成同一句话，且一行日志都不留，报障时无从定位。
class FushiPairV2Failure extends FushiPairV2Outcome {
  const FushiPairV2Failure(this.reason);
  final String reason;
}

/// client 侧 v2 配对驱动。[baseUrl] 应为 https host 根，[expectedFingerprint] 是
/// TOFU 首连记录的 host 证书指纹（用于 pinned client）。
class FushiPairV2Client {
  FushiPairV2Client({
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

  /// 完整一键配对：pair/v2 创建会话 → **仅当 host 回报 pinRequired 时** 才经
  /// [pinProvider] 向调用方索取 6 位 PIN → 双 nonce 算 pinProof → confirm。
  ///
  /// TODO-1273 修复配对时序：PIN 是否需要由 host 的 pair/v2 响应（pinRequired）决定，
  /// client 不能在收到该响应前就盲目弹 PIN 输入框。LAN 免 PIN（pinRequired:false）时
  /// [pinProvider] **完全不会被调用**，用户不会看到「输入对方 PIN」的对话框；只有公网 /
  /// host 强制 PIN 的会话才会调 [pinProvider] 取 PIN。返回 null 视为用户取消
  /// （→ 'cancelled'），返回空串视为未输入（→ 'pin'）；不传 [pinProvider] 而 host 又
  /// 要求 PIN 时同样判为 'pin'（无从取得 PIN）。
  ///
  /// [clientDeviceId] 是本机稳定 deviceId（TODO-961 M1b）：随 pair/v2 上报，host 用它
  /// 作 `fushi_paired_peers.peerId` 落库并回派本设备专属 per-peer token。可空——host
  /// 侧无此字段时回退共享 token（向后兼容）。
  Future<FushiPairV2Outcome> pair({
    required String deviceName,
    Future<String?> Function()? pinProvider,
    String? clientDeviceId,
  }) async {
    final http.Client client = _client();
    try {
      final String clientNonce = FushiPairingProtocol.generateNonce();
      final http.Response startResp = await client
          .post(
            Uri.parse('$baseUrl/api/pair/v2'),
            headers: <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, String>{
              'name': deviceName,
              'clientNonce': clientNonce,
              if (clientDeviceId != null && clientDeviceId.isNotEmpty)
                'clientDeviceId': clientDeviceId,
            }),
          )
          .timeout(timeout);
      if (startResp.statusCode == 403) {
        return FushiPairV2Failure(_reasonOf(startResp.body, 'unavailable'));
      }
      if (startResp.statusCode == 429) {
        return FushiPairV2Failure(_reasonOf(startResp.body, 'rate_limited'));
      }
      if (startResp.statusCode != 200) {
        return const FushiPairV2Failure('error');
      }
      final Map<String, dynamic> startBody =
          jsonDecode(startResp.body) as Map<String, dynamic>;
      final String? sessionId = startBody['sessionId'] as String?;
      final String? hostNonce = startBody['hostNonce'] as String?;
      final bool pinRequired = startBody['pinRequired'] as bool? ?? true;
      if (sessionId == null || hostNonce == null) {
        return const FushiPairV2Failure('error');
      }

      final Map<String, dynamic> confirmBody = <String, dynamic>{
        'sessionId': sessionId,
      };
      if (pinRequired) {
        // 只有 host 明确要求 PIN 时才向调用方索取——LAN 免 PIN 分支到不了这里，
        // 用户不会看到「输入对方 PIN」的对话框（TODO-1273）。
        final String? pin = pinProvider == null ? null : await pinProvider();
        if (pin == null) {
          // pinProvider 返回 null = 用户取消；未接线（pinProvider==null）= 无从取得。
          return FushiPairV2Failure(pinProvider == null ? 'pin' : 'cancelled');
        }
        if (pin.isEmpty) return const FushiPairV2Failure('pin');
        confirmBody['pinProof'] = FushiPairingProtocol.computePinProof(
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
        return FushiPairV2Failure(_reasonOf(confirmResp.body, 'pin'));
      }
      if (confirmResp.statusCode == 403) {
        return FushiPairV2Failure(_reasonOf(confirmResp.body, 'declined'));
      }
      // BUG-1553：429 = host 的 PIN 爆破限速把这个来源锁了，与「PIN 打错一次」是
      // 两回事——不分开用户会一直重试，而重试期间每一次都必然失败。
      if (confirmResp.statusCode == 429) {
        return FushiPairV2Failure(_reasonOf(confirmResp.body, 'rate_limited'));
      }
      if (confirmResp.statusCode != 200) {
        return const FushiPairV2Failure('error');
      }
      final Map<String, dynamic> confirmJson =
          jsonDecode(confirmResp.body) as Map<String, dynamic>;
      final String? token = confirmJson['token'] as String?;
      if (token == null || token.isEmpty) {
        return const FushiPairV2Failure('error');
      }
      return FushiPairV2Success(
        token: token,
        hostFingerprint: confirmJson['hostFingerprint'] as String?,
      );
    } catch (e, stack) {
      // BUG-1553：分型并留痕。吞掉全部异常又不记日志，会把「证书指纹对不上」
      // （安全事件）和「对方关机了」呈现成同一句「配对失败」，且事后查不到任何线索。
      ErrorLogService.instance.log('PairV2Client:$baseUrl', e, stack);
      return FushiPairV2Failure(_classifyTransportFailure(e));
    } finally {
      if (_ownsClient) client.close();
    }
  }

  /// BUG-1553：把传输层异常映射成机器可读 reason，供 UI 说人话。
  ///
  /// [TlsException] 是 dart:io 里证书类失败的共同接口（[HandshakeException] /
  /// [CertificateException] 都 implements 它）——钉扎判据不符时
  /// `badCertificateCallback` 返回 false，握手就以它收场。package:http 的 IOClient
  /// 只把 `SocketException`/`HttpException` 转成 `ClientException`，TLS 异常原样穿透。
  static String _classifyTransportFailure(Object e) {
    if (e is TlsException) return 'tls';
    if (e is TimeoutException) return 'timeout';
    return 'error';
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
