part of '../sync_orchestrator.dart';

/// 云通道书阶段的书级变更筛选（拍板 wiO0nN8aiG / issue #4332）：开轮准备
/// [BookChangeGate]，书阶段之后发布本机书级清单、记全扫账。设计与安全论证见
/// docs/specs/2026-11-24-sync-book-change-manifest.md。
extension _SyncOrchestratorBookChange on SyncOrchestrator {
  /// 准备本轮的筛选器；不该筛（没有设备 id / 认不出远端）或准备失败时返回 null，
  /// 书阶段照旧逐本全扫。
  Future<BookChangeGate?> _prepareBookChangeGate(
    SyncRunReport report,
    RemoteListingSnapshot? listing,
  ) async {
    if (deviceId.isEmpty) return null;
    final String storageDimension;
    try {
      storageDimension = (await progressBaselineStorageFor(
        _db,
        _backend,
      )).storageDimension;
    } on SyncRemoteIdentityUnavailableError {
      // 书阶段自己会把这条错误整段报一次（SyncBooksIncompleteError），这里只是不筛。
      return null;
    }
    final Map<String, int> fingerprints = await _db
        .getSyncBaselinesForDimension(
          BookChangeGate.fingerprintDimensionFor(storageDimension),
        );
    const Set<String> audioNames = <String>{
      kSyncAudiobookAssetName,
      kLegacySyncAudiobookAssetName,
    };

    if (listing != null) {
      // 快照模式：书文件夹的实际文件名就是远端实情，不读清单。本机清单只看在不在
      // （不在就收尾时强制发布，供快照失败落到 manifest 模式的那一轮用）。
      final String ownName = bookManifestNameFor(deviceId);
      final bool ownPresent = listing
          .entriesOf(kSyncBookManifestNamespace)
          .any((AssetEntry e) => !e.isFolder && e.name == ownName);
      report.bookChangeMode = 'snapshot';
      return BookChangeGate(
        mode: BookChangeGateMode.snapshot,
        storageDimension: storageDimension,
        fingerprints: fingerprints,
        audioPackageNames: audioNames,
        listing: listing,
        ownManifestStale: !ownPresent,
      );
    }

    final BookChangeState state = await BookChangeState.load(
      _db,
      storageDimension,
    );
    final List<String> reasons = <String>[];
    final List<BookChangeManifest> peers = <BookChangeManifest>[];
    final Map<String, String> legacyTokens = <String, String>{};
    bool ownStale = false;
    try {
      final String ns = await _backend.ensureNamespace(
        kSyncBookManifestNamespace,
      );
      final List<AssetEntry> manifests = <AssetEntry>[
        for (final AssetEntry e in await _backend.listChildren(ns))
          if (!e.isFolder && bookManifestDeviceOf(e.name) != null) e,
      ];
      await _retainManifestMirror(
        SyncOrchestrator._kBookManifestMirror,
        manifests,
      );
      String? ownHash;
      for (final AssetEntry e in manifests) {
        final String device = bookManifestDeviceOf(e.name)!;
        try {
          final Object? json = await _readManifestJson(
            SyncOrchestrator._kBookManifestMirror,
            e,
          );
          final BookChangeManifest m = BookChangeManifest.fromJson(json);
          if (device == deviceId) {
            ownHash = m.contentHash();
          } else {
            peers.add(m);
          }
        } catch (err) {
          _rethrowIfAbortsRound(err);
          if (device == deviceId) {
            // 本机那份坏了：收尾时强制重发即可自愈，本轮全扫。
            ownStale = true;
          } else {
            _noteDimensionError(
              report,
              'peer book manifest "${e.name}" unreadable; full sweep this run',
              err,
            );
          }
          reasons.add('unreadable manifest ${e.name}');
        }
      }
      if (ownHash == null || ownHash != state.publishedHash) {
        ownStale = true;
        reasons.add('own manifest absent or differs');
      }

      // 旧版客户端：有聚合快照、没有书级清单的设备（只写书文件不写清单）。它的快照
      // 版本标记与上次全扫时不同 = 它这段时间在活动，本轮全扫。
      final Set<String> manifestDevices = <String>{
        deviceId,
        for (final BookChangeManifest m in peers) m.deviceId,
      };
      final String aggregateNs = await _backend.ensureNamespace(
        kSyncAggregateNamespace,
      );
      for (final AssetEntry e in await _backend.listChildren(aggregateNs)) {
        if (e.isFolder) continue;
        final String? device = aggregateSnapshotDeviceOf(e.name);
        if (device == null || manifestDevices.contains(device)) continue;
        final int? modifiedAt = e.modifiedAt;
        final String? token =
            e.revision ??
            (modifiedAt == null ? null : 'm$modifiedAt:${e.sizeBytes}');
        if (token == null) {
          reasons.add('legacy writer $device (no version token)');
          continue;
        }
        legacyTokens[device] = token;
        if (state.legacyTokens[device] != token) {
          reasons.add('legacy writer $device active');
        }
      }
    } catch (e) {
      _noteDimensionError(report, 'book manifests', e);
      reasons.add('manifest read failed');
    }

    final int now = DateTime.now().millisecondsSinceEpoch;
    final int sinceFull = now - state.lastFullSweepMs;
    if (sinceFull < 0 ||
        sinceFull > kBookChangeFullSweepInterval.inMilliseconds) {
      reasons.add('periodic full sweep');
    }

    final String? fullSweepReason = reasons.isEmpty ? null : reasons.join('; ');
    report.bookChangeMode = fullSweepReason == null
        ? 'manifest'
        : 'manifest(full: $fullSweepReason)';
    return BookChangeGate(
      mode: BookChangeGateMode.manifest,
      storageDimension: storageDimension,
      fingerprints: fingerprints,
      audioPackageNames: audioNames,
      peerDigests: <String, String>{
        for (final String key in <String>{
          for (final BookChangeManifest m in peers) ...m.books.keys,
        })
          key: BookChangeGate.peerDigestOf(peers, key),
      },
      fullSweepReason: fullSweepReason,
      legacyTokens: legacyTokens,
      ownManifestStale: ownStale,
    );
  }

  /// 书阶段之后：记账（manifest 模式完整全扫跑完才推进全扫时刻与旧客户端标记）并
  /// 发布本机书级清单。发布失败只记错误，下一次发布按内容哈希自动重发。
  Future<void> _finishBookChangeGate(
    SyncRunReport report,
    BookChangeGate gate, {
    required bool bookStageComplete,
    required int bookStageStartMs,
  }) async {
    report
      ..booksChecked = gate.checked
      ..booksUnchanged = gate.skipped;
    if (gate.mode == BookChangeGateMode.manifest &&
        gate.fullSweepReason != null &&
        bookStageComplete) {
      final BookChangeState state = await BookChangeState.load(
        _db,
        gate.storageDimension,
      );
      state
        ..lastFullSweepMs = bookStageStartMs
        ..legacyTokens = Map<String, String>.of(gate.legacyTokens);
      await state.save(_db, gate.storageDimension);
    }
    try {
      await publishOwnBookManifest(
        db: _db,
        backend: _backend,
        deviceId: deviceId,
        storageDimension: gate.storageDimension,
        force: gate.ownManifestStale,
      );
    } catch (e) {
      _noteDimensionError(report, 'publish book manifest', e);
    }
  }
}
