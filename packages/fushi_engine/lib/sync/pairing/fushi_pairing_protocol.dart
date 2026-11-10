import 'dart:convert';
import 'dart:io' show InternetAddress, InternetAddressType;
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
/// [FushiSyncServer] 与 [FushiSyncServerController] 编排。

/// 一次 client 发起的配对会话（host 侧持有，pair/v2 创建、pair/v2/confirm 消费）。
///
/// nonce 是 host 与 client 各自一次性随机数；[consumed] 在第一次 confirm 成功或被
/// 拒后置位，杜绝同一 sessionId 重放（同 nonce 二次提交一律拒）。
class FushiPairSession {
  FushiPairSession({
    required this.sessionId,
    required this.clientNonce,
    required this.hostNonce,
    required this.pin,
    required this.pinRequired,
    required this.deviceName,
    required this.remoteAddress,
    required this.createdAt,
    this.clientDeviceId,
    this.ticketId,
    this.tunnelPeer,
    this.devicePubkey,
    this.ownerDeviceGrant,
    this.sourceKey,
    this.sourceKeyTrusted = false,
    this.originClass = FushiPairOriginClass.public,
    this.protectedFromEviction = false,
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
  /// false——见 [FushiPairingProtocol.computePinRequired]）。
  final bool pinRequired;

  /// client 自报名（弹窗展示用，可空）。
  final String? deviceName;

  /// 请求来源 IP（弹窗展示 + 审计用，可空）。
  final String? remoteAddress;

  /// TODO-961 M1b: client 自报的稳定 deviceId（配对时上报），confirm 成功后作为
  /// `fushi_paired_peers.peerId` 落库的 UNIQUE 身份。可空——旧 client / 未上报时
  /// 为 null，confirm 回退派发共享 token（不落 per-peer 行，Never break userspace）。
  final String? clientDeviceId;

  /// 会话创建时刻（TTL 判定基准，TTL 加固在 M3，本阶段先记录）。
  final DateTime createdAt;

  /// 本会话凭 host 签发的一次性配对票据（扫码 / 复制链接）发起时的票据 id；
  /// 此时 [pin] 是票据 secret，host 屏上打开二维码即视为已批准，不再弹审批框。
  /// null = 普通 PIN / LAN 配对。
  final String? ticketId;

  /// 经 P2P 隧道进来的会话：对端的 iroh NodeId（密码学身份，不可冒用）。直连会话
  /// 为 null。限流按它分桶——隧道请求在 TCP 层一律来自 127.0.0.1，没有它就只能
  /// 所有隧道对端共用一个桶，一个人撞 PIN 就把其他人全锁在外面。
  final String? tunnelPeer;

  /// client 在 pair/v2 上报的互联设备公钥（base64url SPKI，见
  /// `interconnect_device_key.dart`）。只有带了 [clientDeviceId] 时才记；旧 client 为 null。
  /// confirm 时 client 用对应私钥签本会话，验签通过才算「设备钥匙已证明」。
  final String? devicePubkey;

  /// 本会话审批时 host 主人对「这是我的设备」的选择（**绑定本次会话**，不按 deviceId
  /// 全局记账）。null = 本会话不提供该选项（没上报设备钥匙 / 扫码票据配对）。
  final FushiPairOwnerDeviceGrant? ownerDeviceGrant;

  /// 本会话在 PIN 限速与会话分桶里的来源键（BUG-4280）：IP（IPv6 按 /64）、可信代理
  /// 解析出的转发来源，或隧道 NodeId。**不**取 client 自报的 deviceId——那个谁都能冒报。
  /// null = 无法识别来源，只受类别预算约束。
  final String? sourceKey;

  /// [sourceKey] 能否区分不同的真实来源（回环对端、`p2p:?` 为 false）；为 false 时不做
  /// 「每来源会话数」限额——否则所有经本机反代进来的人共用一个名额。
  final bool sourceKeyTrusted;

  /// 来源类别：决定 PIN 失败计入哪一份总预算、会话占哪一个分区（BUG-4280）。
  final FushiPairOriginClass originClass;

  /// 会话上限淘汰时跳过本会话：票据会话、由人工批准过的 PIN 会话（BUG-4280）。
  final bool protectedFromEviction;

  /// 单次消费标志：一旦 confirm（无论成功/失败）即置位，第二次 confirm 直接拒，
  /// 防 nonce 重放。
  bool consumed = false;
}

/// 一次配对会话里「这是我的设备」的审批结果。server 每个会话新建一个、随
/// `FushiPairRequest.ownerDeviceGrant` 交给 host 审批 UI，UI 在点「允许 · 这是我的设备」
/// 时置 [granted]；confirm 落库时 server 只读**本会话**的这一个实例，并且只在设备钥匙
/// 验签通过时才生效。会话过期 / PIN 错 / 被拒，这个实例随会话一起丢弃，不会残留到
/// 同一 deviceId 的下一次配对上（PR #2258 审查问题 1）。
class FushiPairOwnerDeviceGrant {
  /// host 主人选了「这是我的设备」。
  bool granted = false;
}

/// 配对协议的纯函数集合：nonce 生成、PIN 生成、pinProof 计算与校验、pinRequired
/// 分支判定。全部静态、无副作用，可独立单测。
class FushiPairingProtocol {
  FushiPairingProtocol._();

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
    final String? trimmed = remoteAddress?.trim();
    if (trimmed == null || trimmed.isEmpty) return false;
    // 双栈监听（IPv6 socket 同时收 v4）下，v4 对端被报成 `::ffff:a.b.c.d`——按它
    // 字面判会把整个 LAN 当公网，强制 PIN。先还原成 v4 再判。
    final String addr = unmapIPv4MappedAddress(trimmed);
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
    final List<int?> octets = parts
        .map((String p) => int.tryParse(p))
        .toList(growable: false);
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

  /// IPv4 映射的 IPv6 地址（`::ffff:192.168.1.5`，双栈 socket 上的 v4 对端）还原为
  /// 点分 v4；其余地址原样返回。来源地址的**唯一**规范化入口：LAN 判定、限速来源
  /// key、`lastSeenIp` 落库都必须看到同一种写法，否则同一台设备经 v4/v6 两条路来
  /// 会被当成两个来源。
  static String unmapIPv4MappedAddress(String address) {
    final String lower = address.toLowerCase();
    const String prefix = '::ffff:';
    if (!lower.startsWith(prefix)) return address;
    final String rest = lower.substring(prefix.length);
    return rest.split('.').length == 4 ? rest : address;
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
/// [FushiPairSession.consumed] 让**单个会话**只能 confirm 一次，所以真正的爆破面
/// 不是「对一个会话反复撞」，而是攻击者**不断 pair/v2 开新会话、每个 confirm 一次**
/// 撞不同 PIN。故计数粒度必须落在**来源**（client），而非会话——否则每次开新会话就
/// 把失败计数重置为零，限速形同虚设。
///
/// 来源标识（[sourceKey]）由调用方给出：请求来源 IP（IPv6 按 /64，见
/// [fushiRateKeyForAddress]）或隧道 NodeId，**不**用 client 自报的 deviceId（可冒报，
/// BUG-4280）。拿不到来源时调用方不按来源限速，只受 [FushiPinFailureBudget] 约束。
/// 本类只挡单一来源；海量来源轮流猜由按来源类别的 [FushiPinFailureBudget] 兜住。
///
/// 语义：同一来源在滑动窗口 [failureWindow] 内累计 [maxFailures] 次 PIN 校验失败即
/// 进入锁定，锁定持续 [lockoutDuration]（退避有界、可恢复）。锁定窗口内该来源的
/// confirm 一律被拒（不再触碰 PIN 比对，杜绝继续撞）。成功配对或来源记录过期后计数
/// 清零，绝不永久株连。清理复用注入时钟，配合会话 prune 一并调用防内存泄漏。
class FushiPinRateLimiter {
  FushiPinRateLimiter({
    this.maxFailures = 5,
    this.failureWindow = const Duration(minutes: 5),
    this.lockoutDuration = const Duration(minutes: 15),
    this.maxTrackedSources = 256,
  }) : assert(maxFailures > 0),
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
    final _PinFailureRecord existing =
        _records[sourceKey] ??
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

  /// 管理员解除锁定（BUG-4280）：清掉全部来源记录。
  void reset() {
    _records.clear();
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

/// 单个来源的 PIN 失败记录（[FushiPinRateLimiter] 内部值对象，不可变）。
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

/// 按来源类别的 PIN 失败总预算（BUG-4280）。[FushiPinRateLimiter] 只按来源分桶，
/// 攻击者换来源（IPv6 一个 /64 外还有海量前缀、僵尸网络）即可绕过；无头端又没有人工
/// 审批环节，「开会话 → 猜一次」可以无限循环。本类把同一类别的所有失败合在一起计：
/// 失败间隔都不超过 [window] 的连续 [maxFailures] 次失败即锁定整个类别
/// `baseLockout * 2^level`（封顶 [maxLockout]），之后 level 加一、计数清零。距上次
/// 失败超过 [levelDecay] 时 level 归零。纯内存态、注入时钟，可单测。
class FushiPinFailureBudget {
  FushiPinFailureBudget({
    this.maxFailures = 10,
    this.window = const Duration(minutes: 15),
    this.baseLockout = const Duration(minutes: 15),
    this.maxLockout = const Duration(hours: 24),
    this.levelDecay = const Duration(hours: 24),
  }) : assert(maxFailures > 0);

  final int maxFailures;
  final Duration window;
  final Duration baseLockout;
  final Duration maxLockout;
  final Duration levelDecay;

  int _count = 0;
  int _level = 0;
  DateTime? _lastFailureAt;
  DateTime? _lockedUntil;

  /// 当前锁定到期时刻；未锁定（含已到期）为 null。
  DateTime? get lockedUntil => _lockedUntil;

  /// 已触发过的锁定级数（下一次锁定时长 = baseLockout * 2^level）。
  int get level => _level;

  /// [now] 时本类别是否处于锁定中；到期即解除。
  bool isLockedOut(DateTime now) {
    final DateTime? until = _lockedUntil;
    if (until == null) return false;
    if (now.isBefore(until)) return true;
    _lockedUntil = null;
    return false;
  }

  /// 记一次失败；返回记后是否处于锁定。锁定中再记不累计、不延长（调用方本应在锁定时
  /// 直接拒，不会走到这里）。
  bool recordFailure(DateTime now) {
    if (isLockedOut(now)) return true;
    final DateTime? last = _lastFailureAt;
    if (last != null && now.difference(last) > levelDecay) _level = 0;
    if (last == null || now.difference(last) > window) _count = 0;
    _lastFailureAt = now;
    _count++;
    if (_count < maxFailures) return false;
    _lockedUntil = now.add(_lockoutFor(_level));
    _level++;
    _count = 0;
    return true;
  }

  /// 本类别有 PIN 会话配对成功：级数与计数清零（锁定中不会有成功，不涉及锁定）。
  void recordSuccess() {
    _count = 0;
    _level = 0;
  }

  /// 管理员解除：清锁定、级数与计数。
  void reset() {
    _count = 0;
    _level = 0;
    _lastFailureAt = null;
    _lockedUntil = null;
  }

  Duration _lockoutFor(int level) {
    Duration d = baseLockout;
    for (int i = 0; i < level; i++) {
      d *= 2;
      if (d >= maxLockout) return maxLockout;
    }
    return d > maxLockout ? maxLockout : d;
  }
}

/// 配对请求的来源类别（BUG-4279）。决定是否免 PIN（只有 [lan] 可能免）。
///
/// - [lan]：TCP 对端是私网地址、请求不带任何转发头（无头端另要求对端不是回环）。
/// - [p2p]：经 P2P 隧道监听口进来（`fushi.zone = p2p`），恒按公网要 PIN / 票据。
/// - [public]：其余一切——公网对端、带转发头（经反代 / 穿透）、无头端的回环对端、
///   拿不到对端地址。
enum FushiPairOriginClass { lan, p2p, public }

/// 一组 IP / CIDR（`a.b.c.d`、`a.b.c.d/n`、IPv6 及 `/n`）。用于无头端
/// `trusted_proxies`：对端命中时才读转发头里的真实来源（只影响限速键与展示，
/// **不**影响 LAN 判定）。IPv4 映射的 IPv6 地址（`::ffff:a.b.c.d`）两侧都先还原成 v4。
class FushiAddressRangeSet {
  const FushiAddressRangeSet._(this._ranges);

  /// 空集合：什么都不包含。
  static const FushiAddressRangeSet empty = FushiAddressRangeSet._(
    <_AddressRange>[],
  );

  final List<_AddressRange> _ranges;

  bool get isEmpty => _ranges.isEmpty;

  /// 解析一组条目；任一条非法即抛 [FormatException]，消息里带出那一项原文。
  static FushiAddressRangeSet parse(List<String> cidrsOrIps) {
    final List<_AddressRange> ranges = <_AddressRange>[];
    for (final String raw in cidrsOrIps) {
      ranges.add(_AddressRange.parse(raw));
    }
    return FushiAddressRangeSet._(List<_AddressRange>.unmodifiable(ranges));
  }

  bool contains(InternetAddress address) {
    final List<int> bytes = fushiUnmapIPv4MappedRaw(address.rawAddress);
    for (final _AddressRange r in _ranges) {
      if (r.matches(bytes)) return true;
    }
    return false;
  }
}

class _AddressRange {
  const _AddressRange(this.bytes, this.prefixBits);

  final List<int> bytes;
  final int prefixBits;

  static _AddressRange parse(String raw) {
    final String entry = raw.trim();
    FormatException bad() =>
        FormatException('Invalid IP address or CIDR: "$raw"', raw);
    if (entry.isEmpty) throw bad();
    final int slash = entry.indexOf('/');
    final String addrText = slash < 0 ? entry : entry.substring(0, slash);
    final InternetAddress? addr = InternetAddress.tryParse(addrText);
    if (addr == null) throw bad();
    final List<int> rawBytes = addr.rawAddress;
    final List<int> bytes = fushiUnmapIPv4MappedRaw(rawBytes);
    final int fullBits = rawBytes.length * 8;
    int prefix = fullBits;
    if (slash >= 0) {
      final int? n = int.tryParse(entry.substring(slash + 1));
      if (n == null || n < 0 || n > fullBits) throw bad();
      prefix = n;
    }
    // 写成 v4 映射形式的条目还原成 v4：前缀也要扣掉 96 位映射头。
    if (bytes.length != rawBytes.length) {
      if (prefix < 96) throw bad();
      prefix -= 96;
    }
    return _AddressRange(bytes, prefix);
  }

  bool matches(List<int> other) {
    if (other.length != bytes.length) return false;
    int remaining = prefixBits;
    for (int i = 0; i < bytes.length && remaining > 0; i++) {
      final int bits = remaining >= 8 ? 8 : remaining;
      final int mask = (0xff << (8 - bits)) & 0xff;
      if ((bytes[i] & mask) != (other[i] & mask)) return false;
      remaining -= bits;
    }
    return true;
  }
}

/// IPv4 映射的 IPv6 原始地址（16 字节，`::ffff:a.b.c.d`）还原成 4 字节 v4；
/// 其余原样返回。
List<int> fushiUnmapIPv4MappedRaw(List<int> raw) {
  if (raw.length != 16) return raw;
  for (int i = 0; i < 10; i++) {
    if (raw[i] != 0) return raw;
  }
  if (raw[10] != 0xff || raw[11] != 0xff) return raw;
  return raw.sublist(12);
}

/// 限速 / 会话分桶用的来源键（步骤 5 消费）：v4（含 v4 映射还原后）→
/// `ip:<点分地址>`；v6 → `ip6:<前 64 位规范化>/64`（同一 /64 内换地址仍是同一来源）。
String fushiRateKeyForAddress(InternetAddress address) {
  final List<int> raw = fushiUnmapIPv4MappedRaw(address.rawAddress);
  if (raw.length == 4) {
    return 'ip:${InternetAddress.fromRawAddress(Uint8List.fromList(raw), type: InternetAddressType.IPv4).address}';
  }
  final Uint8List prefix = Uint8List(16)..setRange(0, 8, raw);
  final String net = InternetAddress.fromRawAddress(
    prefix,
    type: InternetAddressType.IPv6,
  ).address;
  return 'ip6:$net/64';
}
