import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';
import 'package:http/http.dart' as http;
import 'package:fushi_engine/foundation/engine_log.dart';

/// TODO-963 M2: `/api/ping` 的 client 侧响应模型。无鉴权探测，配对前用。
class FushiPingResult {
  const FushiPingResult({
    required this.isFushi,
    required this.supportsPairV2,
    required this.tlsEnabled,
    this.fingerprint,
    this.deviceName,
    this.hostId,
  });

  /// host 自报为 fushi（`app == 'fushi'`）。非 fushi / 非 JSON → false。
  final bool isFushi;

  /// host 支持 v2 配对协议（`pairing.v2 == true`）。
  final bool supportsPairV2;

  /// host 已开启 HTTPS（`tls.enabled == true`）。
  final bool tlsEnabled;

  /// host 证书指纹（`tls.fingerprint`，TLS 开时非空），供 client TOFU 记录/核对。
  final String? fingerprint;

  /// host 展示名（`deviceName`，可空）。
  final String? deviceName;

  /// host 稳定设备 id（`hostId`，老 host 无此字段 → null）。选路探测用它核对
  /// 「这个地址背后还是不是我那台 host」。
  final String? hostId;
}

/// BUG-1741：`/api/ping` 探测的失败分型（机器可读，与 [FushiPairV2Client] 的
/// failure reason 共用同一套词汇）。
///
/// 分型存在的唯一理由：旧实现把「证书指纹对不上」（安全事件）、「对端超时」、
/// 「端口没人监听」和「那台机器不是 Fushi」**全部**压成同一个 `null`，UI 只能
/// 挑一句最含糊的话说，用户被引向完全错误的排查方向。
enum FushiPingFailure {
  /// 证书类失败：钉扎指纹不符 / 握手被对端拒绝。**安全事件**，绝不可与
  /// 「找不到设备」同呈现。
  tls,

  /// 对端在超时窗口内没有应答。
  timeout,

  /// 连不上：端口无监听、被防火墙拦、或明文请求打在 TLS-only 端口上被 reset。
  unreachable,

  /// 连上了、也应答了，但对端不是 Fushi（非 200 / 非 JSON / `app != 'fushi'`）。
  notFushi,
}

/// [probeFushiPing] 的结果：要么拿到可信的 [result]，要么给出 [failure] 原因。
class FushiPingOutcome {
  const FushiPingOutcome.ok(FushiPingResult this.result)
    : failure = null,
      statusCode = null,
      cause = null;

  const FushiPingOutcome.failed(
    FushiPingFailure this.failure, {
    this.statusCode,
    this.cause,
  }) : result = null;

  /// 探测成功时的应答（`isFushi` 恒为 true）；失败时为 null。
  final FushiPingResult? result;

  /// 探测失败原因；成功时为 null。
  final FushiPingFailure? failure;

  /// [FushiPingFailure.notFushi] 由「非 200 应答」引起时的状态码，便于日志定位。
  final int? statusCode;

  /// 传输层失败时的原始异常（「No route to host」/ 超时 / 握手失败），留给调用方
  /// 写诊断；其余失败为 null。
  final Object? cause;

  bool get isOk => result != null;

  /// 失败的一行描述（分型 + 状态码 / 原始异常），写诊断用；成功为 null。
  String? get failureDetail {
    final FushiPingFailure? f = failure;
    if (f == null) return null;
    final Object? c = cause;
    final int? code = statusCode;
    return <String>[
      f.name,
      if (code != null) 'HTTP $code',
      if (c != null) '$c',
    ].join(': ');
  }
}

/// 一次 [probeFushiPing] 失败的诊断（BUG-1741 的留痕）。[probeFushiPing] 自己不记
/// 日志——是否该记、记几次由调用方定：配对是用户当场发起的一次探测，每次失败都记；
/// 互联选路是后台每轮对每个候选的探测，只在该地址的状态切换时记（BUG-5262）。
void logFushiPingFailure(String baseUrl, FushiPingOutcome outcome) {
  final String? detail = outcome.failureDetail;
  if (detail == null) return;
  engineLog.logDiagnostic('Ping:$baseUrl', detail);
}

/// 向 [baseUrl] 的 `/api/ping` 发一次探测，**带失败原因**。
///
/// - 明文 http baseUrl：用普通 client。
/// - https baseUrl 且已知 [pinnedFingerprint]：走钉扎 client（指纹必须相等）。
/// - https baseUrl 但 **未知** 指纹（首次 TOFU）：调用方应先用
///   [FushiTofuProbe.probeFingerprint] 取指纹核对后再传进来；此处不接受裸 https
///   无指纹探测（避免无钉扎读 https）。
///
/// 绝不返回部分可信结果：只要有任何一步不确定就走 [FushiPingOutcome.failed]。
Future<FushiPingOutcome> probeFushiPing(
  String baseUrl, {
  String? pinnedFingerprint,
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final bool isHttps = baseUrl.toLowerCase().startsWith('https://');
  final bool ownsClient = httpClient == null;
  final http.Client client =
      httpClient ??
      (isHttps && pinnedFingerprint != null && pinnedFingerprint.isNotEmpty
          ? createPinnedHttpPackageClient(
              expectedFingerprint: pinnedFingerprint,
            )
          : http.Client());
  try {
    final http.Response resp = await client
        .get(Uri.parse('$baseUrl/api/ping'))
        .timeout(timeout);
    if (resp.statusCode != 200) {
      return FushiPingOutcome.failed(
        FushiPingFailure.notFushi,
        statusCode: resp.statusCode,
      );
    }
    final dynamic decoded = jsonDecode(resp.body);
    if (decoded is! Map) {
      return const FushiPingOutcome.failed(FushiPingFailure.notFushi);
    }
    final Map<String, dynamic> json = decoded.cast<String, dynamic>();
    final bool isFushi = json['app'] == 'fushi';
    if (!isFushi) {
      return const FushiPingOutcome.failed(FushiPingFailure.notFushi);
    }
    final dynamic pairing = json['pairing'];
    final bool supportsPairV2 = pairing is Map && pairing['v2'] == true;
    final dynamic tls = json['tls'];
    final bool tlsEnabled = tls is Map && tls['enabled'] == true;
    final String? fingerprint = tls is Map
        ? tls['fingerprint'] as String?
        : null;
    return FushiPingOutcome.ok(
      FushiPingResult(
        isFushi: true,
        supportsPairV2: supportsPairV2,
        tlsEnabled: tlsEnabled,
        fingerprint: fingerprint,
        deviceName: json['deviceName'] as String?,
        hostId: json['hostId'] as String?,
      ),
    );
  } catch (e) {
    // BUG-1741：分型 + 留痕。此前这里是裸 `on Object { return null; }`，
    // 「钉扎指纹不符」查不到任何线索，事后连日志都没有。原始异常随结果交回
    // （[FushiPingOutcome.cause]），由调用方经 [logFushiPingFailure] 写诊断：
    // 后台选路每轮对每个候选都探一次，在这里逐次记会把日志刷满（BUG-5262）。
    return FushiPingOutcome.failed(classifyFushiProbeFailure(e), cause: e);
  } finally {
    if (ownsClient) client.close();
  }
}

/// 把传输层异常映射成 [FushiPingFailure]。
///
/// [TlsException] 是 dart:io 里证书类失败的共同接口（[HandshakeException] /
/// [CertificateException] 都 implements 它）。package:http 的 IOClient 只把
/// `SocketException` / `HttpException` 转成 `ClientException`，TLS 异常原样穿透
/// ——所以 TLS 判定必须放在最前面。
FushiPingFailure classifyFushiProbeFailure(Object e) {
  if (e is TlsException) return FushiPingFailure.tls;
  if (e is TimeoutException) return FushiPingFailure.timeout;
  return FushiPingFailure.unreachable;
}
