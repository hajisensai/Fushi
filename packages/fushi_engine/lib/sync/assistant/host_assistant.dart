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

/// 会话能力名：AI 助手（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §6.5）——整场 agent 会话在 host 上跑，工具集是 host 自己描述的那部分操作。
const String kHostAssistantFeatureAgent = 'agent';

/// 发请求的是谁（`/api/assistant` 的鉴权结果）。[peerToken] = 这次请求用的 per-peer
/// 口令（已配对设备专属）；共享口令 / 老 client → null，host 认不出是哪台设备。
///
/// 只用来**归属**会话（远端会话历史按发起设备列，BUG-4067）：口令本身不出这个进程，
/// provider 自己把它映射成配对表里的稳定设备 id。
class HostAssistantCaller {
  const HostAssistantCaller({this.peerToken});

  /// 认不出设备的调用方（共享口令 / 单测）。
  static const HostAssistantCaller anonymous = HostAssistantCaller();

  final String? peerToken;
}

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

/// 会话可选的生命周期面：会话自己关掉了（被同一台设备续接时接管、host 端收尾…），
/// 会话表据此把它摘掉，客户端随后读到 404（「会话没了」），不对着一个关掉的会话
/// 空转长轮询。
abstract interface class HostAssistantSessionLifecycle {
  bool get isClosed;
}

/// 远端会话历史（BUG-4067）里找不到这场会话（或它不是这台设备发起的）→ 404。
class HostAssistantHistoryNotFound implements Exception {
  const HostAssistantHistoryNotFound();

  @override
  String toString() => 'HostAssistantHistoryNotFound';
}

/// 远端会话历史只对**已配对设备**开放（按发起设备过滤，共享口令认不出是谁）→ 403。
class HostAssistantPeerRequired implements Exception {
  const HostAssistantPeerRequired();

  @override
  String toString() => 'HostAssistantPeerRequired';
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

  /// 开一场 [feature] 会话；[locale] 是客户端的界面语言（AI 解析提示词用），
  /// [caller] 是发请求的设备（会话归属）。未知 feature 抛 [ArgumentError]，当前开不了
  /// 抛 [HostAssistantUnavailable]。
  Future<HostAssistantSession> open(
    String feature, {
    required String locale,
    HostAssistantCaller caller = HostAssistantCaller.anonymous,
  });
}

/// 有会话历史的 provider（AI 助手的远端会话，BUG-4067）：已配对设备列 / 续接 / 改名 /
/// 删除**自己发起的**会话。没实现它（或 [hasHistory] 为 false）的 feature 的历史路由
/// 一律 404，能力位也不宣告——老 host 就是这个样子，客户端据能力位判断。
///
/// 认不出设备（[HostAssistantCaller.peerToken] 为 null / 已吊销）一律抛
/// [HostAssistantPeerRequired]；会话不在或不是这台设备发起的抛
/// [HostAssistantHistoryNotFound]（不区分两者，不泄露别的设备有哪些会话）。
abstract interface class HostAssistantHistoryProvider {
  bool hasHistory(String feature);

  /// `[{id, title, createdAt, updatedAt, tokens}]`，最近更新的在前。
  Future<List<Map<String, Object?>>> listHistory(
    String feature,
    HostAssistantCaller caller,
  );

  /// 续接一场存档会话：读回整场对话，开成一场活的会话（与 [HostAssistantProvider.open]
  /// 同样的门）。正被别处打开着抛 [HostAssistantUnavailable]（`in_use`）。
  Future<HostAssistantSession> resume(
    String feature,
    String id, {
    required String locale,
    required HostAssistantCaller caller,
  });

  Future<void> renameHistory(
    String feature,
    String id,
    String title,
    HostAssistantCaller caller,
  );

  Future<void> deleteHistory(
    String feature,
    String id,
    HostAssistantCaller caller,
  );
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
  }) : _idleTimeout = idleTimeout,
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

  HostAssistantHistoryProvider _history(String feature) {
    if (_provider case final HostAssistantHistoryProvider history
        when history.hasHistory(feature)) {
      return history;
    }
    throw const HostAssistantHistoryNotFound();
  }

  /// 开会话，返回首个信封 `{id, revision, view}`。[resume] 非空 = 续接这场存档会话
  /// （[HostAssistantHistoryProvider.resume]）。
  Future<Map<String, Object?>> open(
    String feature, {
    required String locale,
    HostAssistantCaller caller = HostAssistantCaller.anonymous,
    String? resume,
  }) async {
    await _evictIdle();
    final HostAssistantSession session = resume == null
        ? await _provider.open(feature, locale: locale, caller: caller)
        : await _history(
            feature,
          ).resume(feature, resume, locale: locale, caller: caller);
    // 超上限时先关最久没碰的那场：手机端退出页面会 DELETE，留下来的多半是断线
    // 遗孤；新会话总是用户此刻正在用的那一场。
    while (_sessions.length >= _maxSessions) {
      final String oldest = _sessions.entries
          .reduce(
            (
              MapEntry<String, _SessionEntry> a,
              MapEntry<String, _SessionEntry> b,
            ) => a.value.touchedAt.isBefore(b.value.touchedAt) ? a : b,
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
      // 等待期间可能被关掉（会话表关的，或会话自己关了）。
      if (!_sessions.containsKey(id)) return null;
      if (_closedItself(session)) {
        _sessions.remove(id);
        return null;
      }
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

  /// [caller] 发起的 [feature] 历史会话（见 [HostAssistantHistoryProvider]）。
  Future<List<Map<String, Object?>>> listHistory(
    String feature,
    HostAssistantCaller caller,
  ) => _history(feature).listHistory(feature, caller);

  Future<void> renameHistory(
    String feature,
    String id,
    String title,
    HostAssistantCaller caller,
  ) => _history(feature).renameHistory(feature, id, title, caller);

  Future<void> deleteHistory(
    String feature,
    String id,
    HostAssistantCaller caller,
  ) => _history(feature).deleteHistory(feature, id, caller);

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

  static bool _closedItself(HostAssistantSession session) => switch (session) {
    HostAssistantSessionLifecycle(isClosed: true) => true,
    _ => false,
  };

  _SessionEntry? _touch(String id) {
    final _SessionEntry? entry = _sessions[id];
    if (entry == null) return null;
    // 会话自己关掉了（被接管 / 收尾）：摘掉，客户端读到「会话没了」。
    if (_closedItself(entry.session)) {
      _sessions.remove(id);
      return null;
    }
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
  ) => <String, Object?>{
    'id': id,
    'revision': session.revision,
    'view': session.snapshot(),
  };
}
