/// 互联「来源共享」的两端：host 侧出目录与插件包（[AppInterconnectSourceShareHost]），
/// client 侧把 host 的目录合并进本机（[InterconnectSourceShareSync]）。设计见
/// `docs/specs/2026-11-16-interconnect-source-share.md`。
///
/// 合并规则只写在 [planSourceShare] 一处，服务器来源与插件共用。账本
/// （[SourceShareLedger]，设备本地）记「这条是从哪台 host 收来的、收下时是什么摘要」，
/// 据此区分「host 改了」「我在本机改了」「我在本机删了」：
///
/// | host 目录 | 本机 | 账本 | 结果 |
/// |---|---|---|---|
/// | 有 | 没有 | 没有 | 新增，记账 |
/// | 有 | 没有 | 有 | 用户在本机删了：记「不再接收」，以后不再加回来 |
/// | 有 | 有、摘要 = host | 没有 | 认领（记账，以后跟随 host） |
/// | 有 | 有、摘要 ≠ host | 没有 | 本机自己的那份，不动 |
/// | 有、摘要变了 | 有、摘要 = 账本 | 有 | 跟随 host 更新 |
/// | 有 | 有、摘要 ≠ 账本 | 有 | 用户在本机改过：脱离跟随（销账），不再覆盖 |
/// | 没有 | 有、摘要 = 账本 | 有 | host 删了 / 不再共享：本机跟着删 |
/// | 没有 | 摘要 ≠ 账本或已删 | 有 | 销账，本机的不动 |
///
/// 「host 目录没有」只在 host 这一轮完整枚举过的种类（[InterconnectSourceShareCatalog.kinds]）
/// 里才算「不再共享」；host 列不出的（unavailable）与本机列不出的插件（校验不过）都不动、
/// 账本原样保留。
///
/// 插件另有一条：更新时签名者变了不自动装（换签名者 = 换了一个发布者，插件的登录凭据
/// 与存储会被清空，必须用户在这台设备上自己确认），记进 [SourceShareResult.signerChanged]。
/// 签名者以下载下来的包 inspect 出的为准、与本机已装那份比，不信 host 目录里自报的值。
/// 随 app 自带的插件（bundled）两端都不碰。插件是第三方可执行代码，client 另有一道
/// 「也接收插件」开关（默认关，`SyncRepository.isInterconnectSourceSharePluginsEnabled`）：
/// 这台设备的主人自己打开了，host 才能往本机装插件。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi/src/sync/interconnect_source_share_kinds.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/interconnect_source_share.dart';

/// 账本里的一条：收下时的摘要；[declined] = 用户在本机删了，不再接收。
final class SourceShareLedgerEntry {
  const SourceShareLedgerEntry(this.digest, {this.declined = false});

  final String digest;
  final bool declined;

  Map<String, Object?> toJson() => <String, Object?>{
    'd': digest,
    if (declined) 'x': true,
  };

  static SourceShareLedgerEntry? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final Object? d = json['d'];
    if (d is! String) return null;
    return SourceShareLedgerEntry(d, declined: json['x'] == true);
  }

  @override
  bool operator ==(Object other) =>
      other is SourceShareLedgerEntry &&
      other.digest == digest &&
      other.declined == declined;

  @override
  int get hashCode => Object.hash(digest, declined);
}

/// 设备本地账本：hostId → (`kind/id` → 条目)。
final class SourceShareLedger {
  SourceShareLedger(this.hosts);

  /// 偏好键（设备本地：在 `SyncRepository.deviceLocalPrefKeys`，不随备份 / 设置同步出境）。
  static const String prefKey = 'interconnect_source_share_ledger';

  final Map<String, Map<String, SourceShareLedgerEntry>> hosts;

  static Future<SourceShareLedger> load(FushiDatabase db) async {
    final String raw = await db.getPrefTyped<String>(prefKey, '');
    final Map<String, Map<String, SourceShareLedgerEntry>> hosts =
        <String, Map<String, SourceShareLedgerEntry>>{};
    if (raw.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final MapEntry<Object?, Object?> host in decoded.entries) {
            final Object? entries = host.value;
            if (host.key is! String || entries is! Map) continue;
            hosts[host.key! as String] = <String, SourceShareLedgerEntry>{
              for (final MapEntry<Object?, Object?> e in entries.entries)
                if (e.key is String)
                  if (SourceShareLedgerEntry.tryFromJson(e.value)
                      case final SourceShareLedgerEntry entry)
                    e.key! as String: entry,
            };
          }
        }
      } on FormatException {
        // 坏账本当空：最坏是把本机已有的同一份配置重新认领一次，不丢数据。
      }
    }
    return SourceShareLedger(hosts);
  }

  Future<void> save(FushiDatabase db) => db.setPrefTyped<String>(
    prefKey,
    jsonEncode(<String, Object?>{
      for (final MapEntry<String, Map<String, SourceShareLedgerEntry>> h
          in hosts.entries)
        if (h.value.isNotEmpty)
          h.key: <String, Object?>{
            for (final MapEntry<String, SourceShareLedgerEntry> e
                in h.value.entries)
              e.key: e.value.toJson(),
          },
    }),
  );
}

/// 一步要做的事。
enum SourceShareStepKind { add, update, remove }

/// [planSourceShare] 的一步：执行成功后把账本里 [id] 的条目设成 [ledgerAfter]（null = 销账）。
final class SourceShareStep {
  const SourceShareStep(this.kind, this.id, this.offered, this.ledgerAfter);

  final SourceShareStepKind kind;
  final String id;

  /// add / update 时 host 的那条。
  final InterconnectSharedSource? offered;
  final SourceShareLedgerEntry? ledgerAfter;
}

/// 一类来源的合并计划。
final class SourceSharePlan {
  const SourceSharePlan(this.steps, this.ledger, this.signerChanged);

  final List<SourceShareStep> steps;

  /// 不需要动本机、只改账本的结果（认领 / 不再接收 / 销账）；[steps] 成功后再叠上去。
  final Map<String, SourceShareLedgerEntry> ledger;

  /// 签名者变了、没有自动更新的插件（label）。
  final List<String> signerChanged;
}

/// 本机一条来源的摘要（插件还带签名者）。
typedef SourceShareLocal = ({String digest, String? signer});

/// 合并规则（见文件头的表）。[local] / [offered] / [ledger] 都按 id；[untouchable] 是本机
/// 随 app 自带的插件 id；[held] 是本机列不出（校验不过）的插件 id——与 host 的
/// unavailable 条目一样不动、留账。[checkSigner] 为 true 时（插件）更新前核对签名者。
/// [propagateRemovals] 为 false（host 这一轮没完整枚举这个种类）时「目录里没有」不算删除。
SourceSharePlan planSourceShare({
  required Map<String, SourceShareLocal> local,
  required Map<String, InterconnectSharedSource> offered,
  required Map<String, SourceShareLedgerEntry> ledger,
  Set<String> untouchable = const <String>{},
  Set<String> held = const <String>{},
  bool checkSigner = false,
  bool propagateRemovals = true,
}) {
  final List<SourceShareStep> steps = <SourceShareStep>[];
  final Map<String, SourceShareLedgerEntry> next =
      Map<String, SourceShareLedgerEntry>.of(ledger);
  final List<String> signerChanged = <String>[];
  for (final InterconnectSharedSource o in offered.values) {
    if (untouchable.contains(o.id)) {
      next.remove(o.id);
      continue;
    }
    // 一端列不出：什么都不做，账本原样（next 是 ledger 的拷贝）。
    if (o.unavailable || held.contains(o.id)) continue;
    final SourceShareLedgerEntry? e = ledger[o.id];
    final SourceShareLocal? l = local[o.id];
    final SourceShareLedgerEntry adopted = SourceShareLedgerEntry(o.digest);
    if (e != null && e.declined) continue;
    if (l == null) {
      if (e != null) {
        next[o.id] = SourceShareLedgerEntry(e.digest, declined: true);
      } else {
        steps.add(SourceShareStep(SourceShareStepKind.add, o.id, o, adopted));
      }
      continue;
    }
    if (e == null) {
      if (l.digest == o.digest) next[o.id] = adopted;
      continue;
    }
    if (l.digest != e.digest) {
      next.remove(o.id);
      continue;
    }
    if (o.digest == e.digest) continue;
    if (checkSigner && l.signer != o.signer) {
      signerChanged.add(o.label);
      continue;
    }
    steps.add(SourceShareStep(SourceShareStepKind.update, o.id, o, adopted));
  }
  for (final MapEntry<String, SourceShareLedgerEntry> entry in ledger.entries) {
    if (offered.containsKey(entry.key)) continue;
    if (!propagateRemovals || held.contains(entry.key)) continue;
    final SourceShareLocal? l = local[entry.key];
    final bool follows =
        !entry.value.declined &&
        !untouchable.contains(entry.key) &&
        l != null &&
        l.digest == entry.value.digest;
    if (follows) {
      steps.add(
        SourceShareStep(SourceShareStepKind.remove, entry.key, null, null),
      );
    } else {
      next.remove(entry.key);
    }
  }
  return SourceSharePlan(steps, next, signerChanged);
}

/// 一轮合并的结果。
final class SourceShareResult {
  int added = 0;
  int updated = 0;
  int removed = 0;

  /// 签名者变了、等用户在本机自己确认的插件名。
  final List<String> signerChanged = <String>[];

  /// 单条失败（坏包 / 摘要对不上 / 安装失败）：不中断其余条目。
  final List<String> errors = <String>[];

  int get changed => added + updated + removed;
}

/// 从 host 取东西的两个口子（[InterconnectSyncBackend] 实现；测试注入假的）。
abstract interface class SourceShareRemote {
  /// host 的目录；host 不提供（旧版本 / 明文 / 关着 / 本机不是它的「我的设备」）为 null。
  Future<InterconnectSourceShareCatalog?> getRemoteSourceShareCatalog();

  Future<Uint8List> getRemoteSourceSharePackage(String kind, String id);
}

/// client 侧：一轮把 host [hostId] 的目录合并进本机。
final class InterconnectSourceShareSync {
  InterconnectSourceShareSync(
    this._db, {
    required List<SharedPluginStore> pluginStores,
    this.cachedPrefWriter,
  }) : _pluginStores = pluginStores;

  final FushiDatabase _db;
  final List<SharedPluginStore> _pluginStores;

  /// 服务器来源清单经偏好缓存写回（见 [SharedServerListKind.write]）。
  final SourceSharePrefWriter? cachedPrefWriter;

  Future<SourceShareResult> run(SourceShareRemote remote, String hostId) async {
    final SourceShareResult result = SourceShareResult();
    final SyncRepository repo = SyncRepository(_db);
    // 本机「接收共享来源」开关：关着连请求都不发（不是拉回来再丢弃）。
    if (!await repo.isInterconnectSourceShareEnabled()) {
      return result;
    }
    // 插件是第三方可执行代码：本机主人没打开「也接收插件」时整类跳过、账本原样留着，
    // 与本机没有插件体系同一处理。
    final List<SharedPluginStore> pluginStores =
        await repo.isInterconnectSourceSharePluginsEnabled()
        ? _pluginStores
        : const <SharedPluginStore>[];
    final InterconnectSourceShareCatalog? catalog = await remote
        .getRemoteSourceShareCatalog();
    if (catalog == null) return result;
    final SourceShareLedger ledger = await SourceShareLedger.load(_db);
    final Map<String, SourceShareLedgerEntry> hostLedger =
        ledger.hosts[hostId] ?? <String, SourceShareLedgerEntry>{};
    final Map<String, SourceShareLedgerEntry> nextLedger =
        <String, SourceShareLedgerEntry>{};

    for (final SharedServerListKind kind in kSharedServerListKinds) {
      nextLedger.addAll(
        await _mergeServers(
          kind,
          catalog,
          _slice(hostLedger, kind.kind),
          result,
        ),
      );
    }
    for (final SharedPluginStore store in pluginStores) {
      nextLedger.addAll(
        await _mergePlugins(
          store,
          remote,
          catalog,
          _slice(hostLedger, store.kind),
          result,
        ),
      );
    }
    // 本机这一轮没有处理的种类（例如 iOS 没有插件体系）原样留账，换回来时接着跟随。
    final Set<String> handled = <String>{
      for (final SharedServerListKind k in kSharedServerListKinds) k.kind,
      for (final SharedPluginStore s in pluginStores) s.kind,
    };
    for (final MapEntry<String, SourceShareLedgerEntry> e
        in hostLedger.entries) {
      if (!handled.contains(e.key.split('/').first)) {
        nextLedger[e.key] = e.value;
      }
    }
    ledger.hosts[hostId] = nextLedger;
    await ledger.save(_db);
    return result;
  }

  static Map<String, SourceShareLedgerEntry> _slice(
    Map<String, SourceShareLedgerEntry> hostLedger,
    String kind,
  ) => <String, SourceShareLedgerEntry>{
    for (final MapEntry<String, SourceShareLedgerEntry> e in hostLedger.entries)
      if (e.key.startsWith('$kind/')) e.key.substring(kind.length + 1): e.value,
  };

  static Map<String, SourceShareLedgerEntry> _keyed(
    String kind,
    Map<String, SourceShareLedgerEntry> byId,
  ) => <String, SourceShareLedgerEntry>{
    for (final MapEntry<String, SourceShareLedgerEntry> e in byId.entries)
      '$kind/${e.key}': e.value,
  };

  static Map<String, InterconnectSharedSource> _offered(
    InterconnectSourceShareCatalog catalog,
    String kind,
  ) => <String, InterconnectSharedSource>{
    for (final InterconnectSharedSource s in catalog.sources)
      if (s.kind == kind) s.id: s,
  };

  Future<Map<String, SourceShareLedgerEntry>> _mergeServers(
    SharedServerListKind kind,
    InterconnectSourceShareCatalog catalog,
    Map<String, SourceShareLedgerEntry> ledger,
    SourceShareResult result,
  ) async {
    final List<Map<String, Object?>> raw = await kind.read(_db);
    final Map<String, SourceShareLocal> local = <String, SourceShareLocal>{};
    final List<String?> idsInOrder = <String?>[];
    for (final Map<String, Object?> item in raw) {
      final SharedServerEntry? entry = kind.normalize(item);
      idsInOrder.add(entry?.id);
      if (entry != null && !local.containsKey(entry.id)) {
        local[entry.id] = (
          digest: sourceShareConfigDigest(entry.json),
          signer: null,
        );
      }
    }
    // host 发来的配置也过一遍本机解码：对端版本不同、条目坏了的不收。
    final Map<String, InterconnectSharedSource> offered =
        <String, InterconnectSharedSource>{};
    for (final InterconnectSharedSource s in _offered(
      catalog,
      kind.kind,
    ).values) {
      final Map<String, Object?>? config = s.config;
      if (config == null) continue;
      final SharedServerEntry? entry = kind.normalize(config);
      if (entry == null || entry.id != s.id) continue;
      offered[s.id] = sharedServerSource(kind, entry);
    }
    final SourceSharePlan plan = planSourceShare(
      local: local,
      offered: offered,
      ledger: ledger,
      propagateRemovals: catalog.kinds.contains(kind.kind),
    );
    final Map<String, SourceShareLedgerEntry> next = plan.ledger;
    if (plan.steps.isEmpty) return _keyed(kind.kind, next);

    final List<Map<String, Object?>> items = List<Map<String, Object?>>.of(raw);
    for (final SourceShareStep step in plan.steps) {
      final int index = idsInOrder.indexOf(step.id);
      switch (step.kind) {
        case SourceShareStepKind.add:
          items.add(step.offered!.config!);
          idsInOrder.add(step.id);
          result.added++;
        case SourceShareStepKind.update:
          items[index] = <String, Object?>{
            ...step.offered!.config!,
            for (final String field in kind.deviceLocalFields)
              if (items[index].containsKey(field)) field: items[index][field],
          };
          result.updated++;
        case SourceShareStepKind.remove:
          items.removeAt(index);
          idsInOrder.removeAt(index);
          result.removed++;
      }
      if (step.ledgerAfter case final SourceShareLedgerEntry after) {
        next[step.id] = after;
      } else {
        next.remove(step.id);
      }
    }
    await kind.write(_db, items, cachedWriter: cachedPrefWriter);
    return _keyed(kind.kind, next);
  }

  Future<Map<String, SourceShareLedgerEntry>> _mergePlugins(
    SharedPluginStore store,
    SourceShareRemote remote,
    InterconnectSourceShareCatalog catalog,
    Map<String, SourceShareLedgerEntry> ledger,
    SourceShareResult result,
  ) async {
    final List<SharedPluginPackage> installed = await store.installed();
    final Map<String, SourceShareLocal> local = <String, SourceShareLocal>{
      for (final SharedPluginPackage p in installed)
        if (p.available) p.id: (digest: p.digest, signer: p.signer),
    };
    final SourceSharePlan plan = planSourceShare(
      local: local,
      offered: _offered(catalog, store.kind),
      ledger: ledger,
      untouchable: <String>{
        for (final SharedPluginPackage p in installed)
          if (p.bundled) p.id,
      },
      held: <String>{
        for (final SharedPluginPackage p in installed)
          if (!p.available) p.id,
      },
      checkSigner: true,
      propagateRemovals: catalog.kinds.contains(store.kind),
    );
    result.signerChanged.addAll(plan.signerChanged);
    final Map<String, SourceShareLedgerEntry> next = plan.ledger;
    for (final SourceShareStep step in plan.steps) {
      try {
        if (step.kind == SourceShareStepKind.remove) {
          await store.uninstall(step.id);
          result.removed++;
        } else {
          final InterconnectSharedSource offered = step.offered!;
          final Uint8List zip = await remote.getRemoteSourceSharePackage(
            store.kind,
            step.id,
          );
          final SharedPluginPackage pending = await store.inspect(zip);
          // 摘要 = host 上用户确认安装的那份；对不上（传输损坏 / host 中途换了包）不装。
          if (pending.id != step.id || pending.digest != offered.digest) {
            throw FormatException(
              'package digest mismatch for ${store.kind}/${step.id}',
            );
          }
          if (pending.bundled) continue;
          // 签名者以实际下载的包为准、与本机已装那份比（目录里的 signer 是 host 自报的）：
          // 变了不装、不记账，宿主装的话会按新插件清掉本机的登录凭据与存储。
          if (step.kind == SourceShareStepKind.update &&
              pending.signer != local[step.id]?.signer) {
            result.signerChanged.add(offered.label);
            continue;
          }
          await store.install(zip, pending.digest);
          if (step.kind == SourceShareStepKind.add) {
            result.added++;
          } else {
            result.updated++;
          }
        }
        if (step.ledgerAfter case final SourceShareLedgerEntry after) {
          next[step.id] = after;
        } else {
          next.remove(step.id);
        }
      } on Object catch (e) {
        // 失败的这一步不记账：下一轮照同一规则重试。
        if (step.kind == SourceShareStepKind.add) next.remove(step.id);
        result.errors.add('${store.kind}/${step.id}: $e');
      }
    }
    return _keyed(store.kind, next);
  }
}

/// host 侧：从本机偏好与插件体系出目录 / 插件包。
final class AppInterconnectSourceShareHost
    implements InterconnectSourceShareHost {
  AppInterconnectSourceShareHost({
    required FushiDatabase db,
    required Future<bool> Function() enabled,
    required Future<bool> Function(String peerToken) isOwnerDevicePeer,
    required List<SharedPluginStore> Function() pluginStores,
    Future<Set<String>> Function()? selected,
  }) : _db = db,
       _enabled = enabled,
       _isOwnerDevicePeer = isOwnerDevicePeer,
       _pluginStores = pluginStores,
       _selected =
           selected ??
           (() => SyncRepository(db).getInterconnectSourceShareHostItems());

  final FushiDatabase _db;
  final Future<bool> Function() _enabled;
  final Future<bool> Function(String peerToken) _isOwnerDevicePeer;
  final List<SharedPluginStore> Function() _pluginStores;

  /// host 主人逐项勾选共享的 `kind/id`（默认空 = 一条都不共享）。
  final Future<Set<String>> Function() _selected;

  @override
  Future<bool> isSourceShareEnabled() => _enabled();

  @override
  Future<bool> isOwnerDevicePeer(String peerToken) =>
      _isOwnerDevicePeer(peerToken);

  /// 本机全部可共享的来源（不看勾选）：设置页「选择要共享的来源」列它，
  /// [sourceShareCatalog] 在它上面按勾选过滤。[InterconnectSourceShareCatalog.kinds]
  /// = 这一轮完整枚举过的种类（服务器清单总在；插件体系此刻建好了才在）。
  Future<InterconnectSourceShareCatalog> shareableSources() async {
    final List<InterconnectSharedSource> sources = <InterconnectSharedSource>[];
    final Set<String> kinds = <String>{};
    for (final SharedServerListKind kind in kSharedServerListKinds) {
      final Set<String> seen = <String>{};
      for (final Map<String, Object?> raw in await kind.read(_db)) {
        final SharedServerEntry? entry = kind.normalize(raw);
        if (entry == null || !seen.add(entry.id)) continue;
        sources.add(sharedServerSource(kind, entry));
      }
      kinds.add(kind.kind);
    }
    for (final SharedPluginStore store in _pluginStores()) {
      for (final SharedPluginPackage p in await store.installed()) {
        if (p.bundled) continue;
        sources.add(
          p.available
              ? InterconnectSharedSource(
                  kind: store.kind,
                  id: p.id,
                  label: p.label,
                  digest: p.digest,
                  signer: p.signer,
                )
              : InterconnectSharedSource.unavailable(
                  kind: store.kind,
                  id: p.id,
                  label: p.label,
                ),
        );
      }
      kinds.add(store.kind);
    }
    return InterconnectSourceShareCatalog(sources, kinds: kinds);
  }

  /// 只出 host 主人勾选过的条目；[InterconnectSourceShareCatalog.kinds] 照实带上，
  /// client 据此把「取消勾选 / 删了」传播成删除，把「列不出」当成不动。
  @override
  Future<InterconnectSourceShareCatalog> sourceShareCatalog() async {
    final Set<String> selected = await _selected();
    final InterconnectSourceShareCatalog all = await shareableSources();
    return InterconnectSourceShareCatalog(<InterconnectSharedSource>[
      for (final InterconnectSharedSource s in all.sources)
        if (selected.contains(s.key)) s,
    ], kinds: all.kinds);
  }

  @override
  Future<Uint8List?> sourceSharePackage(String kind, String id) async {
    if (!(await _selected()).contains('$kind/$id')) return null;
    for (final SharedPluginStore store in _pluginStores()) {
      if (store.kind != kind) continue;
      final bool shared = (await store.installed()).any(
        (SharedPluginPackage p) => p.id == id && !p.bundled && p.available,
      );
      return shared ? store.exportPackage(id) : null;
    }
    return null;
  }
}
