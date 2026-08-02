import 'package:flutter/foundation.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_index.dart';
import 'package:hibiki/src/sync/sync_repository.dart';

/// 读写 `__index__` 命名空间：一轮同步开始时出「哪些活可以不干」的计划，结束时把
/// 本端这一轮的观测结果发布回去。
///
/// ## 为什么需要 dirty 租约
///
/// 索引让别的设备据此**跳过**某本书。跳过的前提是「索引记录的远端状态仍然成立」。
/// 一旦本端开始往远端写，这个前提就在被破坏的过程中——此时若本端进程被杀，远端
/// progress 文件已经变新、而索引还停在旧值，别的设备就会拿旧值比对、判定一致、
/// 永久漏掉这次更新。
///
/// 所以本端在**动手之前**先把自己的索引改名成 `dirty`：别的设备一看见 dirty，就把
/// 索引整体判为不可用、本轮退回全量列举。中断留下的 dirty 文件不会自愈成「看起来
/// 没事」，只会让别人多跑一次全量——**索引只被允许「过度保守」，不允许「乐观出错」**。
///
/// ## 为什么 revision 只在真写了远端时才 +1
///
/// 非书籍阶段（合集 / 聚合 / 墓碑…）的远端状态没有 per-item 时间戳可比，它们的跳过
/// 判据只能是「自上次以来没有任何对端动过远端」。如果每轮同步都无条件 bump 自己的
/// revision，那么在多设备场景下，任意一台设备跑一轮同步就会让所有其它设备看到
/// 「有人动过」——这个判据永远为假，那些阶段的跳过就形同虚设。
///
/// 因此 revision 的语义严格是「本端**改动远端内容**的次数」，而不是「本端跑过几轮
/// 同步」。纯跳过的一轮不 bump，也不重传清单。
class SyncIndexService {
  SyncIndexService({
    required SyncAssetStore store,
    required SyncRepository repo,
    required String deviceId,
    required String channel,
  })  : _store = store,
        _repo = repo,
        _deviceId = deviceId,
        _channel = channel;

  final SyncAssetStore _store;
  final SyncRepository _repo;
  final String _deviceId;

  /// 本服务服务的同步通道（云备份 / 互联）。两条通道指向不同远端，观测缓存必须
  /// 分开存，见 [SyncRepository.indexCacheKeys]。
  final String _channel;

  /// 本轮解析出的、属于本端且**不是**当前有效文件的残留（旧 revision / 旧 dirty）。
  /// 发布时一并清掉，避免命名空间里堆积同一设备的历史文件。
  final List<AssetEntry> _ownStaleAssets = <AssetEntry>[];

  /// 本轮 `__index__` 的命名空间 id（plan 时解析，发布时复用，不重复 ensure）。
  String? _namespaceId;

  /// 本端当前在远端的有效文件名（发布新版本后要删掉它）。
  String? _ownCurrentName;

  /// 本轮 plan 里已经确认有效的、各设备清单的本地缓存（发布时在此基础上更新本端那份）。
  Map<String, ({int revision, String raw})> _manifestCache =
      <String, ({int revision, String raw})>{};

  /// 出计划。**绝不抛**：索引是纯优化，任何异常都退化成 [SyncIndexPlan.disabled]
  /// （本轮全量、老行为），由调用方照常同步。
  Future<SyncIndexPlan> plan({required int nowMs}) async {
    try {
      return await _plan(nowMs: nowMs);
    } catch (e) {
      debugPrint('[sync-index] plan failed, falling back to full sweep: $e');
      return SyncIndexPlan.disabled;
    }
  }

  Future<SyncIndexPlan> _plan({required int nowMs}) async {
    // deviceId 为空 = 本机还没有稳定身份（测试构造 / 未初始化）。per-device 清单
    // 无法安全命名，且没有身份就无法把「本端写的」与「别人写的」分开——降级为
    // 不使用索引，与 `_syncAggregate` 对空 deviceId 的处理同律。
    if (_deviceId.isEmpty) return SyncIndexPlan.disabled;

    final String ns = await _store.ensureNamespace(kSyncIndexNamespace);
    _namespaceId = ns;

    final List<AssetEntry> children = await _store.listChildren(ns);

    // 每台设备取 revision 最大的那一份为有效记录。同一设备出现多份是正常的中间态
    // （上传成功但删除旧文件失败），不是错误。
    final Map<String, ({AssetEntry asset, SyncIndexAssetRef ref})> latest =
        <String, ({AssetEntry asset, SyncIndexAssetRef ref})>{};
    final List<AssetEntry> superseded = <AssetEntry>[];

    for (final AssetEntry entry in children) {
      if (entry.isFolder) continue;
      final SyncIndexAssetRef? ref = parseSyncIndexAssetName(entry.name);
      if (ref == null) continue;
      final ({AssetEntry asset, SyncIndexAssetRef ref})? existing =
          latest[ref.deviceId];
      if (existing == null || ref.revision > existing.ref.revision) {
        if (existing != null) superseded.add(existing.asset);
        latest[ref.deviceId] = (asset: entry, ref: ref);
      } else {
        superseded.add(entry);
      }
    }

    _ownStaleAssets
      ..clear()
      ..addAll(superseded.where((AssetEntry a) {
        final SyncIndexAssetRef? r = parseSyncIndexAssetName(a.name);
        return r != null && r.deviceId == _deviceId;
      }));

    final ({AssetEntry asset, SyncIndexAssetRef ref})? own = latest[_deviceId];
    _ownCurrentName = own?.asset.name;
    final int ownRevision = own?.ref.revision ?? 0;

    final Map<String, ({int revision, String raw})> cache =
        await _repo.getIndexManifestCache(_channel);

    // 任何一台设备（含本端）正处于 dirty，整份索引即不可信：它随时可能改远端，而
    // 我们无从知道改了哪本。本端自己的 dirty 说明上一轮被中断在写入过程中，同样
    // 不可信。「有脏就整体退回全量」而不是「只不信任那一台」——后者要求我们能分清
    // 每本书的远端状态归谁负责，而远端 progress 文件是所有设备共写的，分不清。
    final bool anyDirty = latest.values
        .any((({AssetEntry asset, SyncIndexAssetRef ref}) v) => v.ref.dirty);

    // 距上次完整 sweep 太久 → 本轮强制全量，纠正「旧版本设备改了远端却不更新索引」
    // 造成的漂移（见 kSyncIndexFullSweepIntervalMs）。
    final int lastFullSweep = await _repo.getIndexLastFullSweepMs(_channel);
    final bool forcedFullSweep = lastFullSweep <= 0 ||
        (nowMs - lastFullSweep) >= kSyncIndexFullSweepIntervalMs;

    // 读取每台设备的清单：文件名里的 revision 与本地缓存一致就直接用缓存，否则下载。
    final Map<String, ({int revision, String raw})> freshCache =
        <String, ({int revision, String raw})>{};
    final List<SyncIndexManifest> manifests = <SyncIndexManifest>[];
    bool allReadable = true;

    for (final MapEntry<String, ({AssetEntry asset, SyncIndexAssetRef ref})> e
        in latest.entries) {
      // dirty 的那份不读：它的内容按定义就不可信，下载它纯属浪费。
      if (e.value.ref.dirty) continue;

      final ({int revision, String raw})? cached = cache[e.key];
      SyncIndexManifest? manifest;
      String? raw;

      if (cached != null && cached.revision == e.value.ref.revision) {
        raw = cached.raw;
        manifest = SyncIndexManifest.tryDecode(cached.raw);
      }
      if (manifest == null) {
        final Object? json = await _store.getJsonAsset(e.value.asset.id);
        manifest = SyncIndexManifest.tryParse(json);
        raw = manifest?.encode();
      }

      // 读不出 / 版本比本端新 / 内容与文件名自相矛盾 → 索引不可用。宁可全量。
      if (manifest == null ||
          raw == null ||
          manifest.deviceId != e.key ||
          manifest.revision != e.value.ref.revision) {
        allReadable = false;
        continue;
      }

      freshCache[e.key] = (revision: manifest.revision, raw: raw);
      manifests.add(manifest);
    }

    // 本端从未发布过索引（首次启用 / 换了远端 / 缓存被清）→ 没有基准可比，本轮
    // 全量跑一遍并在结束时发布，下一轮才开始受益。
    final bool ownPublished = own != null && !own.ref.dirty;

    // 「没有任何对端动过远端」：对端集合与上轮完全相同，且各自 revision 未变。
    // 新出现的设备、消失的设备都算「动过」——前者可能带来我们没见过的数据，后者
    // 说明有人删了东西。
    final Set<String> currentPeers =
        latest.keys.where((String d) => d != _deviceId).toSet();
    final Set<String> cachedPeers =
        cache.keys.where((String d) => d != _deviceId).toSet();
    bool remoteUnchanged = !anyDirty &&
        currentPeers.length == cachedPeers.length &&
        currentPeers.containsAll(cachedPeers);
    if (remoteUnchanged) {
      for (final String peer in currentPeers) {
        if (cache[peer]?.revision != latest[peer]!.ref.revision) {
          remoteUnchanged = false;
          break;
        }
      }
    }

    final bool usable =
        !anyDirty && allReadable && ownPublished && !forcedFullSweep;

    _manifestCache = freshCache;
    await _repo.setIndexManifestCache(_channel, freshCache);

    final Map<String, int> peerRevisions = <String, int>{
      for (final String peer in currentPeers) peer: latest[peer]!.ref.revision,
    };

    return SyncIndexPlan(
      usable: usable,
      remoteUnchanged: usable && remoteUnchanged,
      books: usable
          ? foldSyncIndexBooks(manifests)
          : const <String, SyncIndexBookEntry>{},
      ownStages:
          usable ? _stagesOf(manifests, _deviceId) : const <String, String>{},
      ownRevision: ownRevision,
      peerRevisions: peerRevisions,
      forcedFullSweep: forcedFullSweep,
    );
  }

  /// 动手改远端之前，把本端索引置为 dirty（同一 revision，只改状态）。
  ///
  /// 只有在本轮**可能**写远端时才需要调用；纯跳过的一轮不写、不留痕迹（见类文档）。
  /// 失败只记日志：拿不到租约就等于「本端这一轮不该被别人信任」，而这正是我们没能
  /// 发布 dirty 时的默认状态——本端接下来仍会照常同步，只是别人可能在这个窗口里
  /// 用旧索引跳过本端刚写的东西。为把这个窗口关死，发布失败时本端会在结束时**强制**
  /// 重发一份 clean 索引并 bump revision（见 [publish] 的 forceRepublish）。
  Future<bool> markDirty(SyncIndexPlan plan) async {
    if (_deviceId.isEmpty) return false;
    try {
      // plan 阶段失败（网络抖动）时 `_namespaceId` 还是空的，但本轮照样会继续同步
      // 并写远端——那正是最需要租约的时候，所以这里自己把命名空间解析出来，而不是
      // 因为计划没做成就放弃上锁。
      final String ns =
          _namespaceId ??= await _store.ensureNamespace(kSyncIndexNamespace);
      final SyncIndexManifest? current = _currentOwnManifest(plan);
      final String name = syncIndexAssetName(
        deviceId: _deviceId,
        revision: plan.ownRevision,
        dirty: true,
      );
      await _store.putJsonAsset(
        ns,
        name,
        (current ??
                SyncIndexManifest(
                  deviceId: _deviceId,
                  revision: plan.ownRevision,
                  publishedAt: 0,
                ))
            .toJson(),
      );
      // 先传新（dirty）再删旧（clean）：反过来一旦中间失败，命名空间里就只剩
      // 「本端没有索引」，别的设备会把它当成一台从未发布过的设备。
      await _deleteOwnAssetNamed(_ownCurrentName, ns);
      _ownCurrentName = name;
      return true;
    } catch (e) {
      debugPrint('[sync-index] markDirty failed: $e');
      return false;
    }
  }

  /// 发布本端这一轮的观测结果。
  ///
  /// [wroteRemote] = 本轮是否真的改动过远端内容。false 且没有 [forceRepublish] 时，
  /// revision 保持不变（见类文档「为什么 revision 只在真写了远端时才 +1」）。
  ///
  /// [books] / [stages] 是本轮**实际观测到**的状态。只有本轮完整跑过的部分才该写进去
  /// ——调用方对跳过的条目直接沿用上一轮的记录（那份记录仍然成立），对跑过的条目写
  /// 新观测值。
  Future<void> publish({
    required SyncIndexPlan plan,
    required Map<String, SyncIndexBookEntry> books,
    required Map<String, String> stages,
    required int nowMs,
    required bool wroteRemote,
    required bool wasFullSweep,
    bool forceRepublish = false,
  }) async {
    if (_deviceId.isEmpty) return;

    try {
      final String ns =
          _namespaceId ??= await _store.ensureNamespace(kSyncIndexNamespace);
      if (wasFullSweep) await _repo.setIndexLastFullSweepMs(_channel, nowMs);

      final bool bump = wroteRemote || forceRepublish;
      final int revision = bump ? plan.ownRevision + 1 : plan.ownRevision;

      final SyncIndexManifest manifest = SyncIndexManifest(
        deviceId: _deviceId,
        revision: revision,
        publishedAt: nowMs,
        books: books,
        stages: stages,
      );

      final String name = syncIndexAssetName(
        deviceId: _deviceId,
        revision: revision,
        dirty: false,
      );

      // 内容与文件名都没变（纯跳过的一轮，且当前远端文件已经是这个名字）→ 一次
      // 写入都不做。这正是稳态：整轮同步只花掉最开始那一次 listChildren。
      final SyncIndexManifest? current = _currentOwnManifest(plan);
      final bool unchanged = !bump &&
          _ownCurrentName == name &&
          current != null &&
          current.canonicalJson() == manifest.canonicalJson();
      if (unchanged) {
        await _pruneOwnStale(ns);
        return;
      }

      await _store.putJsonAsset(ns, name, manifest.toJson());
      if (_ownCurrentName != name) {
        await _deleteOwnAssetNamed(_ownCurrentName, ns);
      }
      _ownCurrentName = name;

      final Map<String, ({int revision, String raw})> cache =
          <String, ({int revision, String raw})>{
        ..._manifestCache,
        _deviceId: (revision: revision, raw: manifest.encode()),
      };
      await _repo.setIndexManifestCache(_channel, cache);

      await _pruneOwnStale(ns);
    } catch (e) {
      // 发布失败 = 下一轮读不到一致的本端索引 → 那一轮自动退回全量。不影响本轮
      // 已经完成的同步，也不该让整轮报错。
      debugPrint('[sync-index] publish failed: $e');
    }
  }

  static Map<String, String> _stagesOf(
    List<SyncIndexManifest> manifests,
    String deviceId,
  ) {
    for (final SyncIndexManifest m in manifests) {
      if (m.deviceId == deviceId) return m.stages;
    }
    return const <String, String>{};
  }

  SyncIndexManifest? _currentOwnManifest(SyncIndexPlan plan) {
    final ({int revision, String raw})? cached = _manifestCache[_deviceId];
    if (cached == null) return null;
    final SyncIndexManifest? m = SyncIndexManifest.tryDecode(cached.raw);
    if (m == null || m.revision != plan.ownRevision) return null;
    return m;
  }

  Future<void> _deleteOwnAssetNamed(String? name, String ns) async {
    if (name == null) return;
    try {
      final AssetEntry? asset = await _store.findAsset(ns, name);
      if (asset != null) await _store.deleteAsset(asset.id);
    } catch (e) {
      debugPrint('[sync-index] delete stale index "$name" failed: $e');
    }
  }

  /// 清掉本端名下的历史残留文件。纯卫生工作，失败无害（下轮再试）。
  Future<void> _pruneOwnStale(String ns) async {
    if (_ownStaleAssets.isEmpty) return;
    final List<AssetEntry> stale = List<AssetEntry>.from(_ownStaleAssets);
    _ownStaleAssets.clear();
    for (final AssetEntry asset in stale) {
      if (asset.name == _ownCurrentName) continue;
      try {
        await _store.deleteAsset(asset.id);
      } catch (e) {
        debugPrint('[sync-index] prune "${asset.name}" failed: $e');
      }
    }
  }
}
