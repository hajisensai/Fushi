part of '../local_library_host_service.dart';

/// 视频域（B4 按域拆出）：清单与 DTO 组装、封面 / 文件 / 字幕解析、剪音频、播放位置与偏好、删除、上传落地。
/// 方法逐字搬自 LocalLibraryHostService。封面守卫登记（media_cover_write_guard_test）指向本文件：
/// importVideo 派生 VideoStorage.coversDir，裸写只在 _moveFileInto 搬视频本体与字幕。
mixin _LocalLibraryHostVideos
    on _LocalLibraryHostBase, _LocalLibraryHostShared {
  /// videoBookUid → 标签名列表 的一趟映射（TODO-1165）。
  Future<Map<String, List<String>>> _tagNamesByVideoUid() async =>
      (await _db.allVideoTagAddedAtByName()).map(
          (String key, Map<String, int> byName) =>
              MapEntry(key, byName.keys.toList()));

  // ── 视频（P4-1，只读）────────────────────────────────────────────────────────

  /// host 当前视频清单（从 VideoBooks 表读，按 importedAt DESC 排序）。
  ///
  /// [sizeBytes] 取 videoPath 对应文件的大小（stat），文件不存在时为 null。
  /// [durationMs] 目前恒为 null（DB 无 duration 列，后续由 ffprobe/libmpv 填充）。
  /// [hasSubtitle] 当前视频文件旁能找到外挂字幕时为 true。
  @override
  Future<List<RemoteVideoInfo>> listVideos() async {
    final List<VideoBookRow> rows = await _db.allVideoBooks();
    // 按 importedAt 降序（null 排最后）
    rows.sort((VideoBookRow a, VideoBookRow b) {
      final int? ta = a.importedAt;
      final int? tb = b.importedAt;
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });

    final Map<String, List<String>> tagsByVideoUid =
        await _tagNamesByVideoUid();
    final ({
      Map<String, RemoteCollectionMembership> membership,
      Map<String, MediaCollectionRow> collectionByEntry,
    }) collections = await _primaryCollectionData();
    final Map<String, RemoteCollectionMembership> membership =
        collections.membership;
    // 批量预取：位置 prefs / 标签 LWW 时钟 / 移除墓碑各一趟查询，sidecar 同目录只扫
    // 一次。旧实现逐行 2~3 次 prefs 读 + 1 次行重查 + 2 次标签查询 + 1 次全目录
    // listSync——500 行清单一次 ≈ 2500 次 DB 往返 + 500 次目录扫描，且封面端点每张
    // 封面重跑整份清单时按 N² 放大（见 [videoCoverPath]）。
    final Map<String, String> allPrefs = await _db.getAllPrefs();
    final Map<String, Map<String, int>> tagAddedAtByUid =
        await _db.allVideoTagAddedAtByName();
    final Map<String, Map<String, int>> tagTombByUid =
        await _db.allTagTombstonesByName(MediaKind.video);
    final Map<String, List<String>?> sidecarDirCache =
        <String, List<String>?>{};
    final List<RemoteVideoInfo> videos = <RemoteVideoInfo>[];
    for (final VideoBookRow row in rows) {
      videos.add(_videoInfoFromRow(
        row,
        tags: tagsByVideoUid[row.bookUid] ?? const <String>[],
        // 合集成员键：video 条目 mediaType='video'、entryKey=bookUid（§2.3 任务5.1）。
        collection: membership[MediaKind.video.compositeKey(row.bookUid)],
        collectionRow: collections
            .collectionByEntry[MediaKind.video.compositeKey(row.bookUid)],
        prefs: allPrefs,
        tagsAddedAt: tagAddedAtByUid[row.bookUid] ?? const <String, int>{},
        tagTombstones: tagTombByUid[row.bookUid] ?? const <String, int>{},
        sidecarDirCache: sidecarDirCache,
      ));
    }
    return videos;
  }

  /// 按 [id] 单查视频封面磁盘路径（封面端点专用，一次 DB 单行查询 + stat；绝不
  /// materialize 整份 [listVideos]——旧封面路径每张封面重跑全量清单是 O(N²) 主犯）。
  @override
  Future<String?> videoCoverPath(String id) async {
    final VideoBookRow? row = await _db.getVideoBookByBookUid(id);
    if (row == null) return null;
    return _existingFilePath(row.coverPath);
  }

  /// 构建单条 [RemoteVideoInfo]（内部辅助，纯同步：所有 DB 数据均由 [listVideos]
  /// 批量预取后经参数注入，仅保留文件 stat 与目录缓存内的 sidecar 匹配）。
  RemoteVideoInfo _videoInfoFromRow(
    VideoBookRow row, {
    required Map<String, String> prefs,
    required Map<String, int> tagsAddedAt,
    required Map<String, int> tagTombstones,
    required Map<String, List<String>?> sidecarDirCache,
    List<String> tags = const <String>[],
    RemoteCollectionMembership? collection,
    MediaCollectionRow? collectionRow,
  }) {
    final String videoPath = row.videoPath;
    int? sizeBytes;
    bool hasSubtitle = false;
    String? subtitleFileName;

    if (videoPath.isNotEmpty) {
      final File f = File(videoPath);
      if (f.existsSync()) {
        try {
          sizeBytes = f.lengthSync();
        } catch (_) {
          // stat 失败：保守返回 null
        }
        // 检查外挂字幕 sidecar（廉价：目录 listing 每目录只扫一次 + 纯字符串匹配）。
        final String dir = p.dirname(videoPath);
        final List<String>? dirFiles =
            sidecarDirCache.putIfAbsent(dir, () => _listDirFileNames(dir));
        final String? picked = dirFiles == null
            ? null
            : pickSidecar(
                p.basenameWithoutExtension(videoPath),
                dirFiles,
                langCode: _videoSubtitleLangCode,
              );
        if (picked != null) {
          hasSubtitle = true;
          subtitleFileName = picked;
        }
        // BUG-814：列表端点**不做**内嵌字幕轨 ffmpeg 探测。旧实现在此逐视频串行
        // spawn `ffmpeg -i`（每项超时基线 60s、大文件到 1200s、无缓存、每次 GET 全量
        // 重跑），大库（如 511 个视频）轻易超过 client 的 15s listTimeout → 远端视频
        // 判空 → 手机整页空。内嵌轨是**播放时**才需要的信息，已由 `/streamurl` 端点
        // (`fushi_sync_server.dart` `_embeddedSubtitleTracksForRequest`) 在拉流时按需
        // 探测并下发（client 唯一消费者 video_fushi_page 读的是 streamurl 响应，列表
        // 的 embeddedSubtitleTracks 零消费）。故此处保持 embeddedSubtitleTracks 为空、
        // hasSubtitle 只反映廉价的外挂 sidecar——列表变纯 DB/stat 读，与 listBooks 对称、
        // 毫秒返回。
      }
    }

    final String? coverPath = _existingFilePath(row.coverPath);
    // TODO-653: 把 host 端记录的播放断点带进清单条目，供 client 跨设备恢复。
    // 语义与 [getVideoPosition]\(id, episodeIndex: 0\) 完全一致：prefs 断点（本机/
    // 远端播放统一键）与旧 `VideoBooks.lastPositionMs`（时间戳 0）取较新——只是行
    // 已在手、prefs 已批量预取，不再逐行发查询。
    // 系列级播放偏好（schema v52 同系列共享）：合集成员的无戳基底 = 系列级 ?? 本集
    // row 值（与本机播放页 [effectiveSeriesDelayMs] 同一决议）。此前只读 row，host
    // 在合集里调的轴远端永远看不到。
    // 播放偏好带戳状态（播放偏好同步泛化批）：语义与 [getVideoPlayback] 完全一致
    // ——无戳基底（系列级 ?? row）与带戳 prefs 逐字段严格较新者胜；prefs 已批量
    // 预取，不逐行发查询。
    String? nullableStr(String? raw) {
      if (raw == null) return null;
      final String decoded = PrefCodec.decode<String>(raw, '');
      return decoded.isEmpty ? null : decoded;
    }

    final VideoPlaybackSyncState playback = VideoPlaybackSyncState.merge(
      VideoPlaybackSyncState(
        delayMs:
            effectiveSeriesDelayMs(collectionRow?.subtitleDelayMs, row.delayMs),
        audioTrackId: effectiveSeriesAudioTrackId(
            collectionRow?.audioTrackId, row.audioTrackId),
        secondarySubtitleSource: row.secondarySubtitleSource,
        secondaryDelayMs: effectiveSeriesSecondaryDelayMs(
            collectionRow?.secondarySubtitleDelayMs, row.secondaryDelayMs),
      ),
      VideoPlaybackSyncState(
        delayMs: PrefCodec.decode<int>(
            prefs[videoRemoteDelayPrefKey(row.bookUid)] ?? '', 0),
        delayAt: PrefCodec.decode<int>(
            prefs[videoRemoteDelayAtPrefKey(row.bookUid)] ?? '', 0),
        audioTrackId:
            nullableStr(prefs[videoRemoteAudioTrackPrefKey(row.bookUid)]),
        audioTrackAt: PrefCodec.decode<int>(
            prefs[videoRemoteAudioTrackAtPrefKey(row.bookUid)] ?? '', 0),
        secondarySubtitleSource: nullableStr(
            prefs[videoRemoteSecondarySubtitlePrefKey(row.bookUid)]),
        secondarySubtitleAt: PrefCodec.decode<int>(
            prefs[videoRemoteSecondarySubtitleAtPrefKey(row.bookUid)] ?? '', 0),
        secondaryDelayMs: int.tryParse(
            nullableStr(prefs[videoRemoteSecondaryDelayPrefKey(row.bookUid)]) ??
                ''),
        secondaryDelayAt: PrefCodec.decode<int>(
            prefs[videoRemoteSecondaryDelayAtPrefKey(row.bookUid)] ?? '', 0),
      ),
    );
    final ({int positionMs, int updatedAtMs}) progress = resolvePositionLww(
      localPositionMs: PrefCodec.decode<int>(
          prefs[videoRemotePositionPrefKey(row.bookUid)] ?? '', 0),
      localUpdatedAtMs: PrefCodec.decode<int>(
          prefs[videoRemotePositionAtPrefKey(row.bookUid)] ?? '', 0),
      remotePositionMs: row.lastPositionMs,
      remoteUpdatedAtMs: 0,
    );
    // TODO-885: 解析 playlistJson → 远端剧集（只 index+title，绝不带 host path）。
    final List<RemoteVideoEpisode> episodes = _episodesFromRow(row);
    final int currentEpisode = episodes.length > 1
        ? row.currentEpisode.clamp(0, episodes.length - 1)
        : 0;
    return RemoteVideoInfo(
      id: row.bookUid,
      title: row.title,
      sizeBytes: sizeBytes,
      hasSubtitle: hasSubtitle,
      subtitleFileName: subtitleFileName,
      embeddedSubtitleTracks: const <RemoteVideoEmbeddedSubtitleTrack>[],
      // durationMs: 暂为 null，DB 无此列（后续接线任务填充）
      hasCover: coverPath != null,
      coverPath: coverPath,
      positionMs: progress.positionMs,
      positionUpdatedAtMs: progress.updatedAtMs,
      // 播放偏好随清单下发（BUG-996 调轴起步，播放偏好同步泛化批扩展为全字段）：
      // client 起播据带戳字段做逐字段 LWW 决议，sweep 免逐视频 GET。
      delayMs: playback.delayMs,
      delayUpdatedAtMs: playback.delayAt,
      audioTrackId: playback.audioTrackId,
      audioTrackUpdatedAtMs: playback.audioTrackAt,
      secondarySubtitleSource: playback.secondarySubtitleSource,
      secondarySubtitleUpdatedAtMs: playback.secondarySubtitleAt,
      secondaryDelayMs: playback.secondaryDelayMs,
      secondaryDelayUpdatedAtMs: playback.secondaryDelayAt,
      // 看完标记下发（client 剧集面板角标；此前远端集无口径恒无标记）。
      completedAt: row.completedAt?.millisecondsSinceEpoch,
      episodes: episodes,
      currentEpisode: currentEpisode,
      tags: tags,
      // tags 稳健档：带上标签 LWW 时钟 + 移除墓碑，供 client mergeRemoteVideoTags 传播
      // host 侧删除/改名、防复活（旧 client 忽略、按 tags 名单只增）。
      tagsAddedAt: tagsAddedAt,
      tagTombstones: tagTombstones,
      collection: collection,
      // 入库时刻下发：client 的「最近添加」行与合集组间序都按它排；不下发就只能
      // 给远端占位造假 importedAt，远端条目结构上进不了「最近添加」。
      importedAt: row.importedAt,
    );
  }

  /// 把 [row] 的 `playlistJson` 解析成远端剧集列表（TODO-885）。坏 JSON / 单视频
  /// （≤1 集）返回空列表 = 单视频语义（向后兼容）。**只取 index+title**，host 端
  /// 文件 path 留在 host（client 用 episodeIndex 反查），绝不进 [RemoteVideoEpisode]。
  List<RemoteVideoEpisode> _episodesFromRow(VideoBookRow row) {
    final List<PlaylistEntry> entries = _parsePlaylistEntries(row.playlistJson);
    if (entries.length <= 1) return const <RemoteVideoEpisode>[];
    return <RemoteVideoEpisode>[
      for (int i = 0; i < entries.length; i++)
        RemoteVideoEpisode(index: i, title: entries[i].title),
    ];
  }

  /// 纯解析 `playlistJson` 为 [PlaylistEntry] 列表（坏 JSON 返回空）。host 端按集反查
  /// 文件 path 用（[_resolveEpisodeVideoPath]）。
  List<PlaylistEntry> _parsePlaylistEntries(String? playlistJson) {
    if (playlistJson == null || playlistJson.isEmpty) {
      return const <PlaylistEntry>[];
    }
    try {
      final dynamic decoded = jsonDecode(playlistJson);
      if (decoded is! List) return const <PlaylistEntry>[];
      return <PlaylistEntry>[
        for (final dynamic e in decoded)
          if (e is Map) PlaylistEntry.fromJson(e.cast<String, dynamic>()),
      ];
    } catch (_) {
      return const <PlaylistEntry>[];
    }
  }

  /// 按 (bookUid=[id], [episodeIndex]) 从 host DB 反查该集真实视频文件路径（TODO-885）。
  ///
  /// **DB-only 安全契约**：path 永远来自 host 自己 `playlistJson` 解析，绝不接受外部
  /// 传入。[episodeIndex]<=0 或非播放列表时回退 `videoPath`（当前选中集 / 单视频）。
  /// 越界 [episodeIndex] 返回 null（安全拒绝）。
  Future<String?> _resolveEpisodeVideoPath(String id, int episodeIndex) async {
    if (episodeIndex < 0) return null; // 非法下标安全拒绝。
    final VideoBookRow? row = await _db.getVideoBookByBookUid(id);
    if (row == null) return null;
    // 当前集 / 单视频（episodeIndex==0）：用 row.videoPath，等价旧行为。
    if (episodeIndex == 0) {
      return row.videoPath.isEmpty ? null : row.videoPath;
    }
    // 播放列表按集：DB 解析 playlistJson，越界安全拒绝。
    final List<PlaylistEntry> entries = _parsePlaylistEntries(row.playlistJson);
    if (episodeIndex >= entries.length) return null;
    final String path = entries[episodeIndex].path;
    return path.isEmpty ? null : path;
  }

  /// 按 [id]（即 `VideoBooks.bookUid`）反查真实视频文件。
  ///
  /// **只查 DB**，不接受外部文件路径。文件不存在或 id 未知时返回 null。
  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async {
    final String? path = await _resolveEpisodeVideoPath(id, episodeIndex);
    if (path == null || path.isEmpty) return null;
    final File f = File(path);
    return f.existsSync() ? f : null;
  }

  /// 按 [id] 查找对应视频的外挂字幕文件（sidecar）。
  ///
  /// 用 [langCode] 优先匹配带语言标记的字幕（如 `.ja.srt`）；内封字幕不在此列。
  /// 找不到外挂字幕或视频未知时返回 null。
  @override
  Future<File?> resolveVideoSubtitle(
    String id, {
    String langCode = '',
    int episodeIndex = 0,
  }) async {
    final String? videoPath = await _resolveEpisodeVideoPath(id, episodeIndex);
    if (videoPath == null || videoPath.isEmpty) return null;
    final String effectiveLangCode =
        langCode.isEmpty ? _videoSubtitleLangCode : langCode;
    final String? subPath =
        findSidecarSubtitle(videoPath, langCode: effectiveLangCode);
    if (subPath == null) return null;
    final File f = File(subPath);
    return f.existsSync() ? f : null;
  }

  /// BUG-1004：host 端本地裁 mining 句子音频（见抽象声明）。用 [resolveVideoFile] 反查真实
  /// 本地文件后调 [extractAudioSegmentViaFfmpeg]（本地路径、不经网络/TLS——绕开 client
  /// ffmpeg 抓 host 自签 https/token 流的整类失败）。裁到独立临时目录，产物返回给调用方，
  /// 调用方读完删该目录；失败清理临时目录并返回 null。
  @override
  Future<File?> clipVideoAudio(
    String id, {
    required int startMs,
    required int endMs,
    int episodeIndex = 0,
    int? audioStreamIndex,
    int? audioStreamCount,
    int audioChannels = 1,
    String audioBitrate = '64k',
  }) async {
    if (endMs <= startMs) return null;
    final File? file = await resolveVideoFile(id, episodeIndex: episodeIndex);
    if (file == null) return null;
    final Directory tmp =
        Directory.systemTemp.createTempSync('hibiki_clip_audio');
    final String out = p.join(tmp.path, 'clip.aac');
    final String? result = await extractAudioSegmentViaFfmpeg(
      inputPath: file.path,
      startMs: startMs,
      endMs: endMs,
      outputPath: out,
      audioStreamIndex: audioStreamIndex,
      audioStreamCount: audioStreamCount,
      audioChannels: audioChannels,
      audioBitrate: audioBitrate,
    );
    if (result == null) {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {
        // best-effort：临时目录清理失败不影响返回 null（裁切已失败）。
      }
      return null;
    }
    return File(result);
  }

  /// 读 host 端 [id] 视频的播放断点（TODO-653 / TODO-816 断点②）。
  ///
  /// 真相源是 `video_remote_position_<bookUid>` + `video_remote_position_at_<bookUid>`
  /// prefs（host 本机播放与远端 resume 路径统一写此键空间，见 video_fushi_page
  /// `_persistPosition` / `_persistRemotePosition`）。
  ///
  /// 向后兼容：TODO-816 之前 host 本机播放只写 `VideoBooks.lastPositionMs`、不写 prefs，
  /// 那部分旧进度在 prefs 里缺失。故 prefs 无记录时回退查 `VideoBooks.lastPositionMs`
  /// （旧数据无独立时间戳记 0），与 prefs 经 [resolvePositionLww] 取较新——既能读
  /// 出旧本机播放进度（client 跨设备恢复），又不让无时间戳的旧值盖过更新的 prefs 进度。
  @override
  Future<({int positionMs, int updatedAtMs})> getVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async {
    final int prefsPos = await _db.getPrefTyped<int>(
        videoRemotePositionEpisodePrefKey(id, episodeIndex), 0);
    final int prefsAt = await _db.getPrefTyped<int>(
        videoRemotePositionEpisodeAtPrefKey(id, episodeIndex), 0);
    // 旧 host 本机播放只写 VideoBooks.lastPositionMs（整书一个值，无按集语义）；只在
    // episodeIndex<=0（当前集 / 单视频）回退它，避免给某集错配整书的旧进度。
    final VideoBookRow? row =
        episodeIndex <= 0 ? await _db.getVideoBookByBookUid(id) : null;
    final int rowPos = row?.lastPositionMs ?? 0;
    // BUG-996：lastPositionMs 列无时间戳，此前硬编码 remoteUpdatedAtMs:0，使 host 的真
    // 进度在跨设备 LWW 里恒输给任何带 now 戳的本地断点（client 一旦碰过就再也拉不回
    // host 的桌面新进度）。用 importedAt 作「进度至少和导入一样旧」的可辩护下界戳——
    // client 真更近才看过仍会赢（语义可接受），但 client 无有效断点时 host 能续上。
    final int rowAt = rowPos > 0 ? (row?.importedAt ?? 0) : 0;
    return resolvePositionLww(
      localPositionMs: prefsPos,
      localUpdatedAtMs: prefsAt,
      remotePositionMs: rowPos,
      remoteUpdatedAtMs: rowAt,
    );
  }

  /// 把 client 上报的 [id] 视频断点写入 host（TODO-653）。
  ///
  /// 冲突解决「取较新时间戳」（[resolvePositionLww]）：仅当 [updatedAtMs] 严格
  /// 新于 host 已存时间戳才覆盖，避免旧设备滞后上报回退新进度。负位置 clamp 0。
  @override
  Future<void> putVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    final ({int positionMs, int updatedAtMs}) current =
        await getVideoPosition(id, episodeIndex: episodeIndex);
    final ({int positionMs, int updatedAtMs}) winner = resolvePositionLww(
      localPositionMs: current.positionMs,
      localUpdatedAtMs: current.updatedAtMs,
      remotePositionMs: positionMs < 0 ? 0 : positionMs,
      remoteUpdatedAtMs: updatedAtMs,
    );
    if (winner.updatedAtMs == current.updatedAtMs &&
        winner.positionMs == current.positionMs) {
      return; // host 已存更新或相等，no-op。
    }
    await _db.setPrefTyped<int>(
        videoRemotePositionEpisodePrefKey(id, episodeIndex), winner.positionMs);
    await _db.setPrefTyped<int>(
        videoRemotePositionEpisodeAtPrefKey(id, episodeIndex),
        winner.updatedAtMs);
    // BUG-1731：prefs 键空间只被「下发清单给子端」消费，host 自己的 UI（继续观看
    // / 下一集 / 合集续播锚点）读的是 VideoBooks.lastPositionMs / lastPlayedAt。
    // 子端上报只写 prefs 会让 host 端 UI 永远看不到对端进度——胜者来自对端时镜像
    // 写行，与 client 侧 sync_orchestrator 的 writeBackLocal 同纪律。playedAt 用
    // **对端的** updatedAtMs（绝不是 now）：传 now 会把对方三天前看的冒充成本机刚
    // 看的，钉死合集续播锚点（BUG-1542）。仅 episodeIndex<=0（合集每集一行 / 单
    // 视频）镜像；episodeIndex>0 是 host-playlist 单行多集形态，行级
    // lastPositionMs 无按集语义，写它会把某一集的进度错配成整行进度。
    if (episodeIndex <= 0 && await _db.getVideoBookByBookUid(id) != null) {
      await _db.updateVideoBookPosition(id, winner.positionMs,
          playedAt: winner.updatedAtMs);
    }
  }

  /// [id] 视频的主归属合集行（无归属 / 未知 id 返回 null）。系列级播放偏好
  /// （`subtitleDelayMs`）解析用，与清单侧 [_primaryCollectionData] 同折叠语义
  /// （最小 collectionId 主归属）。两次轻查询（主归属映射 + 单行取合集）。
  Future<MediaCollectionRow?> _primaryVideoCollectionRow(String id) async {
    final Map<String, int> primaryByEntry =
        await _db.getPrimaryCollectionIdByEntry();
    final int? cid = primaryByEntry[MediaKind.video.compositeKey(id)];
    if (cid == null) return null;
    return _db.getMediaCollectionById(cid);
  }

  /// prefs 里的可空字符串字段读数：缺失/空串 → null（「未设」与「显式清除」由
  /// at 键区分：at>0 且值空 = 显式清除）。
  Future<String?> _readNullableStringPref(String key) async {
    final String raw = await _db.getPrefTyped<String>(key, '');
    return raw.isEmpty ? null : raw;
  }

  /// 读 host 端视频 [id] 的播放偏好带戳状态（[VideoPlaybackSyncHost]）。
  ///
  /// 无戳基底 = 本机播放读的同一决议（系列级 ?? row，[effectiveSeriesDelayMs] 族），
  /// 与带戳 prefs 逐字段「严格较新者胜」合并：旧数据无 prefs 时行为与本机播放完全
  /// 一致（向后兼容）。
  @override
  Future<VideoPlaybackSyncState> getVideoPlayback(String id) async {
    final VideoBookRow? row = await _db.getVideoBookByBookUid(id);
    final MediaCollectionRow? col =
        row == null ? null : await _primaryVideoCollectionRow(id);
    final VideoPlaybackSyncState base = VideoPlaybackSyncState(
      delayMs: effectiveSeriesDelayMs(col?.subtitleDelayMs, row?.delayMs ?? 0),
      audioTrackId:
          effectiveSeriesAudioTrackId(col?.audioTrackId, row?.audioTrackId),
      secondarySubtitleSource: row?.secondarySubtitleSource,
      secondaryDelayMs: effectiveSeriesSecondaryDelayMs(
          col?.secondarySubtitleDelayMs, row?.secondaryDelayMs),
    );
    final VideoPlaybackSyncState stamped = VideoPlaybackSyncState(
      delayMs: await _db.getPrefTyped<int>(videoRemoteDelayPrefKey(id), 0),
      delayAt: await _db.getPrefTyped<int>(videoRemoteDelayAtPrefKey(id), 0),
      audioTrackId:
          await _readNullableStringPref(videoRemoteAudioTrackPrefKey(id)),
      audioTrackAt:
          await _db.getPrefTyped<int>(videoRemoteAudioTrackAtPrefKey(id), 0),
      secondarySubtitleSource: await _readNullableStringPref(
          videoRemoteSecondarySubtitlePrefKey(id)),
      secondarySubtitleAt: await _db.getPrefTyped<int>(
          videoRemoteSecondarySubtitleAtPrefKey(id), 0),
      secondaryDelayMs: int.tryParse(await _db.getPrefTyped<String>(
          videoRemoteSecondaryDelayPrefKey(id), '')),
      secondaryDelayAt: await _db.getPrefTyped<int>(
          videoRemoteSecondaryDelayAtPrefKey(id), 0),
    );
    return VideoPlaybackSyncState.merge(base, stamped);
  }

  /// 把 client 上报的播放偏好合并进 host（[VideoPlaybackSyncHost]）。
  ///
  /// 存在性闸门：host 无该 id 的 VideoBooks 行 → no-op（防任意 id 写脏 prefs，与
  /// [putVideoPosition] 同语义）。调轴类字段越界 clamp
  /// ±[kVideoSubtitleDelayLimitMs]；各字段时间戳截到 host 当前时刻 + 5 分钟时钟
  /// 偏差余量——未来戳会永久锁死后续所有端的正常覆盖。胜出字段同时写穿
  /// row/系列级列，使 host 本机播放立即跟随（只写 row 会被非 null 系列级值遮蔽）。
  @override
  Future<void> putVideoPlayback(
      String id, VideoPlaybackSyncState incoming) async {
    if (incoming.isEmpty) return;
    if (await _db.getVideoBookByBookUid(id) == null) return;
    final int nowCapMs = DateTime.now().millisecondsSinceEpoch + 5 * 60 * 1000;
    int capAt(int at) => at > nowCapMs ? nowCapMs : at;
    final VideoPlaybackSyncState capped = VideoPlaybackSyncState(
      delayMs: incoming.delayMs
          .clamp(-kVideoSubtitleDelayLimitMs, kVideoSubtitleDelayLimitMs),
      delayAt: capAt(incoming.delayAt),
      audioTrackId: incoming.audioTrackId,
      audioTrackAt: capAt(incoming.audioTrackAt),
      secondarySubtitleSource: incoming.secondarySubtitleSource,
      secondarySubtitleAt: capAt(incoming.secondarySubtitleAt),
      secondaryDelayMs: incoming.secondaryDelayMs
          ?.clamp(-kVideoSubtitleDelayLimitMs, kVideoSubtitleDelayLimitMs),
      secondaryDelayAt: capAt(incoming.secondaryDelayAt),
    );
    final VideoPlaybackSyncState held = await getVideoPlayback(id);
    final VideoPlaybackSyncState merged =
        VideoPlaybackSyncState.merge(held, capped);
    if (merged == held) return; // host 已存更新或相等，no-op。
    final MediaCollectionRow? col = await _primaryVideoCollectionRow(id);

    if (merged.delayAt > 0 && merged.delayAt != held.delayAt) {
      await _db.setPrefTyped<int>(videoRemoteDelayPrefKey(id), merged.delayMs);
      await _db.setPrefTyped<int>(
          videoRemoteDelayAtPrefKey(id), merged.delayAt);
      await _db.updateVideoBookDelayMs(id, merged.delayMs);
      if (col != null) {
        await _db.updateMediaCollectionSubtitleDelayMs(col.id, merged.delayMs);
      }
    }
    if (merged.audioTrackAt > 0 && merged.audioTrackAt != held.audioTrackAt) {
      await _db.setPrefTyped<String>(
          videoRemoteAudioTrackPrefKey(id), merged.audioTrackId ?? '');
      await _db.setPrefTyped<int>(
          videoRemoteAudioTrackAtPrefKey(id), merged.audioTrackAt);
      await _db.updateVideoBookAudioTrackId(id, merged.audioTrackId);
      if (col != null) {
        await _db.updateMediaCollectionAudioTrackId(
            col.id, merged.audioTrackId);
      }
    }
    if (merged.secondarySubtitleAt > 0 &&
        merged.secondarySubtitleAt != held.secondarySubtitleAt) {
      await _db.setPrefTyped<String>(videoRemoteSecondarySubtitlePrefKey(id),
          merged.secondarySubtitleSource ?? '');
      await _db.setPrefTyped<int>(videoRemoteSecondarySubtitleAtPrefKey(id),
          merged.secondarySubtitleAt);
      await _db.updateVideoBookSecondarySubtitleSource(
          id, merged.secondarySubtitleSource);
    }
    if (merged.secondaryDelayAt > 0 &&
        merged.secondaryDelayAt != held.secondaryDelayAt) {
      await _db.setPrefTyped<String>(videoRemoteSecondaryDelayPrefKey(id),
          merged.secondaryDelayMs?.toString() ?? '');
      await _db.setPrefTyped<int>(
          videoRemoteSecondaryDelayAtPrefKey(id), merged.secondaryDelayAt);
      await _db.updateVideoBookSecondaryDelayMs(id, merged.secondaryDelayMs);
      if (col != null) {
        await _db.updateMediaCollectionSecondarySubtitleDelayMs(
            col.id, merged.secondaryDelayMs);
      }
    }
  }

  /// 廉价判断 host 库是否已存在 bookUid 为 [id] 的视频（一次 DB 查询）。
  @override
  Future<bool> videoExists(String id) async {
    _assertSafeVideoId(id);
    return (await _db.getVideoBookByBookUid(id)) != null;
  }

  /// 从 host 视频库删除 bookUid 为 [id] 的视频（[VideoDeletionHost]）。
  ///
  /// 与 host 用户在自己视频库长按删除同语义：repository 的完整删除 operation 负责
  /// DB 行 + 字幕 cue + 合集引用 + 删除墓碑及 app-owned 配图/字幕回收；host 再回收
  /// 自己接收上传时创建的视频副本。用户自己导入的原始视频文件绝不删除。
  @override
  Future<void> deleteVideo(String id) async {
    _assertSafeVideoId(id);
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterOperation();
    if (lease == null) throw StateError('视频刮削资料正在清理');
    try {
      await _runExclusive(
        () => VideoCoverMutationGate.runExclusive(() async {
          final VideoBookRow? row = await _db.getVideoBookByBookUid(id);
          if (row == null) return; // 幂等：不存在则静默跳过
          final bool deleted =
              await VideoBookRepository(_db).deleteVideoBookAndReclaimAssets(
            id,
            scope: DeleteScope.syncEverywhere,
            compactDatabase: false,
          );
          if (!deleted) return;
          await _deleteUploadedVideoCopy(row);
        }),
      );
    } finally {
      lease.release();
    }
  }

  /// 删除 client 上传副本目录——当且仅当该行的 `videoPath` 确实落在本 host 的
  /// `<uploadedVideoRoot>/<safeUid>/` 之内。
  ///
  /// host 用户自己导入的原片不在这个目录下，所以这条 [p.isWithin] 判据就是
  /// 「这些字节是 app 自己搬进来的」的证明；判据不成立时一个字节都不动。
  Future<void> _deleteUploadedVideoCopy(VideoBookRow row) async {
    final Directory? root = _uploadedVideoRoot;
    if (root == null) return;
    final Directory owned =
        Directory(p.join(root.path, _sanitizeVideoIdForPath(row.bookUid)));
    if (!owned.existsSync()) return;
    if (!p.isWithin(owned.path, row.videoPath)) return;
    try {
      await owned.delete(recursive: true);
    } catch (_) {
      // best-effort：目录被占用等失败不影响 DB 已删。
    }
  }

  /// 接收 client 上传的单文件视频并注册进 host 视频库（client→host live push）。
  ///
  /// 落盘目录按 [id] 确定（`<uploadedVideoRoot>/<safeUid>/`），故重复上传同一视频
  /// 覆盖同一副本、不留孤儿；`upsertVideoBook` 幂等按 bookUid 覆盖同一行。封面 best-effort
  /// 抽取，与建行解耦（绝不挡上传落库）。
  @override
  Future<void> importVideo(
    File videoFile, {
    required String id,
    required String title,
    String? originalFileName,
  }) async {
    _assertSafeVideoId(id);
    final Directory? root = _uploadedVideoRoot;
    if (root == null) {
      throw UnsupportedError(
        'importVideo requires uploadedVideoRoot to be provided',
      );
    }
    await _runExclusive(() async {
      final String safeUid = _sanitizeVideoIdForPath(id);
      final Directory destDir = Directory(p.join(root.path, safeUid));
      destDir.createSync(recursive: true);
      final File dest = File(
          p.join(destDir.path, _uploadedVideoFileName(originalFileName, id)));
      await _moveFileInto(videoFile, dest);
      await _db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(id),
        title: Value(title),
        videoPath: Value(dest.path),
        // 无外挂字幕上传：回退内嵌默认轨（与 client 下载无字幕分支一致）。
        embeddedSubtitleTrack: const Value<int?>(0),
        importedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ));
    });
    // 封面 best-effort，与建行解耦：抽帧走 ffmpeg 慢，失败留空占位（移动端无 ffmpeg
    // 返 null），绝不让封面失败使整个上传报错。
    final Future<String?> Function(
        {required String videoPath,
        required String bookUid})? extractor = _extractVideoCover;
    if (extractor != null) {
      final VideoScrapeOperationLease? lease =
          VideoScrapeOperationGate.tryEnterOperation();
      if (lease != null) {
        try {
          await VideoCoverMutationGate.runExclusive(() async {
            final VideoBookRow? row = await _db.getVideoBookByBookUid(id);
            if (row == null) return;
            final CoverMetaStore store = CoverMetaStore(
              _videoCoversDirectory ?? await VideoStorage.coversDir(),
            );
            if (!await store.allowsAutoFrameWrite(id)) return;
            final String? coverPath = await extractor(
              videoPath: row.videoPath,
              bookUid: id,
            );
            if (coverPath != null && coverPath.isNotEmpty) {
              await _db.updateVideoBookCover(id, coverPath);
              final bool committed = await store.markAutoFrameAfterWrite(id);
              if (!committed) {
                ErrorLogService.instance.log(
                  'sync.videoCover.provenanceConflict',
                  StateError('封面来源在自动抽帧期间发生变化: $id'),
                  StackTrace.current,
                );
              }
            }
          });
        } catch (error, stack) {
          // best-effort：封面失败不影响上传成功。
          ErrorLogService.instance.log(
            'sync.videoCover.backfill',
            error,
            stack,
          );
        } finally {
          lease.release();
        }
      }
    }
  }

  /// 接收 client 上传的视频外挂字幕并落到视频同目录（BUG-964，client→host live push）。
  ///
  /// 落盘名 = `<host 视频文件 stem><suffix>`，与 [resolveVideoSubtitle] 的同 stem
  /// 匹配规则天然一致；[suffix] 经 [isSidecarSubtitleSuffix] 白名单校验（拒路径
  /// 分隔符/穿越）。落位后按 host 学习语言重解析首选 sidecar（多字幕推送顺序无关、
  /// 结果收敛），镜像 client 下载路径（home_video_page `_registerDownloadedVideo`）
  /// 的行语义：`subtitleSource`/`subtitleFormat` 指向首选 sidecar、
  /// `embeddedSubtitleTrack=null`（播放走外挂）、解析 cue 落库（坏字幕 best-effort
  /// 跳过，不挡文件落位——host 仍能把字节原样转发给其它 client）。
  @override
  Future<void> importVideoSubtitle(
    File subtitleFile, {
    required String id,
    required String suffix,
  }) async {
    _assertSafeVideoId(id);
    if (!isSidecarSubtitleSuffix(suffix)) {
      throw ArgumentError.value(suffix, 'suffix', 'unsafe subtitle suffix');
    }
    await _runExclusive(() async {
      final VideoBookRow? row = await _db.getVideoBookByBookUid(id);
      if (row == null) throw StateError('unknown video: $id');
      final String videoPath = row.videoPath;
      final String lower = videoPath.toLowerCase();
      if (videoPath.isEmpty ||
          lower.startsWith('http://') ||
          lower.startsWith('https://')) {
        throw StateError('video has no local file: $id');
      }
      final File dest = File(p.join(p.dirname(videoPath),
          '${p.basenameWithoutExtension(videoPath)}$suffix'));
      await _moveFileInto(subtitleFile, dest);
      final String? preferred =
          findSidecarSubtitle(videoPath, langCode: _videoSubtitleLangCode);
      if (preferred == null) return; // 防御：刚落位的 dest 本身就是候选。
      final String ext =
          p.extension(preferred).replaceFirst('.', '').toLowerCase();
      List<AudioCue> cues = const <AudioCue>[];
      try {
        cues = parseSubtitleCues(
          content: await readTextWithEncoding(File(preferred)),
          format: ext,
          bookUid: id,
        );
      } catch (_) {
        // best-effort：解析失败不挡字幕文件落位。
      }
      await _db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(id),
        title: Value(row.title),
        videoPath: Value(row.videoPath),
        subtitleSource: Value<String?>(preferred),
        subtitleFormat: Value<String?>(ext),
        embeddedSubtitleTrack: const Value<int?>(null),
      ));
      if (cues.isNotEmpty) {
        await _db.replaceCuesForBook(
            id, cues.map(AudioCue.toCompanion).toList());
      }
    });
  }
}

// ── 本域私有的顶层 helper（原 LocalLibraryHostService 的 private static；mixin 体内看不到
//    宿主类的 static，故提到库顶层）。

/// 列出 [dir] 下的文件名（仅文件，不含子目录）；目录不存在/读取失败返回 null。
/// [listVideos] 用它配合每次调用内的目录缓存，同目录 500 个视频只扫一次。
List<String>? _listDirFileNames(String dir) {
  final Directory directory = Directory(dir);
  try {
    if (!directory.existsSync()) return null;
    return directory
        .listSync(followLinks: false)
        .whereType<File>()
        .map((File f) => p.basename(f.path))
        .toList();
  } on FileSystemException {
    return null;
  }
}

/// 校验视频 id 不含路径穿越字符（`..` / `\`）。id 允许 `/`（bookUid 形如
/// `video/xxx`），落盘前经 [_sanitizeVideoIdForPath] 压平。
void _assertSafeVideoId(String id) {
  if (id.isEmpty || id.contains('..') || id.contains('\\')) {
    throw ArgumentError.value(id, 'id', 'unsafe video id');
  }
}

/// 把视频 id 压成单层安全目录名（`/` → `_`，其余非白名单字符 → `_`）。
String _sanitizeVideoIdForPath(String id) =>
    id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

/// 上传视频落盘文件名：优先保留上传方原始 basename 的扩展名（media_kit 依赖扩展名
/// 判容器）；basename 缺失/不安全时回退 `<safeUid>.mp4`。
String _uploadedVideoFileName(String? originalFileName, String id) {
  if (originalFileName != null && originalFileName.isNotEmpty) {
    final String base = p.basename(originalFileName);
    final String safe = base.replaceAll(RegExp(r'[/\\]'), '_');
    if (safe.isNotEmpty &&
        !safe.contains('..') &&
        p.extension(safe).isNotEmpty) {
      return safe;
    }
  }
  return '${_sanitizeVideoIdForPath(id)}.mp4';
}

/// 把 [src] 搬进 [dest]（同卷 rename 最快；跨卷 rename 失败回退 copy + delete）。
Future<void> _moveFileInto(File src, File dest) async {
  try {
    await src.rename(dest.path);
  } on FileSystemException {
    await src.copy(dest.path);
    try {
      await src.delete();
    } catch (_) {
      // best-effort：源临时文件删除失败不影响落库（上层临时目录整体清理）。
    }
  }
}
