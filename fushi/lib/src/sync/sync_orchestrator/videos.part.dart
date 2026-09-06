part of '../sync_orchestrator.dart';

/// 视频域互联 live 进度 / 上传 / 字幕同步的私有实现（B2 按域拆出）。
/// 公开入口 [SyncOrchestrator.syncVideoAssets] 留在本体；方法逐字搬自 SyncOrchestrator。
extension _SyncOrchestratorVideos on SyncOrchestrator {
  /// 一条 `VideoBooks` 行是否是可作为单文件上传的**本地**视频（[syncVideoAssets] 用）。
  ///
  /// 排除：流媒体（`streamSpecJson` 非空 / `videoPath` 为 http(s) URL）——无本地字节
  /// 可传；多集播放列表（`playlistJson` 非空）——单文件资产模型装不下多集（多集上传
  /// 是后续批的接缝，见 §2.6 seam）。
  bool _isUploadableLocalVideo(VideoBookRow v) {
    if (v.streamSpecJson != null) return false;
    if (v.playlistJson != null) return false;
    final String path = v.videoPath;
    if (path.isEmpty) return false;
    final String lower = path.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return false;
    }
    return true;
  }

  /// 互联视频播放进度 live 双向同步（TODO-767 + TODO-816）。
  ///
  /// 此前只遍历本地 `VideoBooks`，对每条比对 host 进度。但 client 流式看的远端视频
  /// 在本地**没有 VideoBooks 行**（[home_video_page._openRemote] 只 push 不 upsert，
  /// 进度只落 `video_remote_position_<uid>` prefs，见 video_fushi_page._persistRemotePosition）
  /// → 旧 sweep 永远扫不到，流式视频进度无法纳入全量双向同步（TODO-816 子问题1 断点①）。
  ///
  /// 修复：同步基底统一为 uid 集合 = 「本地 VideoBooks 行 uid」∪「本地有
  /// `video_remote_position_<uid>` prefs 的 uid（哪怕无行）」，只对 host 也有的 uid 同步。
  ///
  /// 本地进度真相：书架视频与流式视频共用一个 `_at_` prefs 时间戳。书架视频的位置
  /// 在 `VideoBooks.lastPositionMs`（本机播放写），流式视频的位置在
  /// `video_remote_position_<uid>` prefs（resume 路径写）——同一进度的两处镜像，不会
  /// 同时各有不同含义。本地位置取「有行用 lastPositionMs，否则用 prefs 位置」，时间戳
  /// 统一取 `_at_` prefs（无则 0=旧数据，被任何带时间戳的远端进度盖过）。
  ///
  /// 写回时位置真相统一落 `video_remote_position_<uid>` + `_at_` prefs（resume 路径
  /// 同键空间）；**仅当本地存在 VideoBooks 行时**才一并更新 `lastPositionMs`
  /// （流式视频绝不强建行污染书架）。
  ///
  /// LWW 比对与逐条错误处理见共享模板 [_syncPositionsLive]。
  Future<void> _syncVideoProgressLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    // 基底①：本地 VideoBooks 行（uid → lastPositionMs，向后兼容书架视频）。
    final Map<String, int> rowPositionByUid = <String, int>{};
    for (final VideoBookRow video in await _db.allVideoBooks()) {
      rowPositionByUid[video.bookUid] = video.lastPositionMs;
    }
    // 基底②：本地看过的流式视频（有 video_remote_position_<uid> prefs 但无行）。
    final Set<String> localUids = <String>{...rowPositionByUid.keys};
    final Map<String, String> allPrefs = await _db.getAllPrefs();
    for (final String key in allPrefs.keys) {
      final String? uid = videoUidFromRemotePositionPrefKey(key);
      if (uid != null) localUids.add(uid);
    }
    if (localUids.isEmpty) return;

    // 视频进度是 host-truth 模型：进度端点只对 host DB 里真实存在的视频可用。先取
    // host 视频清单（条目已带 positionMs / positionUpdatedAtMs，省去逐视频 GET），
    // 只对两端都有的视频同步；本地独有视频（host 无）无 host 真相可同步，跳过。
    final Map<String, RemoteVideoInfo> hostById = <String, RemoteVideoInfo>{};
    for (final RemoteVideoInfo info in await backend.listRemoteVideos()) {
      hostById[info.id] = info;
    }
    if (hostById.isEmpty) return;

    await _syncPositionsLive(
      report,
      errorLabel: 'live video progress',
      localKeys: localUids,
      hostKeys: hostById.keys.toSet(),
      readLocal: (String uid) async {
        final int prefsPos =
            await _db.getPrefTyped<int>(videoRemotePositionPrefKey(uid), 0);
        final int prefsAt =
            await _db.getPrefTyped<int>(videoRemotePositionAtPrefKey(uid), 0);
        return (
          positionMs: rowPositionByUid[uid] ?? prefsPos,
          updatedAtMs: prefsAt,
        );
      },
      // host 清单条目已带 positionMs / positionUpdatedAtMs，无需逐视频 GET。
      readHost: (String uid) async {
        final RemoteVideoInfo info = hostById[uid]!;
        return (
          positionMs: info.positionMs,
          updatedAtMs: info.positionUpdatedAtMs,
        );
      },
      pushToHost: (String uid, int positionMs, int updatedAtMs) =>
          backend.putRemoteVideoPosition(uid, positionMs, updatedAtMs),
      writeBackLocal: (String uid, int positionMs, int updatedAtMs) async {
        await _db.setPrefTyped<int>(
            videoRemotePositionPrefKey(uid), positionMs);
        await _db.setPrefTyped<int>(
            videoRemotePositionAtPrefKey(uid), updatedAtMs);
        if (rowPositionByUid.containsKey(uid)) {
          // 时刻用**对端的** updatedAtMs（不是 now）：这是「对方在那个时刻看到这
          // 里」的事实。传 now 会把三天前的远端进度冒充成本机刚看的，直接把合集
          // 续播锚点（BUG-1542）钉在一集用户根本没在看的集上。
          await _db.updateVideoBookPosition(uid, positionMs,
              playedAt: updatedAtMs);
        }
      },
    );

    // 播放偏好双向收敛（BUG-1620 调轴起步，播放偏好同步泛化批扩展为全字段：
    // 调轴/音轨/副字幕源/副字幕调轴）。与进度共用同一 uid 基底 + host 清单带戳
    // 字段（零额外网络读）；逐字段「严格较新时间戳者胜」。本地较新字段聚合成一次
    // putRemoteVideoPlayback（旧 host 无端点 404 → 静默吞，不刷 report 噪音）；
    // host 较新字段写回本地键对（时间戳用对端的，同进度写回纪律）+ 本地有
    // VideoBooks 行时写穿行值，本机播放立即跟随。
    String? nullableStr(String raw) => raw.isEmpty ? null : raw;
    for (final String uid in localUids) {
      final RemoteVideoInfo? info = hostById[uid];
      if (info == null) continue;
      try {
        final VideoPlaybackSyncState host = info.playback;
        final VideoPlaybackSyncState local = VideoPlaybackSyncState(
          delayMs: await _db.getPrefTyped<int>(videoRemoteDelayPrefKey(uid), 0),
          delayAt:
              await _db.getPrefTyped<int>(videoRemoteDelayAtPrefKey(uid), 0),
          audioTrackId: nullableStr(await _db.getPrefTyped<String>(
              videoRemoteAudioTrackPrefKey(uid), '')),
          audioTrackAt: await _db.getPrefTyped<int>(
              videoRemoteAudioTrackAtPrefKey(uid), 0),
          secondarySubtitleSource: nullableStr(await _db.getPrefTyped<String>(
              videoRemoteSecondarySubtitlePrefKey(uid), '')),
          secondarySubtitleAt: await _db.getPrefTyped<int>(
              videoRemoteSecondarySubtitleAtPrefKey(uid), 0),
          secondaryDelayMs: int.tryParse(await _db.getPrefTyped<String>(
              videoRemoteSecondaryDelayPrefKey(uid), '')),
          secondaryDelayAt: await _db.getPrefTyped<int>(
              videoRemoteSecondaryDelayAtPrefKey(uid), 0),
        );

        // 本地→host：只带本地严格较新的字段（at 置 0 的字段 host 端 merge 忽略）。
        final VideoPlaybackSyncState push = VideoPlaybackSyncState(
          delayMs: local.delayMs,
          delayAt: local.delayAt > host.delayAt ? local.delayAt : 0,
          audioTrackId: local.audioTrackId,
          audioTrackAt:
              local.audioTrackAt > host.audioTrackAt ? local.audioTrackAt : 0,
          secondarySubtitleSource: local.secondarySubtitleSource,
          secondarySubtitleAt:
              local.secondarySubtitleAt > host.secondarySubtitleAt
                  ? local.secondarySubtitleAt
                  : 0,
          secondaryDelayMs: local.secondaryDelayMs,
          secondaryDelayAt: local.secondaryDelayAt > host.secondaryDelayAt
              ? local.secondaryDelayAt
              : 0,
        );
        if (!push.isEmpty) {
          try {
            await backend.putRemoteVideoPlayback(uid, push);
          } catch (e) {
            debugPrint(
                '[SyncOrchestrator] video playback push "$uid" failed: $e');
          }
        }

        // host→本地：逐字段写回严格较新者。
        final bool hasRow = rowPositionByUid.containsKey(uid);
        final VideoPlaybackSyncState merged =
            VideoPlaybackSyncState.merge(local, host);
        if (merged.delayAt != local.delayAt) {
          await _db.setPrefTyped<int>(
              videoRemoteDelayPrefKey(uid), merged.delayMs);
          await _db.setPrefTyped<int>(
              videoRemoteDelayAtPrefKey(uid), merged.delayAt);
          if (hasRow) await _db.updateVideoBookDelayMs(uid, merged.delayMs);
        }
        if (merged.audioTrackAt != local.audioTrackAt) {
          await _db.setPrefTyped<String>(
              videoRemoteAudioTrackPrefKey(uid), merged.audioTrackId ?? '');
          await _db.setPrefTyped<int>(
              videoRemoteAudioTrackAtPrefKey(uid), merged.audioTrackAt);
          if (hasRow) {
            await _db.updateVideoBookAudioTrackId(uid, merged.audioTrackId);
          }
        }
        if (merged.secondarySubtitleAt != local.secondarySubtitleAt) {
          await _db.setPrefTyped<String>(
              videoRemoteSecondarySubtitlePrefKey(uid),
              merged.secondarySubtitleSource ?? '');
          await _db.setPrefTyped<int>(
              videoRemoteSecondarySubtitleAtPrefKey(uid),
              merged.secondarySubtitleAt);
          if (hasRow) {
            await _db.updateVideoBookSecondarySubtitleSource(
                uid, merged.secondarySubtitleSource);
          }
        }
        if (merged.secondaryDelayAt != local.secondaryDelayAt) {
          await _db.setPrefTyped<String>(videoRemoteSecondaryDelayPrefKey(uid),
              merged.secondaryDelayMs?.toString() ?? '');
          await _db.setPrefTyped<int>(
              videoRemoteSecondaryDelayAtPrefKey(uid), merged.secondaryDelayAt);
          if (hasRow) {
            await _db.updateVideoBookSecondaryDelayMs(
                uid, merged.secondaryDelayMs);
          }
        }
      } catch (e) {
        report.noteError('live video playback "$uid"', e);
      }
    }
  }

  /// 互联视频文件 live push（client→host，TODO §2.6「后续批」接线）。
  ///
  /// 直打对端 host 上传端点：枚举本地可上传单文件视频（[_isUploadableLocalVideo]，
  /// 排除流媒体 / 多集播放列表），对 host 尚无（按 bookUid）或尺寸不同的推上去。视频
  /// 身份键是 `VideoBooks.bookUid`（= host 端 [RemoteVideoInfo.id]，两端同源派生），故
  /// 直接按 uid union，重复上传同一视频 host 端 upsert 覆盖同一行、不产生重复。
  ///
  /// **upload-only**：host→client 方向仍是按需流式播放 / 手动下载（视频 GB 级不进
  /// 自动 pull），与云后端 [syncVideoAssets] 同律。互联 host 上传字节未混淆（与
  /// [putRemoteAudiobook] 同为裸 octet-stream），故 host 清单 [RemoteVideoInfo.sizeBytes]
  /// == 本地明文尺寸，可直接按尺寸判幂等（不必像云后端那样绕物理尺寸走清单）。
  ///
  /// 仅当 client syncVideoFiles 开且 isInterconnect 时由 [run] 调用。进度走
  /// [SyncPhase.videos]，逐项错误进 report.errors 不中断，[report.videosExported] 计上传数。
  Future<void> _syncVideosLive(
    SyncRunReport report,
    InterconnectSyncBackend backend,
  ) async {
    // host 既有视频（uid → 清单条目；sizeBytes null=host 无法 stat）。
    final Map<String, RemoteVideoInfo> hostByUid = <String, RemoteVideoInfo>{
      for (final RemoteVideoInfo info in await backend.listRemoteVideos())
        info.id: info,
    };

    // 稳定顺序（uid 升序）遍历本地可上传视频，先算出真正要传的（host 无 / 尺寸不同），
    // 让进度分母只计实际上传数。字幕（BUG-964）：视频本轮上传 ⇒ 其全部 sidecar 一并
    // 推；host 已有视频但清单报无外挂字幕 ⇒ 只补推字幕（不重传视频）。
    final List<VideoBookRow> localVideos = <VideoBookRow>[
      for (final VideoBookRow v in await _db.allVideoBooks())
        if (_isUploadableLocalVideo(v)) v,
    ]..sort((VideoBookRow a, VideoBookRow b) => a.bookUid.compareTo(b.bookUid));

    final Map<String, List<String>?> sidecarDirCache =
        <String, List<String>?>{};
    final List<({VideoBookRow row, File file, bool pushVideo})> toPush =
        <({VideoBookRow row, File file, bool pushVideo})>[];
    for (final VideoBookRow v in localVideos) {
      final File file = File(v.videoPath);
      if (!file.existsSync()) {
        report.errors.add(
            'live push video "${v.title}": local file missing: ${v.videoPath}');
        continue;
      }
      final RemoteVideoInfo? host = hostByUid[v.bookUid];
      final int? hostSize = host?.sizeBytes;
      final int localSize = await file.length();
      // host 已有：尺寸可比且相等 ⇒ 跳过（幂等）；host 尺寸不可知（null）也跳过（无从
      // 判差异，避免每轮全量重传大视频，下轮 host stat 成功即自愈）。host 无 ⇒ 上传。
      final bool pushVideo =
          !(host != null && (hostSize == null || hostSize == localSize));
      // 字幕补推判据与视频同粒度：host 已有任一 sidecar 即跳过（改字幕内容/后加语言
      // 不重推，与视频同尺寸跳过一致）。
      // pushVideo==false 蕴含 host!=null（流程分析已提升，无需判空）。
      final bool pushSubtitles = (pushVideo || !host.hasSubtitle) &&
          _localSidecarSubtitles(v.videoPath, sidecarDirCache).isNotEmpty;
      if (!pushVideo && !pushSubtitles) continue;
      toPush.add((row: v, file: file, pushVideo: pushVideo));
    }

    final int total = toPush.length;
    int index = 0;
    // 老 host 无字幕端点（首个 404/405）后停止本轮后续字幕推送，只记一条可见提示
    // （与合集端点缺失的可见性纪律一致），不把每条视频都刷成一条错误。
    bool subtitleEndpointMissing = false;
    for (final ({VideoBookRow row, File file, bool pushVideo}) item in toPush) {
      final VideoBookRow v = item.row;
      _emit(SyncPhase.videos,
          itemIndex: index, itemTotal: total, title: v.title);
      bool videoOk = !item.pushVideo;
      if (item.pushVideo) {
        try {
          await backend.putRemoteVideo(
            v.bookUid,
            item.file,
            title: v.title,
            onProgress: (double f) => _emit(SyncPhase.videos,
                itemIndex: index,
                itemTotal: total,
                title: v.title,
                fileFraction: f),
          );
          report.videosExported++;
          videoOk = true;
        } catch (e) {
          report.noteError('live push video "${v.title}"', e);
        }
      }
      // 字幕跟着视频走：视频本轮失败就不推字幕（host 侧无行可挂）。
      if (videoOk && !subtitleEndpointMissing) {
        subtitleEndpointMissing = !await _pushVideoSubtitlesLive(
          report: report,
          backend: backend,
          row: v,
          sidecarDirCache: sidecarDirCache,
        );
        if (subtitleEndpointMissing) {
          report.errors.add(
              'live push subtitles: host has no subtitle endpoint (older app '
              'version) — update the host app to sync video subtitles');
        }
      }
      index++;
    }
  }

  /// 把 [row] 视频的全部本地 sidecar 字幕推给 host（BUG-964）。
  ///
  /// 返回 false 表示 host 无字幕端点（老版本，404/405），调用方停止本轮后续字幕
  /// 推送；单条字幕的其它失败进 [report.errors] 不中断。
  Future<bool> _pushVideoSubtitlesLive({
    required SyncRunReport report,
    required InterconnectSyncBackend backend,
    required VideoBookRow row,
    required Map<String, List<String>?> sidecarDirCache,
  }) async {
    final String stem = p.basenameWithoutExtension(row.videoPath);
    for (final File sub
        in _localSidecarSubtitles(row.videoPath, sidecarDirCache)) {
      final String suffix = p.basename(sub.path).substring(stem.length);
      try {
        final bool supported = await backend
            .putRemoteVideoSubtitle(row.bookUid, sub, suffix: suffix);
        if (!supported) return false;
      } catch (e) {
        report.noteError('live push subtitle "${p.basename(sub.path)}"', e);
      }
    }
    return true;
  }

  /// 列出 [videoPath] 同目录属于它的全部 sidecar 字幕文件（[listSidecarSubtitles]
  /// 匹配规则）。[sidecarDirCache] 按目录缓存一次 listSync（同目录多视频的 sweep
  /// 不重复扫盘）；目录不可读缓存 null → 返回空。
  List<File> _localSidecarSubtitles(
    String videoPath,
    Map<String, List<String>?> sidecarDirCache,
  ) {
    final String dir = p.dirname(videoPath);
    final List<String>? names = sidecarDirCache.putIfAbsent(dir, () {
      try {
        return Directory(dir)
            .listSync(followLinks: false)
            .whereType<File>()
            .map((FileSystemEntity f) => p.basename(f.path))
            .toList();
      } on FileSystemException {
        return null;
      }
    });
    if (names == null) return const <File>[];
    return <File>[
      for (final String name
          in listSidecarSubtitles(p.basenameWithoutExtension(videoPath), names))
        File(p.join(dir, name)),
    ];
  }
}
