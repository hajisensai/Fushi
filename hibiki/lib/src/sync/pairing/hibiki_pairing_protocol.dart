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
    this.clientDeviceId,
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

  /// TODO-961 M1b: client 自报的稳定 deviceId（配对时上报），confirm 成功后作为
  /// `hibiki_paired_peers.peerId` 落库的 UNIQUE 身份。可空——旧 client / 未上报时
  /// 为 null，confirm 回退派发共享 token（不落 per-peer 行，Never break userspace）。
  final String? clientDeviceId;

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

/// TODO-961 M3: 配对 PIN 爆破限速的纯状态跟踪器（无 IO / 无 Flutter，可完整单测）。
///
/// 威胁模型（设计稿 §3.1 承诺「靠限速防爆破」）：6 位 PIN 只有 100 万空间，
/// [HibikiPairSession.consumed] 让**单个会话**只能 confirm 一次，所以真正的爆破面
/// 不是「对一个会话反复撞」，而是攻击者**不断 pair/v2 开新会话、每个 confirm 一次**
/// 撞不同 PIN。故计数粒度必须落在**来源**（client），而非会话——否则每次开新会话就
/// 把失败计数重置为零，限速形同虚设。
///
/// 来源标识（[sourceKey]）由调用方给出：优先 client 自报的稳定 `clientDeviceId`，
/// 回退请求来源 IP（`remoteAddress`）。二者都缺时调用方应退化为不限速的单会话路径
/// （无稳定身份可锁，见 [HibikiSyncServer]）。
///
/// 语义：同一来源在滑动窗口 [failureWindow] 内累计 [maxFailures] 次 PIN 校验失败即
/// 进入锁定，锁定持续 [lockoutDuration]（退避有界、可恢复）。锁定窗口内该来源的
/// confirm 一律被拒（不再触碰 PIN 比对，杜绝继续撞）。成功配对或来源记录过期后计数
/// 清零，绝不永久株连。清理复用注入时钟，配合会话 prune 一并调用防内存泄漏。
class HibikiPinRateLimiter {
  HibikiPinRateLimiter({
    this.maxFailures = 5,
    this.failureWindow = const Duration(minutes: 5),
    this.lockoutDuration = const Duration(minutes: 15),
    this.maxTrackedSources = 256,
  })  : assert(maxFailures > 0),
        assert(maxTrackedSources > 0);

  /// 触发锁定的连续（窗口内）失败阈值。第 [maxFailures] 次失败后即锁定。
  final int maxFailures;

  /// 失败计数的滑动窗口：距上次失败超过本时长即视为「已冷却」，计数从头开始，
  /// 使正常用户偶发输错在长时间后不被历史失败株连。
  final Duration failureWindow;

  /// 达阈值后的锁定退避时长。锁定窗口内该来源 confirm 直接被拒。有界、到期自动恢复。
  final Duration lockoutDuration;

  /// 跟踪来源数上限（防攻击者用海量伪造来源撑爆内存）。超限时先按最旧活动淘汰。
  final int maxTrackedSources;

  /// 每来源一条记录：窗口内失败计数、最近一次失败时刻、锁定到期时刻（null=未锁）。
  final Map<String, _PinFailureRecord> _records = <String, _PinFailureRecord>{};

  /// [sourceKey] 当前是否处于锁定退避窗口内（[now] 为注入时钟）。锁定期满自动解除。
  /// 调用方在触碰 PIN 比对**之前**先查此方法：锁定则直接拒，不给继续撞的机会，
  /// 也不引入「PIN 前缀正确就更慢」的计时差（锁定判定与 PIN 内容完全无关）。
  bool isLockedOut(String sourceKey, DateTime now) {
    final _PinFailureRecord? rec = _records[sourceKey];
    if (rec == null) return false;
    final DateTime? until = rec.lockedUntil;
    if (until == null) return false;
    if (!now.isBefore(until)) {
      // 锁定期满：清除该来源记录，允许重新尝试（退避可恢复）。
      _records.remove(sourceKey);
      return false;
    }
    return true;
  }

  /// 记录 [sourceKey] 一次 PIN 校验失败（[now] 为注入时钟）。返回记录后该来源是否
  /// **已进入锁定**。滑动窗口：距上次失败超过 [failureWindow] 则计数重置为 1。
  bool recordFailure(String sourceKey, DateTime now) {
    _reclaimStale(now);
    final _PinFailureRecord existing = _records[sourceKey] ??
        _PinFailureRecord(failureCount: 0, lastFailureAt: now);
    final bool windowExpired =
        now.difference(existing.lastFailureAt) > failureWindow;
    final int nextCount = windowExpired ? 1 : existing.failureCount + 1;
    final bool nowLocked = nextCount >= maxFailures;
    _records[sourceKey] = _PinFailureRecord(
      failureCount: nextCount,
      lastFailureAt: now,
      lockedUntil: nowLocked ? now.add(lockoutDuration) : null,
    );
    // 插入后再守上限：先回收陈旧再插入可能使总数达 maxTrackedSources+1，此处淘汰
    // 最旧活动来源把它压回上限内（刚写入的记录 lastFailureAt=now 最新，不会被淘汰）。
    _enforceCap();
    return nowLocked;
  }

  /// [sourceKey] 成功配对后清零其失败计数与锁定态（不再株连未来尝试）。
  void recordSuccess(String sourceKey) {
    _records.remove(sourceKey);
  }

  /// 清掉既非锁定中、失败又已冷却（超 [failureWindow]）的陈旧记录，并在超过
  /// [maxTrackedSources] 时淘汰最旧活动来源。与会话 prune 同步调用防内存泄漏。
  void prune(DateTime now) {
    _reclaimStale(now);
    _enforceCap();
  }

  /// 测试钩子：当前跟踪的来源记录数。
  int get trackedSourceCount => _records.length;

  /// 回收陈旧记录：锁定中的保留到锁定期满（删掉=提前解锁），未锁定的失败一旦冷却
  /// 出 [failureWindow] 窗口即回收。不涉及上限淘汰。
  void _reclaimStale(DateTime now) {
    _records.removeWhere((String _, _PinFailureRecord rec) {
      final DateTime? until = rec.lockedUntil;
      if (until != null) return !now.isBefore(until);
      return now.difference(rec.lastFailureAt) > failureWindow;
    });
  }

  /// 守住跟踪来源数上限：超过 [maxTrackedSources] 时按 lastFailureAt 淘汰最旧活动
  /// 来源直到回到上限内（防攻击者用海量伪造来源撑爆内存）。
  void _enforceCap() {
    while (_records.length > maxTrackedSources) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final MapEntry<String, _PinFailureRecord> e in _records.entries) {
        if (oldestAt == null || e.value.lastFailureAt.isBefore(oldestAt)) {
          oldestAt = e.value.lastFailureAt;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) break;
      _records.remove(oldestKey);
    }
  }
}

/// 单个来源的 PIN 失败记录（[HibikiPinRateLimiter] 内部值对象，不可变）。
class _PinFailureRecord {
  const _PinFailureRecord({
    required this.failureCount,
    required this.lastFailureAt,
    this.lockedUntil,
  });

  /// 当前滑动窗口内累计的连续失败次数。
  final int failureCount;

  /// 最近一次失败时刻（滑动窗口与陈旧回收的判定基准）。
  final DateTime lastFailureAt;

  /// 锁定退避到期时刻；null 表示尚未触发锁定。
  final DateTime? lockedUntil;
}
