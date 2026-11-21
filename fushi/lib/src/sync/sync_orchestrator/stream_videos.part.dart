part of '../sync_orchestrator.dart';

/// 流媒体书（「粘贴 URL 导入」/ 网页视频站）互联 live 行对齐（拍板台 Z2OhxAjKVv：
/// Mac 与 Android 的 YouTube 观看进度不同步）。
///
/// 视频进度 / 播放偏好 sweep 只对两端都有的 uid 生效；本地视频靠文件阶段上传成为
/// host 的行，流媒体书没有字节可传，此前永远只在本机，两端各看各的。这里只对齐
/// **行**（标题 + URL + 重开规格，`stream_video_sync.dart`），不传字节：
///
/// - 推：本机有、host 没有的流媒体书注册给 host（先看能力位，过 host 删除墓碑）；
/// - 拉：host 有、本机没有、且 host 拥有时刻晚于本机拉取基线的落到本机——早于
///   基线、本机却没有的，是本机删掉的（「仅本机删除」不写墓碑），不建回来；本机
///   「从所有设备删除」留下的墓碑同样挡住删除之前就有的那条。
///
/// 两边都有之后 [_syncVideoProgressLive] 原样接管进度、播放偏好与看完标记。
extension _SyncOrchestratorStreamVideos on SyncOrchestrator {
  /// 对齐流媒体书的行，返回之后进度阶段该用的 host 清单：推过东西就重取（刚注册的
  /// 行这一轮就要对上进度），否则原样返回 [hostList]。
  ///
  /// 整段错误进 [report] 不中断 sweep；失败时返回 [hostList]，进度照旧按它同步。
  Future<List<RemoteVideoInfo>> _reconcileStreamVideosLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
    List<RemoteVideoInfo> hostList,
  ) async {
    final Set<String> hostUids = <String>{
      for (final RemoteVideoInfo info in hostList) info.id,
    };
    final List<VideoBookRow> localRows = await _db.allVideoBooks();
    final Set<String> localUids = <String>{
      for (final VideoBookRow r in localRows) r.bookUid,
    };

    bool pushed = false;
    try {
      pushed = await _pushStreamVideosLive(
        report,
        backend,
        <VideoBookRow>[
          for (final VideoBookRow r in localRows)
            if (!hostUids.contains(r.bookUid) &&
                isSyncableStreamVideo(
                  bookUid: r.bookUid,
                  videoPath: r.videoPath,
                ))
              r,
        ]..sort(
          (VideoBookRow a, VideoBookRow b) => a.bookUid.compareTo(b.bookUid),
        ),
      );
    } on SyncCancelledException {
      rethrow;
    } catch (e) {
      report.noteError('live push stream videos', e);
    }

    try {
      await _pullStreamVideosLive(report, hostList, localUids);
    } on SyncCancelledException {
      rethrow;
    } catch (e) {
      report.noteError('live pull stream videos', e);
    }

    if (!pushed) return hostList;
    return backend.listRemoteVideos();
  }

  /// 把 [rows]（本机有、host 没有的流媒体书）注册给 host。返回是否改变了 host 清单。
  Future<bool> _pushStreamVideosLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
    List<VideoBookRow> rows,
  ) async {
    if (rows.isEmpty) return false;
    // 老 host 没有注册端点：带后缀的 PUT 会被它当成视频文件上传，所以先问能力位，
    // 不支持就整段不推（不报错——升级 host 之前这一维度本来就不存在）。
    if (!await backend.hostAcceptsStreamVideos()) return false;
    final DeletionTombstoneEntries? hostTombstones =
        await _loadHostPushVetoTombstones(
          report,
          backend,
          'live push stream videos',
        );
    if (hostTombstones == null) return false;
    bool changed = false;
    for (final VideoBookRow row in rows) {
      _checkpoint();
      if (_hostVetoesPush(
        hostTombstones,
        kinds: const <SyncTombstoneKind>[SyncTombstoneKind.video],
        itemKeys: <String>[row.bookUid],
        presentSinceAt: row.localAddedAt,
      )) {
        continue;
      }
      try {
        final StreamVideoPushResult result = await backend.putRemoteStreamVideo(
          row.bookUid,
          StreamVideoRegistration(
            title: row.title,
            url: row.videoPath.trim(),
            streamSpecJson: row.streamSpecJson,
            importedAt: row.importedAt,
          ),
          presentSinceAt: row.localAddedAt,
        );
        switch (result) {
          case StreamVideoPushResult.created:
            report.streamVideosPushed++;
            changed = true;
          case StreamVideoPushResult.existed:
            // 清单之后 host 才有了这一行（别的设备刚推过）：清单同样过时了。
            changed = true;
          case StreamVideoPushResult.vetoed:
            break;
        }
      } catch (e) {
        report.noteError('live push stream video "${row.title}"', e);
      }
    }
    return changed;
  }

  /// 把 host 新有、本机没有的流媒体书落到本机（见扩展注释的基线语义）。
  Future<void> _pullStreamVideosLive(
    SyncRunReport report,
    List<RemoteVideoInfo> hostList,
    Set<String> localUids,
  ) async {
    final SyncRepository repo = SyncRepository(_db);
    final int since = await repo.getStreamVideoPullSinceMs(_scope);
    Map<String, int>? localTombstones;
    int newest = since;
    bool incomplete = false;
    final List<({String uid, String url})> created =
        <({String uid, String url})>[];
    for (final RemoteVideoInfo info in hostList) {
      final RemoteStreamVideoEntry? stream = info.stream;
      if (stream == null ||
          !isSyncableStreamVideo(bookUid: info.id, videoPath: stream.url)) {
        continue;
      }
      final int addedAt = stream.addedAt ?? 0;
      if (addedAt > newest) newest = addedAt;
      if (localUids.contains(info.id)) continue;
      // 基线之前就在 host 上、本机却没有：本机删过（仅本机删除不写墓碑），不建回。
      if (since > 0 && addedAt <= since) continue;
      // 本机「从所有设备删除」过、墓碑还没送达 host：删除之前就有的那条不建回。
      localTombstones ??= await _db.getSyncDeletionDeletedAtByKey(
        SyncTombstoneKind.video.dbValue,
      );
      final int? deletedAt = localTombstones[info.id];
      if (deletedAt != null && deletedAt >= addedAt) continue;
      try {
        await _db.upsertVideoBook(
          streamVideoRowCompanion(
            bookUid: info.id,
            title: info.title,
            url: stream.url,
            streamSpecJson: stream.streamSpecJson,
            importedAt: info.importedAt,
            nowMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        report.streamVideosPulled++;
        created.add((uid: info.id, url: stream.url));
      } catch (e) {
        incomplete = true;
        report.noteError('live pull stream video "${info.title}"', e);
      }
    }
    // 有条目没落成就不推进基线，否则它们再也拉不到。
    if (!incomplete && newest > since) {
      await repo.setStreamVideoPullSinceMs(_scope, newest);
    }
    if (created.isEmpty) return;
    // 封面尽力而为（YouTube 缩略图），失败只是占位，不进报告。
    try {
      final Directory coversDir = await VideoStorage.coversDir();
      for (final ({String uid, String url}) c in created) {
        try {
          await backfillStreamVideoThumbnailCover(
            _db,
            bookUid: c.uid,
            url: c.url,
            coversDir: coversDir,
          );
        } catch (e) {
          debugPrint('[SyncOrchestrator] stream video cover "${c.uid}": $e');
        }
      }
    } catch (e) {
      debugPrint('[SyncOrchestrator] stream video covers skipped: $e');
    }
  }
}
