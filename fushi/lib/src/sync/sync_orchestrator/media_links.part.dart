part of '../sync_orchestrator.dart';

/// 作品图谱（media_links）互联 live 通道：跨模块作品连接（手动连接、推断建议、
/// 否决墓碑）跨设备保持一致（`media_link_sync.dart`）。
extension _SyncOrchestratorMediaLinks on SyncOrchestrator {
  /// 作品图谱双向同步：GET host 清单 → [applyMediaLinkManifest] 按整行 LWW 并入
  /// 本地 → 本机清单未被 host 覆盖（[mediaLinkManifestCovers]）才 POST。
  ///
  /// 整行 LWW 与应用顺序无关、重放幂等，中途失败下轮原样重来。老 host 无端点
  /// （GET 404 → null）只跳过这一维度：作品图谱是新功能，老 host 上本来就没有
  /// 任何连接，不像标签那样「用户看见没同步」需要线索，计入 report.errors 只会让
  /// 每轮同步报一条无从处理的错。
  Future<void> _syncMediaLinksLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    try {
      final MediaLinkManifest? remote = await backend
          .getRemoteMediaLinkManifest();
      if (remote == null) return;
      late final MediaLinkManifest local;
      // 与本机作为 host 处理对端 POST 的 mergeMediaLinkManifest 持同一把窄锁。
      await runExclusiveWithSyncStateApply(() async {
        report.mediaLinksUpdated += await applyMediaLinkManifest(_db, remote);
        local = await loadLocalMediaLinkManifest(_db);
      });
      if (!mediaLinkManifestCovers(remote, local)) {
        await backend.putRemoteMediaLinkManifest(local);
      }
    } catch (e) {
      report.noteError('media links live sync', e);
    }
  }

  /// 作品图谱云通道：与合集清单同一命名空间（`__collections__`，已是保留目录，不会
  /// 被当成书列出），per-device 各写各的 `media-links-<deviceId>.json`、读时把全部
  /// 设备的文件逐份并入。
  ///
  /// 与合集不同，这里**不需要基线**：整行 LWW 与应用顺序无关、重放幂等，旧设备
  /// 留下的陈旧文件只会因 updatedAt 更旧而输掉，不会复活任何东西。per-device 文件
  /// 而不是单文件，是为了两台设备并发写时后写者不覆盖先写者（合集清单踩过的坑）。
  /// 他端文件读不出：跳过并记一条错误，下一轮再读；本端文件读不出：用本机重写。
  Future<void> _syncMediaLinksCloud(SyncRunReport report) async {
    try {
      final String ns = await _backend.ensureNamespace(
        kSyncCollectionsNamespace,
      );
      final String ownName = mediaLinksManifestNameFor(deviceId);
      final List<MediaLinkManifest> peers = <MediaLinkManifest>[];
      String? ownCanonical;
      bool ownExists = false;
      for (final AssetEntry e in await _backend.listChildren(ns)) {
        if (e.isFolder || !isMediaLinksManifestName(e.name)) continue;
        final bool isOwn = e.name == ownName;
        try {
          final Object? json = await _backend.getJsonAsset(e.id);
          if (json == null) {
            throw const FormatException('unreadable (null decode)');
          }
          final MediaLinkManifest m = MediaLinkManifest.fromJson(json);
          peers.add(m);
          if (isOwn) {
            ownExists = true;
            ownCanonical = m.canonicalJson();
          }
        } catch (err) {
          report.noteError(
            isOwn
                ? 'own media links manifest "${e.name}" unreadable; '
                      'republishing from local'
                : 'peer media links manifest "${e.name}" unreadable; skipped',
            err,
          );
        }
      }
      late final MediaLinkManifest local;
      await runExclusiveWithSyncStateApply(() async {
        for (final MediaLinkManifest m in peers) {
          report.mediaLinksUpdated += await applyMediaLinkManifest(_db, m);
        }
        local = await loadLocalMediaLinkManifest(_db);
      });
      // 没有任何连接且本端从没发布过：不无中生有地建空文件。
      if (!ownExists && local.links.isEmpty) return;
      if (local.canonicalJson() != ownCanonical) {
        await _backend.putJsonAsset(ns, ownName, local.toJson());
      }
    } catch (e) {
      report.noteError('media links cloud sync', e);
    }
  }
}

/// 本端 per-device 作品图谱清单资产名（与合集清单同一命名空间）。[deviceId] 为空
/// （未配置 / 测试）时退回单文件名。
String mediaLinksManifestNameFor(String deviceId) =>
    deviceId.isEmpty ? 'media-links.json' : 'media-links-$deviceId.json';

/// 是否是一份作品图谱清单资产。与 [isCollectionsManifestName] 互斥（前缀不同），
/// 合集清单的折叠不会误读它。
bool isMediaLinksManifestName(String name) =>
    name == 'media-links.json' ||
    (name.startsWith('media-links-') && name.endsWith('.json'));
