import 'dart:async';
import 'dart:io';

import 'package:fushi/src/sync/tls/fushi_pinning_http.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// BUG-1741：TOFU 握手的失败分型。
///
/// 「握手失败」和「连不上」是两件事：前者证明**端口上有东西，只是不讲 TLS**
/// （多半是用户把 http host 写成了 https），后者是根本没连上。旧实现把两者都
/// 压成 null，配对流程因此无法判断「该不该回落明文 v1」。
enum FushiTofuFailure {
  /// 端口可连，但不是 TLS 端点（明文服务 / 协议版本谈不拢）。
  notTls,

  /// 连不上（无监听 / 防火墙）。
  unreachable,

  /// 超时。
  timeout,
}

/// [FushiTofuProbe.probeFingerprint] 的结果。
class FushiTofuOutcome {
  const FushiTofuOutcome.captured(String this.fingerprint) : failure = null;

  const FushiTofuOutcome.failed(FushiTofuFailure this.failure)
      : fingerprint = null;

  /// 捕获到的 host 证书 SHA-256 指纹（`aa:bb:..`）；失败时为 null。
  final String? fingerprint;

  /// 失败原因；成功时为 null。
  final FushiTofuFailure? failure;

  /// 已确证对端在该端口讲 TLS。
  ///
  /// 配对流程用它做「禁止回落 v1 明文配对」的判据：明文 POST 打向一个只讲
  /// https 的端口**必然**失败，回落过去只会换来一句无意义的「配对失败」。
  bool get speaksTls => (fingerprint?.isNotEmpty ?? false);
}

/// TODO-963 M2: TOFU 首连「捕获 host 证书指纹」探测。
///
/// 首次连接一个 https host 时 client 还没有可钉扎的指纹，无从比对。本探测建立一次
/// **一次性** TLS 握手，记录 host 出示证书的 SHA-256 指纹（小写 hex 冒号分隔）交还
/// 调用方，由用户核对 / TOFU 记录后再用 [createPinnedHttpClient] 走真正的钉扎连接。
///
/// 安全边界（务必遵守）：
/// - 本探测**只**用于取指纹给用户核对，**绝不**用于传 token / 同步数据。
/// - 取到指纹后，所有后续连接必须经 [createPinnedHttpClient]（指纹钉扎）。
/// - 它不无条件「信任」证书：它信任的是「本次握手所见的指纹」这一事实，并把该指纹
///   原样交还由 TOFU / 用户裁决。`onBadCertificate` 返回的是「是否已成功捕获到指纹」
///   这一计算结果，而非硬编码放行——捕获失败（理论上不会）即拒绝握手。
class FushiTofuProbe {
  /// 连到 [host]:[port] 做一次 TLS 握手，返回 host 证书的 SHA-256 指纹
  /// （aa:bb:.. 形式）或**失败原因**。
  static Future<FushiTofuOutcome> probeFingerprint(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    String? captured;
    SecureSocket? socket;
    bool timedOut = false;
    try {
      // BUG-1741：超时**不**走 `SecureSocket.connect(timeout:)`。它超时抛的是
      // `SocketException: Connection timed out`，会被 [classifyFushiTofuFailure]
      // 归成 `unreachable`，UI 于是把「对端没在时限内应答」说成「连接失败」——正是
      // 本 bug 要消灭的那类误导文案，而 [FushiTofuFailure.timeout] 那条分支永远
      // 走不到。外包一层 `.timeout()` 抛真正的 [TimeoutException]，分型才可达。
      // 两套超时**不叠加**：connect 不再传 `timeout:`，只此一处计时。
      final Future<SecureSocket> connecting = SecureSocket.connect(
        host,
        port,
        onBadCertificate: (X509Certificate cert) {
          captured = fingerprintOfDer(cert.der);
          // 返回「是否已捕获到指纹」：捕获成功才放行这一次性握手，否则拒绝。
          // 不是无条件 true——没有指纹（理论不可能）就让握手失败。
          return captured != null;
        },
      );
      final Future<SecureSocket> connected = connecting.timeout(
        timeout,
        onTimeout: () {
          timedOut = true;
          throw TimeoutException('TOFU handshake timed out', timeout);
        },
      );
      // `.timeout` 只让**本函数**不再等，并不取消底层 connect：它稍后仍可能
      // resolve 出一个真 socket，没人 destroy 就是句柄泄漏。这个兜底必须注册在
      // `.timeout` **之后**——注册顺序即回调顺序，抢在前面会在成功路径上先把我们
      // 正要用的 socket 销毁掉。
      unawaited(connecting.then<void>(
        (SecureSocket abandoned) {
          if (timedOut) abandoned.destroy();
        },
        onError: (Object _) {
          // 超时之后底层 connect 才真失败：结论已由上面的 TimeoutException 代表，
          // 这里只负责别让它变成 unhandled async error。
        },
      ));
      socket = await connected;
      // 自签证书会先触发 onBadCertificate（此时已捕获）；若证书恰好被系统信任则
      // 回调不触发，从 socket.peerCertificate 兜底取。
      captured ??= () {
        final X509Certificate? peer = socket?.peerCertificate;
        return peer == null ? null : fingerprintOfDer(peer.der);
      }();
      final String? fingerprint = captured;
      if (fingerprint == null || fingerprint.isEmpty) {
        return const FushiTofuOutcome.failed(FushiTofuFailure.notTls);
      }
      return FushiTofuOutcome.captured(fingerprint);
    } catch (e) {
      // 握手中途失败但已拿到证书：指纹本身仍然可信（它就是对端出示的那张），
      // 保持旧行为返回它。
      final String? fingerprint = captured;
      if (fingerprint != null && fingerprint.isNotEmpty) {
        return FushiTofuOutcome.captured(fingerprint);
      }
      // BUG-1741：分型 + 留痕。此前这里静默返回 null，调用方无从分辨
      // 「对端不讲 TLS」与「对端不在」——而这两者的正确处置完全相反。
      //
      // 走 logDiagnostic 而非 log：这是多候选 failover 里的**瞬时探测失败**，
      // 明文 host 每次配对都必然让 https 候选抛一次 HandshakeException，属预期
      // 路径。计进用户可见错误计数 + 持久化日志只会制造噪声
      // （见 ErrorLogService.logDiagnostic 的文档）。
      ErrorLogService.instance.logDiagnostic('TofuProbe:$host:$port', e);
      return FushiTofuOutcome.failed(classifyFushiTofuFailure(e));
    } finally {
      try {
        await socket?.close();
      } on Object {
        // best-effort close
      }
    }
  }
}

/// 把 TOFU 握手抛出的传输层异常映射成 [FushiTofuFailure]。
///
/// 连到明文端口时 `SecureSocket.connect` 抛的是 [HandshakeException]（实现了
/// [TlsException]）；连不上抛 [SocketException]；超时由
/// [FushiTofuProbe.probeFingerprint] 外包的 `.timeout()` 抛 [TimeoutException]
/// ——**不是** connect 自己的 `timeout:`（那个抛的是 SocketException，会被误归
/// 成 unreachable，见该处注释）。
FushiTofuFailure classifyFushiTofuFailure(Object e) {
  if (e is TlsException) return FushiTofuFailure.notTls;
  if (e is TimeoutException) return FushiTofuFailure.timeout;
  return FushiTofuFailure.unreachable;
}
