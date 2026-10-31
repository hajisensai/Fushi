/// 同一家 AI 提供商多把 API Key 的轮换与冷却。
///
/// 数据分两份、各有主人：
/// - **配置**（哪几把 key、顺序、启用开关）在 [AiProviderConfig.apiKeys]，用户在
///   设置页改；
/// - **健康记录**（这把 key 冷却到什么时候、连续失败了几次）在 [AiKeyHealthStore]，
///   只有调用层（`AiChatClient`）在请求成败时写。
///
/// 分开是刻意的：冷却是请求热路径上的高频写，若塞进提供商配置里，就会和设置页
/// 防抖落盘的草稿互相覆盖（一边刚改的 key 被另一边的冷却写回旧值）。
///
/// 健康记录按 [aiKeyFingerprint] 索引，**不存 key 本身**。
library;

import 'dart:convert';
import 'dart:io' show HttpDate, HttpException;
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';

/// 没有 `Retry-After` 时第一次失败的冷却时长；之后每连续失败一次翻倍。
const Duration kAiKeyBaseCooldown = Duration(minutes: 1);

/// 冷却上限：失效的 key 也最多一天后再试一次（用户可能已经去充值 / 换了权限）。
const Duration kAiKeyMaxCooldown = Duration(hours: 24);

/// 一把 key 的运行时健康记录。
class AiKeyHealth {
  const AiKeyHealth({
    required this.cooldownUntil,
    required this.failures,
    required this.reason,
  });

  /// 冷却到期时刻（UTC）。到期前这把 key 排到最后，只在别的 key 都不可用时才试。
  final DateTime cooldownUntil;

  /// 连续失败次数（成功一次就整条清掉），决定下次的退避时长。
  final int failures;

  /// 最近一次失败的脱敏短码（`unauthorized` / `rate_limited` / `quota_exhausted`），
  /// 只给界面显示原因用。
  final String reason;

  bool isCoolingAt(DateTime now) => now.isBefore(cooldownUntil);

  /// 值相等：[aiKeyHealthAfterSuccess] / [aiKeyHealthAfterFailure] 靠它判断「这条
  /// 记录自请求发出以来有没有被别的请求改过」。持久化实现每次读都解码出新对象，
  /// 不能比身份。
  @override
  bool operator ==(Object other) =>
      other is AiKeyHealth &&
      other.cooldownUntil.isAtSameMomentAs(cooldownUntil) &&
      other.failures == failures &&
      other.reason == reason;

  @override
  int get hashCode =>
      Object.hash(cooldownUntil.microsecondsSinceEpoch, failures, reason);

  Map<String, Object?> toJson() => <String, Object?>{
    'until': cooldownUntil.toUtc().millisecondsSinceEpoch,
    'failures': failures,
    'reason': reason,
  };

  /// 字段畸形返回 null（坏记录等于「没有记录」，不该挡住请求）。
  static AiKeyHealth? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? until = json['until'];
    final Object? failures = json['failures'];
    if (until is! int || failures is! int || failures < 1) {
      return null;
    }
    return AiKeyHealth(
      cooldownUntil: DateTime.fromMillisecondsSinceEpoch(until, isUtc: true),
      failures: failures,
      reason: json['reason'] as String? ?? '',
    );
  }
}

/// 一条健康记录的更新函数：收到这条记录的**当前值**（没有为 null），返回新值
/// （null = 清掉）。必须是纯函数——持久化实现会对进程内缓存值与最新持久值各调用
/// 一次。
typedef AiKeyHealthUpdate = AiKeyHealth? Function(AiKeyHealth? current);

/// 健康记录的存取口。app 落设备本地偏好（重启后冷却仍然有效），无头服务端用
/// 进程内实现。
///
/// 写入只有 [update] 一个口子，没有「整条覆盖」：调用方先 [read] 再写回时，两个
/// 并发请求会各自拿到同一个旧值、各算一条再先后写，后写的覆盖先写的（一次限流
/// 记成两次失败、按旧排序发出的成功抹掉别处刚记的冷却）。「读当前 → 算下一条 →
/// 写回」必须在实现内部一气呵成。
abstract interface class AiKeyHealthStore {
  AiKeyHealth? read(String fingerprint);

  /// 原子地改 [fingerprint] 这一条：读当前值、调用 [update]、写回结果之间不插入
  /// 别的写；只动这一条，不碰别的指纹。
  void update(String fingerprint, AiKeyHealthUpdate update);
}

class InMemoryAiKeyHealthStore implements AiKeyHealthStore {
  final Map<String, AiKeyHealth> _records = <String, AiKeyHealth>{};

  @override
  AiKeyHealth? read(String fingerprint) => _records[fingerprint];

  @override
  void update(String fingerprint, AiKeyHealthUpdate update) {
    final AiKeyHealth? next = update(_records[fingerprint]);
    if (next == null) {
      _records.remove(fingerprint);
    } else {
      _records[fingerprint] = next;
    }
  }
}

/// 全局装配点：app 在偏好可读时换成持久化实现（`PreferencesRepository.loadFromDb`）。
AiKeyHealthStore aiKeyHealthStore = InMemoryAiKeyHealthStore();

/// 一把 key 在健康记录里的索引：`sha256(providerId \0 key)` 的前 16 个十六进制位。
///
/// 带上 providerId：同一把 key 配在两家（例如两个不同地址的中转）时各自的
/// 健康互不影响——限流和鉴权是按端点算的。
String aiKeyFingerprint(String providerId, String key) => sha256
    .convert(utf8.encode('$providerId\u0000${key.trim()}'))
    .toString()
    .substring(0, 16);

/// 失败码里哪些说明「换一把 key 可能就好了」：鉴权被拒、限流、余额 / 额度不足。
/// 网络、5xx、坏回复、请求本身 4xx 都与 key 无关，换 key 重试只会把同一个错误
/// 多吃几遍。
bool aiFailureRotatesKey(String code) =>
    code == 'unauthorized' ||
    code == 'rate_limited' ||
    code == 'quota_exhausted';

/// 这次失败之后这把 key 的健康记录。
///
/// 服务端给了 `Retry-After` 就照它冷却（上限 [kAiKeyMaxCooldown]）；否则按
/// [kAiKeyBaseCooldown] 指数退避（1、2、4… 分钟，封顶一天）。
AiKeyHealth nextAiKeyHealth({
  required AiKeyHealth? previous,
  required String reason,
  required Duration? retryAfter,
  required DateTime now,
}) {
  final int failures = (previous?.failures ?? 0) + 1;
  final Duration cooldown = retryAfter != null
      ? _clampCooldown(retryAfter)
      : _clampCooldown(
          kAiKeyBaseCooldown * math.pow(2, math.min(failures - 1, 20)).toInt(),
        );
  return AiKeyHealth(
    cooldownUntil: now.toUtc().add(cooldown),
    failures: failures,
    reason: reason,
  );
}

Duration _clampCooldown(Duration value) {
  if (value <= Duration.zero) {
    return const Duration(seconds: 1);
  }
  return value > kAiKeyMaxCooldown ? kAiKeyMaxCooldown : value;
}

/// 一次请求在某把 key 上**成功**之后，这把 key 的记录该变成什么。
///
/// [seen] 是这次请求发出前读到的记录，[current] 是落账时的当前记录。只有记录自
/// 发出以来没被别的请求改过（`current == seen`）才清掉：否则那是一个比本次发出
/// 更晚才观测到的失败（同一把 key 上并发的另一个请求刚被拒 / 限流），本次成功
/// 不能拿发出时的旧视图把它抹掉。
AiKeyHealth? aiKeyHealthAfterSuccess({
  required AiKeyHealth? seen,
  required AiKeyHealth? current,
}) => current == seen ? null : current;

/// 一次请求在某把 key 上**失败**（且属于换 key 的失败）之后，这把 key 的记录。
///
/// - 记录自发出以来没变，或已被并发的成功清掉：在当前记录上照常累加
///   （[nextAiKeyHealth]）；被清掉的情形从第一次失败重新计。
/// - 发出之后别的并发请求已经记过一次失败：两边是从同一个旧视图出发的同一阵
///   拒绝 / 限流的两份回执，不是「连续失败两次」——失败次数不再累加，冷却取
///   两者里更晚的到期（服务端给的 `Retry-After` 更长时以它为准）。
///
/// 这样并发请求的落账顺序不影响结果：两次不带 `Retry-After` 的 429 只记一次
/// 退避（1 分钟，不会变成 2 分钟）。
AiKeyHealth aiKeyHealthAfterFailure({
  required AiKeyHealth? seen,
  required AiKeyHealth? current,
  required String reason,
  required Duration? retryAfter,
  required DateTime now,
}) {
  if (current == null || current == seen) {
    return nextAiKeyHealth(
      previous: current,
      reason: reason,
      retryAfter: retryAfter,
      now: now,
    );
  }
  final AiKeyHealth mine = nextAiKeyHealth(
    previous: seen,
    reason: reason,
    retryAfter: retryAfter,
    now: now,
  );
  final bool mineLater = mine.cooldownUntil.isAfter(current.cooldownUntil);
  return AiKeyHealth(
    cooldownUntil: mineLater ? mine.cooldownUntil : current.cooldownUntil,
    failures: math.max(mine.failures, current.failures),
    reason: mineLater ? mine.reason : current.reason,
  );
}

/// 这次请求按什么顺序试 key。
///
/// 没在冷却的 key 按用户排的顺序全部可试；一把都没有时只试**最早到期**的那一把
/// ——宁可真打一次拿回服务端的真实错误（或者它其实已经恢复），也不凭本地记录
/// 编一个「全部冷却中」的失败。所以只配一把 key 的用户行为与以前完全一样：每次
/// 请求都真的发出去。
List<String> orderAiKeysForRequest({
  required String providerId,
  required List<String> keys,
  required AiKeyHealthStore store,
  required DateTime now,
}) {
  final List<String> ready = <String>[];
  String? soonest;
  DateTime? soonestUntil;
  for (final String key in keys) {
    final AiKeyHealth? health = store.read(aiKeyFingerprint(providerId, key));
    if (health == null || !health.isCoolingAt(now)) {
      ready.add(key);
      continue;
    }
    if (soonestUntil == null || health.cooldownUntil.isBefore(soonestUntil)) {
      soonest = key;
      soonestUntil = health.cooldownUntil;
    }
  }
  if (ready.isNotEmpty || soonest == null) {
    return ready;
  }
  return <String>[soonest];
}

/// 解析 `Retry-After`：秒数或 HTTP-date 两种形状（RFC 9110 §10.2.3）；认不出
/// 返回 null（退回指数退避）。
Duration? parseRetryAfter(String? header, DateTime now) {
  if (header == null) {
    return null;
  }
  final String value = header.trim();
  if (value.isEmpty) {
    return null;
  }
  final int? seconds = int.tryParse(value);
  if (seconds != null) {
    return seconds < 0 ? null : Duration(seconds: seconds);
  }
  try {
    final Duration delta = HttpDate.parse(value).difference(now.toUtc());
    return delta.isNegative ? Duration.zero : delta;
  } on FormatException {
    return null;
  } on HttpException {
    return null;
  }
}
