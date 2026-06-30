import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// TODO-961 M1 配对协议核心（纯 Dart，无 IO / 无 Flutter，可完整单测）。
///
/// 安全模型（设计稿 §3.1）：
/// - PIN 是 host 屏幕上显示的 6 位数字短码，**绝不明文过线**。
/// - client 提交 `pinProof = HMAC-SHA256(PIN, clientNonce|hostNonce)`，host 用同一
///   PIN + 同一对 nonce 重算比对。双 nonce 既绑定本次会话又防重放（同一 sessionId
///   的 nonce 二次提交必拒）。
/// - 双重确认：pinProof 校验通过 **且** host 端人工点允许，二者缺一不派 token。
///
/// 本文件只负责「算」与「判」；会话生命周期 / token 派发 / 弹窗由
/// [HibikiSyncServer] 与 [HibikiSyncServerController] 编排。

/// 一次 client 发起的配对会话（host 侧持有，pair/v2 创建、pair/v2/confirm 消费）。
///
/// nonce 是 host 与 client 各自一次性随机数；[consumed] 在第一次 confirm 成功或被
/// 拒后置位，杜绝同一 sessionId 重放（同 nonce 二次提交一律拒）。
class HibikiPairSession {
  HibikiPairSession({
    required this.sessionId,
    required this.clientNonce,
    required this.hostNonce,
    required this.pin,
    required this.pinRequired,
    required this.deviceName,
    required this.remoteAddress,
    required this.createdAt,
  });

  /// 不透明会话 id（client 在 confirm 时回传以定位本会话）。
  final String sessionId;

  /// client 在 pair/v2 提交的一次性随机数（base64url）。
  final String clientNonce;

  /// host 在 pair/v2 响应时生成的一次性随机数（base64url）。
  final String hostNonce;

  /// host 屏幕显示的 6 位数字 PIN。pinRequired=false 时仍生成但 client 可免输。
  final String pin;

  /// 本会话是否要求 PIN 校验（公网入站恒 true；LAN 自动发现且 host 允许免 PIN 时
  /// false——见 [HibikiPairingProtocol.computePinRequired]）。
  final bool pinRequired;

  /// client 自报名（弹窗展示用，可空）。
  final String? deviceName;

  /// 请求来源 IP（弹窗展示 + 审计用，可空）。
  final String? remoteAddress;

  /// 会话创建时刻（TTL 判定基准，TTL 加固在 M3，本阶段先记录）。
  final DateTime createdAt;

  /// 单次消费标志：一旦 confirm（无论成功/失败）即置位，第二次 confirm 直接拒，
  /// 防 nonce 重放。
  bool consumed = false;
}

/// 配对协议的纯函数集合：nonce 生成、PIN 生成、pinProof 计算与校验、pinRequired
/// 分支判定。全部静态、无副作用，可独立单测。
class HibikiPairingProtocol {
  HibikiPairingProtocol._();

  /// 生成一个一次性随机 nonce（24 字节 → base64url，无填充）。供 host / client 各
  /// 自调用；clientNonce 由 client 生成并随 pair/v2 提交，hostNonce 由 host 生成。
  static String generateNonce([Random? random]) {
    final Random rng = random ?? Random.secure();
    final List<int> bytes = List<int>.generate(24, (_) => rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// 生成 6 位数字 PIN（"000000"–"999999"，前导零保留为定长 6 位字符串）。
  /// 100 万空间，靠限速（M3）防爆破；本身不可逆地过线（只过 HMAC proof）。
  static String generatePin([Random? random]) {
    final Random rng = random ?? Random.secure();
    final int value = rng.nextInt(1000000);
    return value.toString().padLeft(6, '0');
  }

  /// 计算 pinProof：`HMAC-SHA256(key=PIN_bytes, msg=clientNonce|hostNonce)`，输出
  /// 小写 hex。client 与 host 用完全相同的输入算，比对结果即知 PIN 是否一致。
  ///
  /// 消息用 `clientNonce` + '|' + `hostNonce` 拼接：分隔符消除 (a|b) 与 (a'|b') 在
  /// 边界处的歧义碰撞；两侧 nonce 都进 MAC 保证 proof 与本次会话强绑定（防重放到
  /// 另一会话）。
  static String computePinProof({
    required String pin,
    required String clientNonce,
    required String hostNonce,
  }) {
    final Hmac hmac = Hmac(sha256, utf8.encode(pin));
    final Digest digest = hmac.convert(utf8.encode('$clientNonce|$hostNonce'));
    final StringBuffer buf = StringBuffer();
    for (final int b in digest.bytes) {
      buf.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  /// 校验 client 提交的 [submittedProof] 是否等于用本会话 PIN/nonce 重算的期望值。
  /// 用常量时间比较防计时侧信道。归一化（去空白、转小写）以容忍大小写/空白噪声。
  static bool verifyPinProof({
    required String pin,
    required String clientNonce,
    required String hostNonce,
    required String submittedProof,
  }) {
    final String expected = computePinProof(
      pin: pin,
      clientNonce: clientNonce,
      hostNonce: hostNonce,
    );
    return constantTimeEquals(
      _normalizeProof(expected),
      _normalizeProof(submittedProof),
    );
  }

  /// pinRequired 分支（设计稿 §3.1）：公网入站恒 true；仅当请求来自 LAN 自动发现
  /// （同网段）**且** host 设置允许 LAN 免 PIN 时返回 false。任一条件不满足都强制
  /// PIN。这是「自家局域网免 PIN、外网强制 PIN」取舍 A 的判据。
  ///
  /// * [isLanPeer]：请求来源是否被判定为同网段 LAN（私有地址段 / 环回）。
  /// * [lanRequiresPin]：host 偏好「LAN 也要 PIN」。默认 false=自家免。
  static bool computePinRequired({
    required bool isLanPeer,
    required bool lanRequiresPin,
  }) {
    if (!isLanPeer) return true; // 公网 / 跨网段：强制 PIN。
    return lanRequiresPin; // LAN：随 host 设置（默认 false=免）。
  }

  /// 判断 [remoteAddress] 是否属于本地 / 私有网段（粗判 LAN 同网段）。无法解析或为
  /// 空时保守地返回 false（→ 走强制 PIN，安全侧）。覆盖 IPv4 私有段
  /// (10/8, 172.16/12, 192.168/16, 169.254/16 link-local, 127/8) 与 IPv6 环回
  /// (::1) / 唯一本地地址 (fc00::/7) / link-local (fe80::/10)。
  static bool isPrivateLanAddress(String? remoteAddress) {
    final String? addr = remoteAddress?.trim();
    if (addr == null || addr.isEmpty) return false;
    // IPv6：环回与本地段。
    if (addr.contains(':')) {
      final String lower = addr.toLowerCase();
      if (lower == '::1') return true;
      if (lower.startsWith('fe80:')) return true; // link-local
      if (lower.startsWith('fc') || lower.startsWith('fd')) {
        return true; // fc00::/7 unique-local
      }
      return false;
    }
    final List<String> parts = addr.split('.');
    if (parts.length != 4) return false;
    final List<int?> octets =
        parts.map((String p) => int.tryParse(p)).toList(growable: false);
    if (octets.any((int? o) => o == null || o < 0 || o > 255)) return false;
    final int a = octets[0]!;
    final int b = octets[1]!;
    if (a == 127) return true; // 127.0.0.0/8 loopback
    if (a == 10) return true; // 10.0.0.0/8
    if (a == 192 && b == 168) return true; // 192.168.0.0/16
    if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
    if (a == 169 && b == 254) return true; // 169.254.0.0/16 link-local
    return false;
  }

  /// 去空白、转小写以归一化 proof hex 串后比对。
  static String _normalizeProof(String proof) =>
      proof.replaceAll(RegExp(r'\s'), '').toLowerCase();

  /// 常量时间相等比较：长度不同也不提前返回，避免计时侧信道泄漏 proof 前缀。
  static bool constantTimeEquals(String a, String b) {
    final Uint8List ab = Uint8List.fromList(utf8.encode(a));
    final Uint8List bb = Uint8List.fromList(utf8.encode(b));
    final int len = ab.length > bb.length ? ab.length : bb.length;
    int result = ab.length ^ bb.length;
    for (var i = 0; i < len; i++) {
      result |= (i < ab.length ? ab[i] : 0) ^ (i < bb.length ? bb[i] : 0);
    }
    return result == 0;
  }
}
