import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/sync/sync_repository.dart'
    show FushiClientUrl, remoteDictionaryHostIdOf;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 词典服务器被判不可达后的**再探测间隔**（BUG-1302 的失败冷却窗，BUG-4275 起改作
/// 后台再探测的节奏）。
///
/// 与音频源的 `kRemoteAudioFailureCooldown`（45s，`word_audio_resolver.dart`）同量级：
/// host 被证实死了之后，查词不再每次重付「3s × 候选数」的连接超时；后台每隔这么久
/// 轻量探一次，探通了立刻恢复查词。
const Duration kRemoteDictionaryFailureCooldown = Duration(seconds: 45);

/// 已配对 host 上托管的词典清单端点（`fushi_library_host_service` 的 `listDictionaries`）。
/// 目录服务拉清单、后台再探测（两个进程）都打它。
const String kRemoteDictionaryCatalogPath = '/api/library/dictionaries';

/// 一台词典服务器（[remoteDictionaryHostIdOf] 口径）在本进程里的传输层可达性。
///
/// 只记本次运行看到的：重启后为空，界面退回目录行的 `lastSeenAt`（「最近在线」）。
/// 「可达」= 某个地址拿到了 HTTP 响应（含 401 / 404 / 坏回包——对端活着）；
/// 「不可达」= 试过的地址全部传输层失败（连接拒绝 / 超时 / DNS）。
@immutable
class RemoteDictionaryHostReachability {
  const RemoteDictionaryHostReachability({
    this.lastOkAt,
    this.failingSince,
    this.lastAttemptAt,
  });

  /// 最近一次拿到响应的时刻（ms）。
  final int? lastOkAt;

  /// 自这一刻起连续不可达（ms）；null = 最近一次是可达的（或还没试过）。
  final int? failingSince;

  /// 最近一次真正发出请求（成功或失败）的时刻（ms）。
  final int? lastAttemptAt;

  bool get reachable => failingSince == null && lastOkAt != null;
}

/// 一次互联请求里各候选地址的传输层结局，按 host 归并：任一地址拿到响应 = 可达；
/// 试过的地址全部失败 = 不可达；没轮到的 host（前面已有候选给出结果）不出现。
class RemoteHostOutcomes {
  final Map<String, bool> _reachableByHost = <String, bool>{};

  /// 交给 `InterconnectPostTransport` 的 `onCandidateOutcome`。
  void add(FushiClientUrl candidate, bool responded) {
    final String hostId = remoteDictionaryHostIdOf(candidate);
    _reachableByHost[hostId] = (_reachableByHost[hostId] ?? false) || responded;
  }

  bool get isEmpty => _reachableByHost.isEmpty;

  Map<String, bool> get reachableByHost =>
      Map<String, bool>.unmodifiable(_reachableByHost);
}

/// 后台再探测一台 host：做一次轻量互联往返，结局经 [RemoteDictionaryReachability.record]
/// 记回来（探测函数自己负责记，追踪器只管什么时候探）。
typedef RemoteDictionaryHostProbe = Future<void> Function(String hostId);

/// 词典服务器可达性的**唯一真相源**（BUG-4275）。
///
/// 以前查词路径（`AppModel` 的失败冷却）与目录服务（来源卡片的在线 / 连不上）各记各的：
/// 目录服务早就判了 host 掉线，查词仍要自己再付一遍「3s × 地址数」；目录刷新成功、
/// 卡片已显示在线，查词还要等满自己的 45s 冷却。现在两边都把每次往返的结局写进同
/// 一个实例，也都只读它：
/// * 查词：被判不可达的 host 直接跳过（[shouldSkip]），全部查词 host 都不可达时连远端
///   请求都不发，本机结果不等远端；
/// * 任何一次成功往返（目录刷新、查词、后台探测）立刻把 host 标回可达；
/// * 不可达期间按 [kRemoteDictionaryFailureCooldown] 节奏在后台探测（[probe]），不在查词
///   的关键路径上。主进程由目录服务挂上（`RemoteDictionaryCatalogService.probeHost`，
///   回前台 / 配对列表变化时它经 [probeUnreachableNow] 立刻探）；弹窗进程没有目录服务，
///   由查词客户端挂上（`FushiRemoteLookupClient.probeDictionaryHost`）。
///
/// 没挂探测函数时（只剩单元测试与初始化之前）退回旧口径：不可达的 host 在间隔内跳过，
/// 过了间隔由下一次查词顺带重试。
class RemoteDictionaryReachability {
  RemoteDictionaryReachability({
    DateTime Function() now = DateTime.now,
    Duration reprobeInterval = kRemoteDictionaryFailureCooldown,
  }) : _now = now,
       _reprobeInterval = reprobeInterval;

  final DateTime Function() _now;
  final Duration _reprobeInterval;

  /// [hosts] 变了就 +1（词典管理页据此重建来源卡片）。全进程一份：页面不持有追踪器实例。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  final Map<String, RemoteDictionaryHostReachability> _hosts =
      <String, RemoteDictionaryHostReachability>{};
  final Map<String, Timer> _reprobeTimers = <String, Timer>{};

  /// 正在跑的探测（同一台 host 同时只探一次：定时器与回前台撞在一起时共用这一次）。
  final Map<String, Future<void>> _probing = <String, Future<void>>{};
  RemoteDictionaryHostProbe? _probe;

  /// 每台 host 本次运行里最近一次往返的结局。
  Map<String, RemoteDictionaryHostReachability> get hosts =>
      Map<String, RemoteDictionaryHostReachability>.unmodifiable(_hosts);

  bool isUnreachable(String hostId) => _hosts[hostId]?.failingSince != null;

  /// 查词要不要跳过这台 host。挂着探测函数时，不可达就一直跳过，直到某次往返成功
  /// （探测 / 目录刷新）；没挂时只在距上次尝试不到再探测间隔时跳过。
  bool shouldSkip(String hostId) {
    final RemoteDictionaryHostReachability? r = _hosts[hostId];
    final int? failingSince = r?.failingSince;
    if (r == null || failingSince == null) return false;
    if (_probe != null) return true;
    final int last = r.lastAttemptAt ?? failingSince;
    return _now().millisecondsSinceEpoch - last <
        _reprobeInterval.inMilliseconds;
  }

  /// [hostIds] 非空且每一台都该跳过：远端这一路已知是死的，查词只看本机。
  bool allSkipped(Iterable<String> hostIds) {
    bool any = false;
    for (final String hostId in hostIds) {
      if (!shouldSkip(hostId)) return false;
      any = true;
    }
    return any;
  }

  /// 记下一次请求的按 host 结局（[RemoteHostOutcomes.reachableByHost]）。
  ///
  /// [revision] 只在某台 host 的可见状态变了时 +1（新出现、可达 ↔ 不可达）：每次查词
  /// 都会记一次，状态没变还 bump 的话词典管理页每查一次词就重建一遍来源卡片。
  void record(Map<String, bool> reachableByHost) {
    if (reachableByHost.isEmpty) return;
    final int now = _now().millisecondsSinceEpoch;
    bool changed = false;
    for (final MapEntry<String, bool> e in reachableByHost.entries) {
      final RemoteDictionaryHostReachability? previous = _hosts[e.key];
      final RemoteDictionaryHostReachability next;
      if (e.value) {
        next = RemoteDictionaryHostReachability(
          lastOkAt: now,
          lastAttemptAt: now,
        );
        _reprobeTimers.remove(e.key)?.cancel();
      } else {
        next = RemoteDictionaryHostReachability(
          lastOkAt: previous?.lastOkAt,
          failingSince: previous?.failingSince ?? now,
          lastAttemptAt: now,
        );
      }
      _hosts[e.key] = next;
      if (!e.value) _scheduleReprobe(e.key);
      changed = changed || !_sameVisibleState(previous, next);
    }
    if (changed) revision.value++;
  }

  /// 界面能看出差别的部分（在线 / 连不上自何时 / 从没连上过）是否相同。
  /// [RemoteDictionaryHostReachability.lastAttemptAt] 与成功时刻的刷新不算。
  static bool _sameVisibleState(
    RemoteDictionaryHostReachability? a,
    RemoteDictionaryHostReachability b,
  ) =>
      a != null &&
      a.failingSince == b.failingSince &&
      (a.lastOkAt == null) == (b.lastOkAt == null);

  /// 单台 host 版 [record]。
  void note(String hostId, {required bool reachable}) =>
      record(<String, bool>{hostId: reachable});

  /// 挂上（或摘掉，传 null）后台探测函数。挂上时给已知不可达的 host 排好下一次探测。
  set probe(RemoteDictionaryHostProbe? probe) {
    _probe = probe;
    for (final Timer t in _reprobeTimers.values) {
      t.cancel();
    }
    _reprobeTimers.clear();
    if (probe == null) return;
    for (final String hostId in _hosts.keys) {
      if (isUnreachable(hostId)) _scheduleReprobe(hostId);
    }
  }

  RemoteDictionaryHostProbe? get probe => _probe;

  /// 立刻探一遍全部已知不可达的 host（目录服务回前台 / 配对列表变化时调）。没挂探测
  /// 函数时无事。返回的 Future 在这批探测（含已在跑、被共用的那次）都结束后完成，
  /// 从不报错（探测异常已记进错误日志）。
  Future<void> probeUnreachableNow() => Future.wait<void>(<Future<void>>[
    for (final String hostId in _hosts.keys.toList())
      if (isUnreachable(hostId)) ?_runProbe(hostId),
  ]);

  /// 只留 [hostIds] 的状态（解除配对 / 关掉查词的 host 不再探测、不再占卡片）。
  void retainHosts(Set<String> hostIds) {
    final List<String> gone = <String>[
      for (final String hostId in _hosts.keys)
        if (!hostIds.contains(hostId)) hostId,
    ];
    if (gone.isEmpty) return;
    for (final String hostId in gone) {
      _hosts.remove(hostId);
      _reprobeTimers.remove(hostId)?.cancel();
    }
    revision.value++;
  }

  /// 停掉全部后台探测（App 退出）。状态保留，之后查词按「没挂探测函数」的口径。
  void dispose() => probe = null;

  void _scheduleReprobe(String hostId) {
    if (_probe == null) return;
    _reprobeTimers.remove(hostId)?.cancel();
    _reprobeTimers[hostId] = Timer(_reprobeInterval, () {
      _reprobeTimers.remove(hostId);
      unawaited(_runProbe(hostId));
    });
  }

  /// 发起（或共用正在跑的）一次探测；没挂探测函数时返回 null。
  Future<void>? _runProbe(String hostId) {
    final Future<void>? running = _probing[hostId];
    if (running != null) return running;
    final RemoteDictionaryHostProbe? probe = _probe;
    if (probe == null) return null;
    _reprobeTimers.remove(hostId)?.cancel();
    return _probing[hostId] = () async {
      try {
        await probe(hostId);
      } catch (e, stack) {
        ErrorLogService.instance.log('remoteDictionaryReachability', e, stack);
      } finally {
        _probing.remove(hostId);
        // 探测没留下结局（候选为空、本地读库失败……）而 host 仍记为不可达：照常排下一次，
        // 不让后台探测就此断掉。
        if (identical(_probe, probe) &&
            isUnreachable(hostId) &&
            !_reprobeTimers.containsKey(hostId)) {
          _scheduleReprobe(hostId);
        }
      }
    }();
  }
}
