/// 互联 host 的「AI 助手会话」：手机把一句话 / 一次点选交给已配对的电脑，由电脑用
/// **它自己的** AI 指派、资源搜索与下载管线把事办完（第一个功能是 AI 下视频）。
///
/// 与 `/api/jobs` 分开的原因：任务是「算完取回产物」的一次性调用，对话是多轮交互
/// ——host 会停在问题上等手机点选，一场对话可能跨越几分钟。所以这里是**会话**：
/// host 持有状态机，客户端只收与语言无关的快照（文案键 + 参数，手机按自己的语言
/// 渲染）、只发动作。
///
/// 引擎只管会话表（id / 闲置回收 / 长轮询）与 wire 形状；会话本身由 app 实现
/// [HostAssistantProvider]（状态机与全部端口都在 app 里）。
library;

import 'dart:async';
import 'dart:math';

/// 会话能力名：AI 下视频。
const String kHostAssistantFeatureVideoAcquire = 'videoAcquire';

/// host 上跑着的一场对话。
abstract interface class HostAssistantSession {
  /// 单调递增；快照每变一次 +1。客户端长轮询按它判断「有没有新东西」。
  int get revision;

  /// 与语言无关、JSON 安全的会话快照。
  Map<String, Object?> snapshot();

  /// 快照变化时发一个事件（值无意义，读 [snapshot]）。
  Stream<void> get changes;

  /// 执行一个客户端动作。**不等**它引发的效果链跑完（搜资源 / 找系列可能要一两
  /// 分钟），只保证动作本身已归约进快照；动作非法抛 [ArgumentError]（路由 400）。
  Future<void> act(Map<String, Object?> action);

  Future<void> close();
}

/// host 这边还不能开这类会话（没指派 AI 提供商 / 下载没配好…）。[reason] 是稳定短码，
/// 与 `capability()['reason']` 同一套，客户端据此给出具体引导。
class HostAssistantUnavailable implements Exception {
  const HostAssistantUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'HostAssistantUnavailable($reason)';
}

abstract interface class HostAssistantProvider {
  /// `/api/capabilities` 的 `assistant` 字段：`{supported, features, reason?}`。
  /// `supported=false` 时 `reason` 说明缺什么（短码）。
  Future<Map<String, Object?>> capability();

  /// 开一场 [feature] 会话；[locale] 是客户端的界面语言（AI 解析提示词用）。
  /// 未知 feature 抛 [ArgumentError]，当前开不了抛 [HostAssistantUnavailable]。
  Future<HostAssistantSession> open(String feature, {required String locale});
}

class _SessionEntry {
  _SessionEntry(this.session, this.touchedAt);

  final HostAssistantSession session;
  DateTime touchedAt;
}

/// 会话表：随机 id、闲置回收、并发上限、长轮询。一个 host 实例一份。
class HostAssistantSessions {
  HostAssistantSessions(
    this._provider, {
    Duration idleTimeout = const Duration(minutes: 30),
    int maxSessions = 8,
    DateTime Function()? now,
    Random? random,
  })  : _idleTimeout = idleTimeout,
        _maxSessions = maxSessions,
        _now = now ?? DateTime.now,
        _random = random ?? Random.secure();

  final HostAssistantProvider _provider;
  final Duration _idleTimeout;
  final int _maxSessions;
  final DateTime Function() _now;
  final Random _random;
  final Map<String, _SessionEntry> _sessions = <String, _SessionEntry>{};

  /// 长轮询单次最长等待；路由对客户端传的 `wait` 取上限。
  static const Duration maxWait = Duration(seconds: 25);

  int get length => _sessions.length;

  Future<Map<String, Object?>> capability() => _provider.capability();

  /// 开会话，返回首个信封 `{id, revision, view}`。
  Future<Map<String, Object?>> open(
    String feature, {
    required String locale,
  }) async {
    await _evictIdle();
    final HostAssistantSession session =
        await _provider.open(feature, locale: locale);
    // 超上限时先关最久没碰的那场：手机端退出页面会 DELETE，留下来的多半是断线
    // 遗孤；新会话总是用户此刻正在用的那一场。
    while (_sessions.length >= _maxSessions) {
      final String oldest = _sessions.entries
          .reduce(
            (MapEntry<String, _SessionEntry> a,
                    MapEntry<String, _SessionEntry> b) =>
                a.value.touchedAt.isBefore(b.value.touchedAt) ? a : b,
          )
          .key;
      await close(oldest);
    }
    final String id = _newId();
    _sessions[id] = _SessionEntry(session, _now());
    return _envelope(id, session);
  }

  /// 读快照。[after] 非空且快照还没越过它时最多等 [wait]（有变化立即返回）。
  /// 会话不存在（过期 / 已关）→ null。
  Future<Map<String, Object?>?> read(
    String id, {
    int? after,
    Duration wait = Duration.zero,
  }) async {
    final _SessionEntry? entry = _touch(id);
    if (entry == null) return null;
    final HostAssistantSession session = entry.session;
    if (after != null && session.revision <= after && wait > Duration.zero) {
      try {
        await session.changes
            .firstWhere((_) => session.revision > after)
            .timeout(wait > maxWait ? maxWait : wait);
      } on TimeoutException {
        // 没变化：照样回当前快照，客户端据 revision 判断后再发下一轮。
      } on StateError {
        // 会话在等待中被关掉（changes 流关闭）。
      }
      // 等待期间可能被关掉。
      if (!_sessions.containsKey(id)) return null;
    }
    return _envelope(id, session);
  }

  /// 执行动作后回当前快照；会话不存在 → null。
  Future<Map<String, Object?>?> act(
    String id,
    Map<String, Object?> action,
  ) async {
    final _SessionEntry? entry = _touch(id);
    if (entry == null) return null;
    await entry.session.act(action);
    return _envelope(id, entry.session);
  }

  Future<bool> close(String id) async {
    final _SessionEntry? entry = _sessions.remove(id);
    if (entry == null) return false;
    await entry.session.close();
    return true;
  }

  Future<void> dispose() async {
    final List<String> ids = _sessions.keys.toList(growable: false);
    for (final String id in ids) {
      await close(id);
    }
  }

  _SessionEntry? _touch(String id) {
    final _SessionEntry? entry = _sessions[id];
    if (entry == null) return null;
    if (_now().difference(entry.touchedAt) > _idleTimeout) {
      unawaited(close(id));
      return null;
    }
    entry.touchedAt = _now();
    return entry;
  }

  Future<void> _evictIdle() async {
    final DateTime now = _now();
    final List<String> stale = <String>[
      for (final MapEntry<String, _SessionEntry> e in _sessions.entries)
        if (now.difference(e.value.touchedAt) > _idleTimeout) e.key,
    ];
    for (final String id in stale) {
      await close(id);
    }
  }

  String _newId() {
    const String hex = '0123456789abcdef';
    String id;
    do {
      id = List<String>.generate(24, (_) => hex[_random.nextInt(16)]).join();
    } while (_sessions.containsKey(id));
    return id;
  }

  static Map<String, Object?> _envelope(
    String id,
    HostAssistantSession session,
  ) =>
      <String, Object?>{
        'id': id,
        'revision': session.revision,
        'view': session.snapshot(),
      };
}
