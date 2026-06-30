import 'dart:io';

import 'package:hibiki/src/sync/tls/hibiki_pinning_http.dart';

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
class HibikiTofuProbe {
  /// 连到 [host]:[port] 做一次 TLS 握手，返回 host 证书的 SHA-256 指纹
  /// （aa:bb:.. 形式）。失败（连不上 / 非 TLS / 超时）返回 null。
  static Future<String?> captureFingerprint(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    String? captured;
    SecureSocket? socket;
    try {
      socket = await SecureSocket.connect(
        host,
        port,
        timeout: timeout,
        onBadCertificate: (X509Certificate cert) {
          captured = fingerprintOfDer(cert.der);
          // 返回「是否已捕获到指纹」：捕获成功才放行这一次性握手，否则拒绝。
          // 不是无条件 true——没有指纹（理论不可能）就让握手失败。
          return captured != null;
        },
      );
      // 自签证书会先触发 onBadCertificate（此时已捕获）；若证书恰好被系统信任则
      // 回调不触发，从 socket.peerCertificate 兜底取。
      captured ??= () {
        final X509Certificate? peer = socket?.peerCertificate;
        return peer == null ? null : fingerprintOfDer(peer.der);
      }();
      return captured;
    } on Object {
      return captured; // 连接异常时若已捕获到指纹仍可返回（握手中途失败）。
    } finally {
      try {
        await socket?.close();
      } on Object {
        // best-effort close
      }
    }
  }
}
