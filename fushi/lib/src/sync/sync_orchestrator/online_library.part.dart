part of '../sync_orchestrator.dart';

/// 在线源条目跨设备同步（拍板台 mY5VWg1nD-，`online_library_items.dart`）：从在线源
/// 加进库的漫画 / 小说 / 视频 / 音乐条目在各设备之间对齐（只传条目，不传内容）。
extension _SyncOrchestratorOnlineLibrary on SyncOrchestrator {
  /// 互联：GET host 上的各设备清单（含 host 自己的）→ 并进本机 → 本机清单与 host
  /// 存着的那份不同才 PUT。老 host 无端点（404）记一条「对端版本过旧」后跳过。
  Future<void> _syncOnlineLibraryLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    if (deviceId.isEmpty) return;
    try {
      final List<OnlineLibraryManifest>? remote = await backend
          .getRemoteOnlineLibraryManifests();
      if (remote == null) {
        await _notePeerGapLive(
          report,
          backend,
          SyncPeerGapDimension.onlineLibrary,
        );
        return;
      }
      String? ownCanonical;
      for (final OnlineLibraryManifest m in remote) {
        if (m.deviceId == deviceId) ownCanonical = m.canonicalJson();
      }
      final OnlineLibraryManifest local = await _applyOnlineLibrary(
        report,
        remote,
      );
      if (ownCanonical == null && local.items.isEmpty) return;
      if (local.canonicalJson() != ownCanonical) {
        await backend.putRemoteOnlineLibraryManifest(local);
      }
    } catch (e) {
      _noteDimensionError(report, 'online library live sync', e);
    }
  }

  /// 云通道：与合集同一命名空间（`__collections__`），每台设备各写各的
  /// `online-library-<deviceId>.json`，读时把别的设备的逐份并入本机。他端文件读
  /// 不出：跳过并记一条错误，下一轮再读；本端文件读不出：用本机重写。
  Future<void> _syncOnlineLibraryCloud(SyncRunReport report) async {
    if (deviceId.isEmpty) return;
    try {
      final String ns = await _backend.ensureNamespace(
        kSyncCollectionsNamespace,
      );
      final String ownName = onlineLibraryManifestNameFor(deviceId);
      final List<AssetEntry> manifests = <AssetEntry>[
        for (final AssetEntry e in await _backend.listChildren(ns))
          if (!e.isFolder && isOnlineLibraryManifestName(e.name)) e,
      ];
      await _retainManifestMirror(
        SyncOrchestrator._kOnlineLibraryMirror,
        manifests,
      );
      final List<OnlineLibraryManifest> peers = <OnlineLibraryManifest>[];
      String? ownCanonical;
      for (final AssetEntry e in manifests) {
        _checkpoint();
        final bool isOwn = e.name == ownName;
        try {
          final Object? json = await _readManifestJson(
            SyncOrchestrator._kOnlineLibraryMirror,
            e,
          );
          if (json == null) {
            throw const FormatException('unreadable (null decode)');
          }
          final OnlineLibraryManifest m = OnlineLibraryManifest.fromJson(json);
          if (isOwn) {
            ownCanonical = m.canonicalJson();
          } else {
            peers.add(m);
          }
        } catch (err) {
          _noteDimensionError(
            report,
            isOwn
                ? 'own online library manifest "${e.name}" unreadable; '
                      'republishing from local'
                : 'peer online library manifest "${e.name}" unreadable; '
                      'skipped',
            err,
          );
        }
      }
      final OnlineLibraryManifest local = await _applyOnlineLibrary(
        report,
        peers,
      );
      // 没有任何在线条目且本端从没发布过：不无中生有地建空文件。
      if (ownCanonical == null && local.items.isEmpty) return;
      if (local.canonicalJson() != ownCanonical) {
        await _backend.putJsonAsset(ns, ownName, local.toJson());
      }
    } catch (e) {
      _noteDimensionError(report, 'online library cloud sync', e);
    }
  }

  /// 并入 [manifests] 并读回本机清单（与本机作为 host 收 PUT 时同一把同步状态锁）；
  /// 要联网的收尾（封面）放锁外跑。
  Future<OnlineLibraryManifest> _applyOnlineLibrary(
    SyncRunReport report,
    List<OnlineLibraryManifest> manifests,
  ) async {
    late final OnlineLibraryApplyResult result;
    late final OnlineLibraryManifest local;
    await runExclusiveWithSyncStateApply(() async {
      result = await OnlineLibraryApplier(
        _db,
      ).apply(manifests, ownDeviceId: deviceId);
      local = await buildLocalOnlineLibraryManifest(_db, deviceId: deviceId);
    });
    report.onlineLibraryItemsApplied += result.changed;
    for (final String error in result.errors) {
      report.errors.add('online library item $error');
    }
    await runOnlineLibraryFollowUps(result.followUps);
    return local;
  }
}

/// 本端 per-device 在线源条目清单资产名（与合集清单同一命名空间）。
String onlineLibraryManifestNameFor(String deviceId) =>
    'online-library-$deviceId.json';

/// 是否是一份在线源条目清单资产。与合集 / 作品图谱清单前缀不同，互不误读。
bool isOnlineLibraryManifestName(String name) =>
    name.startsWith('online-library-') && name.endsWith('.json');
