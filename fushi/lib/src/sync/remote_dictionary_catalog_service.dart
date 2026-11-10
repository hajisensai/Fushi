import 'dart:async';
import 'dart:convert' show jsonDecode;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/profile/remote_dictionary_profile_meta.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/remote_dictionary_reachability.dart';
import 'package:fushi/src/sync/sync_backend.dart' show SyncAuthError;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteDictionaryInfo;

export 'package:fushi/src/sync/remote_dictionary_reachability.dart'
    show
        RemoteDictionaryHostReachability,
        RemoteDictionaryReachability,
        kRemoteDictionaryCatalogPath;

/// 一次对账（[RemoteDictionaryCatalogService.reconcileHost]）改了什么。
@immutable
class RemoteDictionaryCatalogDiff {
  const RemoteDictionaryCatalogDiff({
    this.added = const <String>[],
    this.missing = const <String>[],
    this.reappeared = const <String>[],
  });

  /// 目录里第一次出现的词典（新行，开关取 host 的默认开关、老 host 默认启用，排在
  /// 已有词典之后）。
  final List<String> added;

  /// 这次从 host 目录里消失的词典（记 `missingSince`，行与配置保留）。
  final List<String> missing;

  /// 之前标过消失、这次又回来的词典（清 `missingSince`）。
  final List<String> reappeared;

  bool get isEmpty => added.isEmpty && missing.isEmpty && reappeared.isEmpty;
}

/// 服务器托管词典的本机目录（`remote_dictionary_metadata`）的**唯一刷新者**。
///
/// 对每台开着「用这台服务器查词典」（[FushiClientUrl.lookupEnabled]）的已配对 host
/// 拉一次 [kRemoteDictionaryCatalogPath]，与本机目录行对账（[reconcileHost]）：
/// * 新出现 → 插一行，开关取 host 的默认开关（[RemoteDictionaryInfo.defaultEnabled]，
///   缺省 = 启用），顺序接在全部已有词典（本机 + 服务器）之后；激活配置快照里已有
///   这本、或本机有同名词典时先用它们（优先级见 [reconcileHost]）；
/// * 消失 → 记 `missingSince`，行与各配置的顺序 / 开关都留着；
/// * 消失后又回来 → 清 `missingSince`；
/// * 目录字段（版本 / 显示名 / 语言 …）变化 → 只更新目录列，配置列不动；
/// * host 不可达 / 老 host 没有这个端点 / 凭据被拒 → 什么都不改。
///
/// 触发点：配对列表变化里出现了新的查词 host（配对成功、重新打开查词开关，见
/// [start]）、App 回到前台（[refreshOnResume]，按 host 节流）、同步编排的词典阶段
/// （它本来就拉了清单，直接交给 [reconcileHost]），以及 UI 的显式 [refresh]。
///
/// 写库后经 [catalogRevision] 广播；本实例收到后让 [DictionaryRepository] 重读，
/// 跨实例写入（同步编排）也走这一条，不靠每个写入点记得通知。
///
/// 每次拉清单的按 host 传输层结局写进共享的 [RemoteDictionaryReachability]
/// （BUG-4275：查词路径读的是同一份），并挂上它的后台探测（[probeHost]）：host 判死
/// 之后按再探测间隔轻量拉一次清单，拉通了查词立刻恢复。
class RemoteDictionaryCatalogService {
  RemoteDictionaryCatalogService({
    required FushiDatabase db,
    required SyncRepository syncRepository,
    required InterconnectPostTransport transport,
    DictionaryRepository? dictionaries,
    RemoteDictionaryReachability? reachability,
    DateTime Function() now = DateTime.now,
    Duration timeout = const Duration(seconds: 10),
    Duration probeTimeout = const Duration(seconds: 3),
    Duration resumeRefreshInterval = const Duration(minutes: 10),
  }) : _db = db,
       _syncRepository = syncRepository,
       _transport = transport,
       _dictionaries = dictionaries,
       _reachability = reachability ?? RemoteDictionaryReachability(now: now),
       _now = now,
       _timeout = timeout,
       _probeTimeout = probeTimeout,
       _resumeRefreshInterval = resumeRefreshInterval;

  final FushiDatabase _db;
  final SyncRepository _syncRepository;
  final InterconnectPostTransport _transport;
  final DictionaryRepository? _dictionaries;
  final DateTime Function() _now;
  final Duration _timeout;

  /// 后台再探测（[probeHost]）的往返预算：它只回答「host 回来了没有」，不在任何人的
  /// 关键路径上，但也不该把刷新串行链占上 10s × 地址数。
  final Duration _probeTimeout;
  final Duration _resumeRefreshInterval;

  /// 词典服务器可达性的唯一真相源（与查词路径共用，BUG-4275）。
  final RemoteDictionaryReachability _reachability;

  /// 目录表的进程内「已变更」广播（[reconcileHost] 每次真正改了行就 +1）。
  static final ValueNotifier<int> catalogRevision = ValueNotifier<int>(0);

  /// 每台 host 上次成功拉到清单的时刻（[refreshOnResume] 节流用）。
  final Map<String, DateTime> _lastFetched = <String, DateTime>{};

  /// [hostReachability] 变了就 +1（词典管理页据此重建来源卡片）。
  static ValueNotifier<int> get reachabilityRevision =>
      RemoteDictionaryReachability.revision;

  /// 每台 host（[remoteDictionaryHostIdOf] 口径）本次运行里最近一次互联往返的结局
  /// （拉目录、查词、后台探测都算）。
  Map<String, RemoteDictionaryHostReachability> get hostReachability =>
      _reachability.hosts;

  /// 与查词路径共用的可达性追踪。
  RemoteDictionaryReachability get reachability => _reachability;

  /// [start] 之后看见过的查词 host；配对列表变化时与它比出「新来的」。
  Set<String>? _knownLookupHosts;

  /// 刷新串行化：配对列表连写几次、回前台与显式刷新撞在一起时，同一台 host 不会
  /// 并发对账（对账是「读现有行 → 算差异 → 写」）。
  Future<void> _chain = Future<void>.value();
  bool _started = false;

  /// 开始跟随配对列表与目录广播。重复调用无效果。
  void start() {
    if (_started) return;
    _started = true;
    SyncRepository.fushiClientUrlsRevision.addListener(_onClientUrlsChanged);
    catalogRevision.addListener(_onCatalogChanged);
    _reachability.probe = probeHost;
    _detached(_serial(_syncLookupHosts));
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    SyncRepository.fushiClientUrlsRevision.removeListener(_onClientUrlsChanged);
    catalogRevision.removeListener(_onCatalogChanged);
    if (_reachability.probe == probeHost) _reachability.probe = null;
  }

  /// 后台再探测一台判死的 host（[RemoteDictionaryReachability] 按间隔调）：用短预算拉
  /// 一次清单，结局照常记进可达性追踪；拉通了顺带对账（host 回来时目录本来就该刷）。
  Future<void> probeHost(String hostId) =>
      _serial(() => _refreshHostNow(hostId, timeout: _probeTimeout));

  void _onClientUrlsChanged() => _detached(_serial(_syncLookupHosts));

  /// 监听回调里发起、没人等的刷新：失败已由 [_serial] 记进错误日志，这里只是不让
  /// 同一个错误再冒成未处理异常。
  static void _detached(Future<void> future) =>
      unawaited(future.then<void>((_) {}, onError: (Object _) {}));

  void _onCatalogChanged() {
    final DictionaryRepository? repo = _dictionaries;
    if (repo != null) _detached(_logged(repo.reloadRemoteDictionaries()));
  }

  /// 配对列表变了：先让词典仓库按新的查词 host 集合重算（关掉 / 解除配对的 host
  /// 立刻退出查词过滤），再给新出现的 host 拉一次目录；已知判死的 host 立刻再探一次
  /// （地址可能刚学到 / 刚改过），不等后台间隔——走追踪器的
  /// [RemoteDictionaryReachability.probeUnreachableNow]，与定时再探共用同一次探测。
  Future<void> _syncLookupHosts() async {
    final Set<String> hosts = await _lookupHostIds();
    final Set<String>? known = _knownLookupHosts;
    _knownLookupHosts = hosts;
    _reachability.retainHosts(hosts);
    await _dictionaries?.reloadRemoteDictionaries();
    if (known == null) return;
    // 本方法跑在串行链上，探测（[probeHost]）也排在链上：只发起、不等，不然自等死锁。
    // 先于新 host 的首拉发起：首拉失败的新 host 不会被立刻再探一遍。
    unawaited(_reachability.probeUnreachableNow());
    for (final String hostId in hosts) {
      if (!known.contains(hostId)) await _refreshHostNow(hostId);
    }
  }

  /// 刷新全部查词 host 的目录（UI 的「刷新」）。返回每台 host 的对账结果；拉不到
  /// 清单的 host 不在结果里。
  Future<Map<String, RemoteDictionaryCatalogDiff>> refresh() =>
      _serial(() => _refreshAll(force: true));

  /// App 回到前台：刷新距上次成功拉取超过节流间隔的 host；判死的 host 不受节流，
  /// 回前台立刻再探（BUG-4275，[RemoteDictionaryReachability.probeUnreachableNow]，
  /// 与定时再探共用同一次探测）。返回的差异不含经探测拉到的 host。
  Future<Map<String, RemoteDictionaryCatalogDiff>> refreshOnResume() async {
    // 先发起探测（排在串行链上），再排节流刷新：等到刷新跑完时探测也已跑完。
    final Future<void> probes = _reachability.probeUnreachableNow();
    final Map<String, RemoteDictionaryCatalogDiff> diffs = await _serial(
      () => _refreshAll(force: false),
    );
    await probes;
    return diffs;
  }

  /// 只刷新一台 host（[hostId] 按 [remoteDictionaryHostIdOf] 口径）。
  Future<RemoteDictionaryCatalogDiff?> refreshHost(String hostId) =>
      _serial(() => _refreshHostNow(hostId));

  Future<Map<String, RemoteDictionaryCatalogDiff>> _refreshAll({
    required bool force,
  }) async {
    final Map<String, RemoteDictionaryCatalogDiff> out =
        <String, RemoteDictionaryCatalogDiff>{};
    final DateTime now = _now();
    for (final String hostId in await _lookupHostIds()) {
      if (!force) {
        // 判死的 host 由 [refreshOnResume] 交给探测（[start] 挂上的 [probeHost]）。
        if (_reachability.isUnreachable(hostId)) continue;
        final DateTime? last = _lastFetched[hostId];
        if (last != null && now.difference(last) < _resumeRefreshInterval) {
          continue;
        }
      }
      final RemoteDictionaryCatalogDiff? diff = await _refreshHostNow(hostId);
      if (diff != null) out[hostId] = diff;
    }
    return out;
  }

  Future<Set<String>> _lookupHostIds() async => remoteDictionaryLookupHostIdsOf(
    await _syncRepository.getFushiClientUrls(),
  );

  /// 拉 [hostId] 的清单并对账；拉不到（不可达 / 老 host / 凭据被拒 / 回包畸形）返回
  /// null 且不改任何行。
  Future<RemoteDictionaryCatalogDiff?> _refreshHostNow(
    String hostId, {
    Duration? timeout,
  }) async {
    final List<RemoteDictionaryInfo>? infos = await _fetch(
      hostId,
      timeout: timeout ?? _timeout,
    );
    if (infos == null) return null;
    _lastFetched[hostId] = _now();
    return reconcileHost(
      _db,
      hostId: hostId,
      infos: infos,
      now: _now().millisecondsSinceEpoch,
    );
  }

  /// 拉清单。可达性按**传输层**记（拿到任何响应 = 可达，含老 host 的 404 与凭据被拒
  /// 的 401——对端活着，查词照样该发过去）；清单拿没拿到另由返回值表达。
  Future<List<RemoteDictionaryInfo>?> _fetch(
    String hostId, {
    required Duration timeout,
  }) async {
    final RemoteHostOutcomes outcomes = RemoteHostOutcomes();
    final InterconnectGetOutcome outcome;
    try {
      outcome = await _transport.getJson(
        path: kRemoteDictionaryCatalogPath,
        timeout: timeout,
        authErrorMessage: 'Fushi server rejected dictionary catalog token',
        candidateFilter: (FushiClientUrl candidate) =>
            candidate.isDictionaryLookupCandidate &&
            remoteDictionaryHostIdOf(candidate) == hostId,
        onCandidateOutcome: outcomes.add,
      );
    } on SyncAuthError catch (e, stack) {
      ErrorLogService.instance.log('remoteDictionaryCatalog.auth', e, stack);
      return null;
    } finally {
      _reachability.record(outcomes.reachableByHost);
    }
    return remoteDictionaryInfosFromJson(outcome.json);
  }

  /// [kRemoteDictionaryCatalogPath] 的回包 → 清单；不是数组返回 null（= 没拿到，
  /// 不能当成「host 上一本都没有」去把全部行标成消失）。名字为空的项丢弃。
  static List<RemoteDictionaryInfo>? remoteDictionaryInfosFromJson(
    Object? json,
  ) {
    if (json is! List) return null;
    return <RemoteDictionaryInfo>[
      for (final Object? e in json)
        if (e is Map)
          RemoteDictionaryInfo.fromJson(<String, Object?>{
            for (final MapEntry<Object?, Object?> f in e.entries)
              '${f.key}': f.value,
          }),
    ]..removeWhere((RemoteDictionaryInfo info) => info.name.isEmpty);
  }

  /// 本机 `dictionary_metadata.hiddenLanguagesJson` 是否含 `ja`（= 本机这本词典已关掉，
  /// 与 `Dictionary.isHidden(JapaneseLanguage.instance)` 同一判据）。坏 JSON 当没关。
  static bool _hiddenLanguagesContainJa(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded is List && decoded.contains('ja');
    } on FormatException {
      return false;
    }
  }

  /// 把 [hostId] 的一份完整清单 [infos] 对账进目录表（一个事务），返回差异。
  ///
  /// 静态、只碰库：同步编排的词典阶段已经拉了连接中那台 host 的清单，直接交给这里，
  /// 不用再持有服务实例。真正改了行就 bump [catalogRevision]。
  ///
  /// 新行的顺序 / 开关按优先级取：
  /// 1. 激活配置快照里的 `<hostId>/<真名>`（BUG-4276）——配置从服务器拉下来 / 恢复 /
  ///    导入后先应用、目录后到，或配对时配置早已激活，应用那一刻还没有这一行可写；
  ///    这里补上，配置的选择不必等到下一次切换才生效；
  /// 2. 本机同名词典（刚推送上去的那本，落在本机行的位置、沿用本机开关）；
  /// 3. host 的默认开关，顺序接在全部已有词典之后。
  static Future<RemoteDictionaryCatalogDiff> reconcileHost(
    FushiDatabase db, {
    required String hostId,
    required List<RemoteDictionaryInfo> infos,
    required int now,
  }) async {
    final RemoteDictionaryCatalogDiff diff = await db.transaction(() async {
      final Map<String, RemoteDictionaryMetaRow> existing =
          <String, RemoteDictionaryMetaRow>{
            for (final RemoteDictionaryMetaRow r
                in await db.getAllRemoteDictionaryMetadata())
              if (r.hostId == hostId) r.name: r,
          };
      // 新词典接在**全部**已有词典之后（本机 + 各 host 的服务器词典共用一条数轴）。
      // 本机同名词典按名字记下：刚推送上去的词典在 host 清单里首次出现时，应落在本机
      // 行的位置、沿用本机的开关，而不是排到末尾——否则推送一次就把用户排好的优先级
      // 丢了（场景探针第 1 项的推送半边）。
      int nextOrder = 0;
      final Map<String, DictionaryMetaRow> localByName =
          <String, DictionaryMetaRow>{};
      for (final DictionaryMetaRow r in await db.getAllDictionaryMetadata()) {
        if (r.order >= nextOrder) nextOrder = r.order + 1;
        localByName[r.name] = r;
      }
      // 激活配置的快照只在切走时刷新，可能比 live 行旧（设计如此）；但新行此刻还没有
      // 任何 live 值，快照就是这本词典在当前配置下最好的信息。已有行绝不按它改。
      final Map<String, RemoteDictionaryProfileColumns> profileColumns =
          await activeProfileRemoteDictionaryColumns(db, hostId);
      for (final RemoteDictionaryMetaRow r
          in await db.getAllRemoteDictionaryMetadata()) {
        if (r.order >= nextOrder) nextOrder = r.order + 1;
      }

      final List<String> added = <String>[];
      final List<String> reappeared = <String>[];
      final Set<String> seen = <String>{};
      for (final RemoteDictionaryInfo info in infos) {
        if (info.name.isEmpty || !seen.add(info.name)) continue;
        final RemoteDictionaryMetaRow? row = existing[info.name];
        final RemoteDictionaryProfileColumns? fromProfile = row == null
            ? profileColumns[info.name]
            : null;
        final DictionaryMetaRow? local = row == null && fromProfile == null
            ? localByName[info.name]
            : null;
        // 快照给的顺序可能落在末尾之后：之后接在末尾的新行要排在它后面，不撞号。
        if (fromProfile != null && fromProfile.order >= nextOrder) {
          nextOrder = fromProfile.order + 1;
        }
        if (row == null) {
          added.add(info.name);
        } else if (row.missingSince != null) {
          reappeared.add(info.name);
        }
        await db.upsertRemoteDictionaryCatalog(
          RemoteDictionaryMetadataCompanion(
            hostId: Value<String>(hostId),
            name: Value<String>(info.name),
            type: Value<String>(info.type.isEmpty ? 'term' : info.type),
            formatKey: Value<String?>(info.formatKey),
            revision: Value<String?>(info.revision),
            displayName: Value<String?>(info.displayName),
            sourceLanguage: Value<String?>(info.sourceLanguage),
            lastSeenAt: Value<int>(now),
            missingSince: const Value<int?>(null),
            // 只在插入新行时生效；已有行的顺序 / 开关属于配置，upsert 不碰。
            // 激活配置快照有这本 ⇒ 用快照的位置；本机已有同名词典（刚推送上去的）⇒
            // 沿用本机行的位置；否则接在末尾。
            order: Value<int>(
              row?.order ?? fromProfile?.order ?? local?.order ?? nextOrder++,
            ),
            // 新行的开关：快照 ⇒ 快照的开关；本机有同名词典 ⇒ 沿用本机开关；否则按
            // host 自己的默认开关初始化（host 默认关 ⇒ 本机也先关）；老 host 不发
            // defaultEnabled ⇒ 启用。已有行绝不改。
            hidden: row == null
                ? Value<bool>(
                    fromProfile?.hidden ??
                        (local != null
                            ? _hiddenLanguagesContainJa(
                                local.hiddenLanguagesJson,
                              )
                            : info.defaultEnabled == false),
                  )
                : const Value<bool>.absent(),
          ),
        );
      }
      final List<String> missing = <String>[
        for (final RemoteDictionaryMetaRow r in existing.values)
          if (!seen.contains(r.name) && r.missingSince == null) r.name,
      ];
      await db.markRemoteDictionariesMissing(hostId, missing, now);
      return RemoteDictionaryCatalogDiff(
        added: List<String>.unmodifiable(added),
        missing: List<String>.unmodifiable(missing),
        reappeared: List<String>.unmodifiable(reappeared),
      );
    });
    // 目录列（lastSeenAt / 版本 …）每次都会刷新，改动广播不只看差异：仓库重读一张
    // 几十行的表很便宜，漏掉一次版本变化不划算。
    catalogRevision.value++;
    return diff;
  }

  Future<T> _serial<T>(Future<T> Function() task) {
    final Future<T> result = _chain.then((_) => task());
    _chain = result.then<void>(
      (_) {},
      onError: (Object e, StackTrace stack) =>
          ErrorLogService.instance.log('remoteDictionaryCatalog', e, stack),
    );
    return result;
  }

  static Future<void> _logged(Future<void> future) => future.catchError(
    (Object e, StackTrace stack) => ErrorLogService.instance.log(
      'remoteDictionaryCatalog.reload',
      e,
      stack,
    ),
  );
}
