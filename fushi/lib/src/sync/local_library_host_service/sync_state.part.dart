part of '../local_library_host_service.dart';

/// 同步状态域（B4 按域拆出）：Profile 传输、互联 service-config、活动流、聚合快照、合集清单、删除墓碑。
/// 方法逐字搬自 LocalLibraryHostService。
mixin _LocalLibraryHostSyncState
    on _LocalLibraryHostBase, _LocalLibraryHostShared {
  @override
  Future<bool> isInterconnectProfileTransferEnabled() async {
    // 三者缺一即视为不可用：没有导出/导入回调时开着开关也无从服务。
    final Future<bool> Function()? enabled = _isProfileTransferEnabled;
    if (enabled == null) return false;
    if (_exportActiveProfileJson == null || _importProfileJson == null) {
      return false;
    }
    return enabled();
  }

  /// 导出**也**要串行：激活 Profile 的导出会先 `snapshotCurrentSettings()`，
  /// 那是一次写库 —— 一个远端 GET 就能和正在跑的备份恢复 / 集合同步交错。
  @override
  Future<String> exportInterconnectProfile() async {
    final Future<String> Function()? export = _exportActiveProfileJson;
    if (export == null) {
      throw UnsupportedError('profile export not wired on this host');
    }
    late final String json;
    await _runExclusive(() async {
      json = await export();
    });
    return json;
  }

  /// 导入必须串行：底下的 `importProfileFromJson` 是跨三个 await 的
  /// check-then-act（算唯一名 → 建 Profile → 写设置）。两个并发对端（或一个对端
  /// 重试）会算出**同一个名字**，而且在建行与写设置之间存在一个「有名字、零设置」
  /// 的半成品 Profile 对本机 UI 可见。client 侧的 `_busy` 只挡本机重复点击，挡不
  /// 住并发对端 —— 串行锁得由 host 侧兜。
  @override
  Future<String> importInterconnectProfile(String json) async {
    final Future<String> Function(String json)? import = _importProfileJson;
    if (import == null) {
      throw UnsupportedError('profile import not wired on this host');
    }
    late final String name;
    await _runExclusive(() async {
      name = await import(json);
    });
    return name;
  }

  @override
  Future<InterconnectServiceConfigSnapshot>
      getInterconnectServiceConfig() async {
    return InterconnectServiceConfigSnapshot.fromPreferences(
      await _db.getAllPrefs(),
    );
  }

  /// host 最近 [limit] 条活动事件（新首页 Activity 面板互联数据源）。
  @override
  Future<List<RemoteActivityEvent>> listActivityEvents(
      {int limit = 100}) async {
    // v92：活动流唯一数据源是统一事实面（legacy 活动行 ∪ 段 ∪ 游玩会话合成行），
    // 与本机首页同一份；否则 client 看不到 host 在 v92 之后的任何阅读 / 观看。
    final List<ActivityEventRow> rows =
        (await loadStatFacts(_db, activityLimit: limit)).activityRows;
    return <RemoteActivityEvent>[
      for (final ActivityEventRow r in rows)
        RemoteActivityEvent(
          eventType: r.eventType,
          mediaType: r.mediaType,
          title: r.title,
          dateKey: r.dateKey,
          timestampMs: r.timestampMs,
          mediaKey: r.mediaKey,
          durationMs: r.durationMs,
          charsDelta: r.charsDelta,
        ),
    ];
  }

  // ── 聚合（统计 + 收藏，TODO-1056 phase C）────────────────────────────────────

  /// 读 host 端当前聚合快照。直接复用云后端 phase B 的
  /// [AggregateSyncService.materializeLocalSnapshot]（同一 DB 读取逻辑），保证互联
  /// 与云通道 materialize 结果字节等价、无第二套实现。
  @override
  Future<AggregateSnapshot> getAggregateSnapshot() async {
    return AggregateSyncService(_db).materializeLocalSnapshot();
  }

  /// 把 client 上报的聚合快照折叠进 host DB。用
  /// [AggregateSyncService.foldIntoLocal]（先 materialize host 自己 → MAX / 并集
  /// 合并 incoming → apply），保证 host 侧也满足 never-shrinks：client 上报的某字段
  /// 即便小于 host 当前值（并发 / GET 后 host 又涨），MAX 折叠让 host 值不被缩小；
  /// 幂等（重复 apply 同一快照不变）；删除不跨端传播。经 [_runExclusive] 与其它库
  /// 变动串行，避免与 host 本机写统计/收藏竞态。
  @override
  Future<void> applyAggregateSnapshot(AggregateSnapshot snapshot) async {
    await _runExclusive(
      () => AggregateSyncService(_db).foldIntoLocal(snapshot),
    );
  }

  // ── 合集清单（多端库联合视图 §2.3 任务5.2）──────────────────────────────────

  /// 读 host 合集全量快照清单。直接复用云后端同一 [loadLocalCollectionManifest]（同一
  /// DB 读取逻辑），保证互联与云通道 materialize 结果字节等价、无第二套实现。
  @override
  Future<CollectionManifest> getCollectionManifest() =>
      loadLocalCollectionManifest(_db);

  /// 把 client 上报的合集清单并入 host DB 并返回合并后清单。
  ///
  /// 与云后端 orchestrator [SyncOrchestrator.syncCollections] 的核心完全同构，仅
  /// 通道不同：`CollectionSyncEngine.merge`（host 自身 `sync_collections_baseline_ms`
  /// 因果基线）→ [applyCollectionLocalChanges] 把本地变更集落 host DB → 推进 host
  /// 基线 → 返回合并后清单（client 端再拿它重跑引擎收敛，双端同一并集）。
  ///
  /// 基线的角色：区分「未见过的移出/删除墓碑」（新闻 → 生效）与「本端已裁决过、
  /// 成员/合集仍在即代表之后重加/重建」（旧闻 → 活胜）。host 每次合并成功后推进基线，
  /// 使已应用的墓碑成为「旧闻」，日后本端或对端重加时不被旧墓碑再删（收敛正确性依赖
  /// 此推进，见 collection_sync_engine 注释）。
  ///
  /// 经 [_runExclusive] 与其它库变动串行：读清单→合并→落库→推基线整体互斥，
  /// 避免与 host 本机合集编辑竞态。重放同一清单幂等（应用端按目标态调和）。
  @override
  Future<CollectionManifest> mergeCollectionManifest(
    CollectionManifest incoming,
  ) async {
    late CollectionManifest merged;
    await _runExclusive(() async {
      final CollectionManifest local = await loadLocalCollectionManifest(_db);
      final SyncRepository repo = SyncRepository(_db);
      // BUG-1579：host 收 POST 走**自己那本账**（[SyncChannelScope.host]）。它与
      // 本机作为 client 跑的云/互联通道是三条独立的因果轴：共用一个键时，client
      // 通道刚推进的基线会把对端 POST 来的移出墓碑判成旧闻 → 引擎按「活胜」撤销
      // → 再回传给对端，用户的移出被自己另一条通道悄悄撤销。
      final int baseline =
          await repo.getCollectionsSyncBaselineMs(SyncChannelScope.host);
      final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
        local: local,
        remote: incoming,
        lastSyncedAtMs: baseline,
      );
      await applyCollectionLocalChanges(_db, outcome.changes);
      await repo.setCollectionsSyncBaselineMs(
          SyncChannelScope.host, DateTime.now().millisecondsSinceEpoch);
      merged = outcome.merged;
    });
    return merged;
  }

  @override
  Future<List<({String mediaType, String itemKey, int deletedAt})>>
      listDeletionTombstones() async {
    final List<SyncDeletionTombstoneRow> rows =
        await _db.getSyncDeletionTombstones();
    return <({String mediaType, String itemKey, int deletedAt})>[
      for (final SyncDeletionTombstoneRow r in rows)
        (mediaType: r.mediaType, itemKey: r.itemKey, deletedAt: r.deletedAt),
    ];
  }
}
