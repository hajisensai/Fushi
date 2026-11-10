import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/sync_backend.dart' show SyncAuthError;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteDictionaryInfo;

/// 已配对 host 上托管的词典清单端点（`fushi_library_host_service` 的 `listDictionaries`）。
const String kRemoteDictionaryCatalogPath = '/api/library/dictionaries';

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
///   缺省 = 启用），顺序接在全部已有词典（本机 + 服务器）之后；
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
/// 一台 host 在本进程里最近一次拉目录的结果（词典管理页的来源卡片显示「在线 /
/// 自某时起连不上」）。只记本次运行看到的：重启后为空，界面退回目录行的
/// `lastSeenAt`（「最近在线」）。
@immutable
class RemoteDictionaryHostReachability {
  const RemoteDictionaryHostReachability({this.lastOkAt, this.failingSince});

  /// 最近一次成功拉到清单的时刻（ms）。
  final int? lastOkAt;

  /// 自这一刻起连续拉不到清单（ms）；null = 最近一次是成功的（或还没试过）。
  final int? failingSince;

  bool get reachable => failingSince == null && lastOkAt != null;
}

class RemoteDictionaryCatalogService {
  RemoteDictionaryCatalogService({
    required FushiDatabase db,
    required SyncRepository syncRepository,
    required InterconnectPostTransport transport,
    DictionaryRepository? dictionaries,
    DateTime Function() now = DateTime.now,
    Duration timeout = const Duration(seconds: 10),
    Duration resumeRefreshInterval = const Duration(minutes: 10),
  }) : _db = db,
       _syncRepository = syncRepository,
       _transport = transport,
       _dictionaries = dictionaries,
       _now = now,
       _timeout = timeout,
       _resumeRefreshInterval = resumeRefreshInterval;

  final FushiDatabase _db;
  final SyncRepository _syncRepository;
  final InterconnectPostTransport _transport;
  final DictionaryRepository? _dictionaries;
  final DateTime Function() _now;
  final Duration _timeout;
  final Duration _resumeRefreshInterval;

  /// 目录表的进程内「已变更」广播（[reconcileHost] 每次真正改了行就 +1）。
  static final ValueNotifier<int> catalogRevision = ValueNotifier<int>(0);

  /// 每台 host 上次成功拉到清单的时刻（[refreshOnResume] 节流用）。
  final Map<String, DateTime> _lastFetched = <String, DateTime>{};

  /// 每台 host 最近一次拉目录的结果（见 [hostReachability]）。
  final Map<String, RemoteDictionaryHostReachability> _reachability =
      <String, RemoteDictionaryHostReachability>{};

  /// [hostReachability] 变了就 +1（词典管理页据此重建来源卡片）。
  static final ValueNotifier<int> reachabilityRevision = ValueNotifier<int>(0);

  /// 每台 host（[remoteDictionaryHostIdOf] 口径）本次运行里最近一次拉目录的结果。
  Map<String, RemoteDictionaryHostReachability> get hostReachability =>
      Map<String, RemoteDictionaryHostReachability>.unmodifiable(_reachability);

  void _noteReachability(String hostId, {required bool ok}) {
    final int now = _now().millisecondsSinceEpoch;
    final RemoteDictionaryHostReachability? previous = _reachability[hostId];
    _reachability[hostId] = ok
        ? RemoteDictionaryHostReachability(lastOkAt: now)
        : RemoteDictionaryHostReachability(
            lastOkAt: previous?.lastOkAt,
            failingSince: previous?.failingSince ?? now,
          );
    reachabilityRevision.value++;
  }

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
    _detached(_serial(_syncLookupHosts));
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    SyncRepository.fushiClientUrlsRevision.removeListener(_onClientUrlsChanged);
    catalogRevision.removeListener(_onCatalogChanged);
  }

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
  /// 立刻退出查词过滤），再给新出现的 host 拉一次目录。
  Future<void> _syncLookupHosts() async {
    final Set<String> hosts = await _lookupHostIds();
    final Set<String>? known = _knownLookupHosts;
    _knownLookupHosts = hosts;
    await _dictionaries?.reloadRemoteDictionaries();
    if (known == null) return;
    for (final String hostId in hosts.difference(known)) {
      await _refreshHostNow(hostId);
    }
  }

  /// 刷新全部查词 host 的目录（UI 的「刷新」）。返回每台 host 的对账结果；拉不到
  /// 清单的 host 不在结果里。
  Future<Map<String, RemoteDictionaryCatalogDiff>> refresh() =>
      _serial(() => _refreshAll(force: true));

  /// App 回到前台：刷新距上次成功拉取超过节流间隔的 host。
  Future<Map<String, RemoteDictionaryCatalogDiff>> refreshOnResume() =>
      _serial(() => _refreshAll(force: false));

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
      final DateTime? last = _lastFetched[hostId];
      if (!force &&
          last != null &&
          now.difference(last) < _resumeRefreshInterval) {
        continue;
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
  Future<RemoteDictionaryCatalogDiff?> _refreshHostNow(String hostId) async {
    final List<RemoteDictionaryInfo>? infos;
    try {
      infos = await _fetch(hostId);
    } catch (_) {
      _noteReachability(hostId, ok: false);
      rethrow;
    }
    _noteReachability(hostId, ok: infos != null);
    if (infos == null) return null;
    _lastFetched[hostId] = _now();
    return reconcileHost(
      _db,
      hostId: hostId,
      infos: infos,
      now: _now().millisecondsSinceEpoch,
    );
  }

  Future<List<RemoteDictionaryInfo>?> _fetch(String hostId) async {
    final InterconnectGetOutcome outcome;
    try {
      outcome = await _transport.getJson(
        path: kRemoteDictionaryCatalogPath,
        timeout: _timeout,
        authErrorMessage: 'Fushi server rejected dictionary catalog token',
        candidateFilter: (FushiClientUrl candidate) =>
            candidate.isDictionaryLookupCandidate &&
            remoteDictionaryHostIdOf(candidate) == hostId,
      );
    } on SyncAuthError catch (e, stack) {
      ErrorLogService.instance.log('remoteDictionaryCatalog.auth', e, stack);
      return null;
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

  /// 把 [hostId] 的一份完整清单 [infos] 对账进目录表（一个事务），返回差异。
  ///
  /// 静态、只碰库：同步编排的词典阶段已经拉了连接中那台 host 的清单，直接交给这里，
  /// 不用再持有服务实例。真正改了行就 bump [catalogRevision]。
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
      int nextOrder = 0;
      for (final DictionaryMetaRow r in await db.getAllDictionaryMetadata()) {
        if (r.order >= nextOrder) nextOrder = r.order + 1;
      }
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
            order: Value<int>(row?.order ?? nextOrder++),
            // 新行的开关按 host 自己的默认开关初始化（host 默认关 ⇒ 本机也先关）；
            // 老 host 不发 defaultEnabled ⇒ 启用。已有行绝不改。
            hidden: row == null
                ? Value<bool>(info.defaultEnabled == false)
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
