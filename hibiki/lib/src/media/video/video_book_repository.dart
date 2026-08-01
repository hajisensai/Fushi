import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:hibiki/src/media/video/m3u8_playlist.dart' show PlaylistEntry;
import 'package:hibiki/src/media/video/scraper/scraper_types.dart'
    show ScrapeInfoboxEntry, ScrapeMetadata, ScrapeSource, ScrapeTag;
import 'package:hibiki/src/media/video/video_path_migration.dart';
import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:hibiki/src/sync/deletion_propagation.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/misc/hibiki_time_format.dart';

/// VideoBooks 仓库：视频元数据 + 进度；字幕 cue 复用 audioCues 表。
class VideoBookRepository {
  const VideoBookRepository(this._db);

  final HibikiDatabase _db;

  /// 写入/更新一本视频书。
  ///
  /// TODO-817 M1b：可选 [sourceId] 指向归属的网络/本地来源库（[MediaSources].id）；
  /// 默认 null = 手动导入无来源（向后兼容，现有手动导入调用点一字不改）。只在
  /// [book] 自身没显式设过 sourceId 时才合并进 companion，避免覆盖调用方意图。
  Future<void> saveVideoBook(VideoBooksCompanion book, {int? sourceId}) {
    final VideoBooksCompanion withSource =
        sourceId == null ? book : book.copyWith(sourceId: Value(sourceId));
    return _db.upsertVideoBook(withSource);
  }

  // ── 条目刮削资料（video_scrape_meta，v54）─────────────────────────

  /// 落一本视频的条目资料（重刮即覆盖）。标签/infobox 在这里序列化成 JSON 列，
  /// 读回时由 [scrapeMetadata] 反序列化——JSON 编解码只在本仓库层出现一次，
  /// 展示层和刮削层都只见领域对象 [ScrapeMetadata]。
  Future<void> saveScrapeMetadata(String bookUid, ScrapeMetadata meta) {
    return _db.upsertVideoScrapeMeta(
      VideoScrapeMetaCompanion.insert(
        bookUid: bookUid,
        source: meta.source.name,
        subjectId: meta.subjectId,
        title: meta.title,
        originalTitle: Value<String?>(meta.originalTitle),
        summary: Value<String?>(meta.summary),
        airDate: Value<String?>(meta.airDate),
        rating: Value<double?>(meta.rating),
        ratingCount: Value<int?>(meta.ratingCount),
        episodeCount: Value<int?>(meta.episodeCount),
        tagsJson: Value<String?>(
          meta.tags.isEmpty
              ? null
              : jsonEncode(<Map<String, Object?>>[
                  for (final ScrapeTag t in meta.tags) t.toJson(),
                ]),
        ),
        infoboxJson: Value<String?>(
          meta.infobox.isEmpty
              ? null
              : jsonEncode(<Map<String, Object?>>[
                  for (final ScrapeInfoboxEntry e in meta.infobox) e.toJson(),
                ]),
        ),
        detailUrl: Value<String?>(meta.detailUrl),
        scrapedAt: DateTime.now(),
      ),
    );
  }

  /// 读一本视频的条目资料；未刮过返回 null。JSON 列损坏时该列降级为空列表（其余
  /// 字段照常返回），不因一列坏掉丢掉整条资料。
  Future<ScrapeMetadata?> scrapeMetadata(String bookUid) async {
    final VideoScrapeMetaRow? row = await _db.getVideoScrapeMeta(bookUid);
    if (row == null) return null;
    return ScrapeMetadata(
      source:
          ScrapeSource.values.asNameMap()[row.source] ?? ScrapeSource.bangumi,
      subjectId: row.subjectId,
      title: row.title,
      originalTitle: row.originalTitle,
      summary: row.summary,
      airDate: row.airDate,
      rating: row.rating,
      ratingCount: row.ratingCount,
      episodeCount: row.episodeCount,
      tags: _decodeJsonList<ScrapeTag>(row.tagsJson, ScrapeTag.fromJson),
      infobox: _decodeJsonList<ScrapeInfoboxEntry>(
        row.infoboxJson,
        ScrapeInfoboxEntry.fromJson,
      ),
      detailUrl: row.detailUrl,
    );
  }

  /// 已刮出资料的 bookUid 集合（自动刮削一次性排除已刮的，避免逐本 N+1 查询）。
  Future<Set<String>> scrapedBookUids() => _db.scrapedVideoBookUids();

  /// 删一本的条目资料（「重新刮削」前先清）。
  Future<void> deleteScrapeMetadata(String bookUid) =>
      _db.deleteVideoScrapeMeta(bookUid);

  /// 解 JSON 数组列为领域对象列表；null / 非数组 / 解析异常一律降级为空列表。
  static List<T> _decodeJsonList<T>(
    String? json,
    T? Function(Object?) fromJson,
  ) {
    if (json == null || json.isEmpty) return const <Never>[];
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return const <Never>[];
    }
    if (decoded is! List<Object?>) return const <Never>[];
    final List<T> out = <T>[];
    for (final Object? item in decoded) {
      final T? parsed = fromJson(item);
      if (parsed != null) out.add(parsed);
    }
    return out;
  }

  /// v49：记录一条「added」活动事件，喂首页 Activity 时间轴。**只在用户导入视频
  /// 成功后**调用：[VideoImportDialog] 各路径（单文件 / 文件夹单集 / 播放列表首集 /
  /// 流媒体各调一次；播放列表整本只调一次，title=合集名、mediaKey=首集 uid），以及
  /// 扫描首导的新 playlist 合集（source_library_scanner，BUG-1351：用户把新清单放进
  /// 扫描根就是入库动作，整本 1 条；重扫 reconcile 不 emit）——刻意**不放进
  /// [saveVideoBook]**，让散装文件批量扫描、远端打开（home_video_page，打开≠导入）、
  /// 云同步（app_model_library_host_service）等路径天然不 emit，避免刷屏或语义错误
  /// （对齐 EpubImporter 只在用户导入管线 emit 的做法）。timestamp/dateKey 用调用
  /// 时刻。best-effort：记账失败只 log，不影响视频已导入。
  Future<void> recordVideoImportActivity({
    required String bookUid,
    required String title,
  }) async {
    try {
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      await _db.addActivityEvent(
        eventType: kActivityAdded,
        mediaType: kActivityMediaVideo,
        title: title,
        mediaKey: bookUid,
        dateKey: HibikiTimeFormat.dayKey(
          DateTime.fromMillisecondsSinceEpoch(nowMs),
        ),
        timestampMs: nowMs,
      );
    } catch (e) {
      ErrorLogService.instance.log(
        'VideoBookRepository.recordVideoImportActivity',
        e,
        StackTrace.current,
      );
    }
  }

  /// 按标签名重建视频书标签映射（TODO-1165 跨设备下载后恢复标签）。标签是每设备
  /// 本地数据，只能按名传递：逐名 [HibikiDatabase.getOrCreateTagByName] 归一到本机
  /// tag id，再 [HibikiDatabase.addTagToVideoBook]（insertOrIgnore 幂等）。只增不删。
  Future<void> applyTagNamesToVideoBook(
    String bookUid,
    List<String> tagNames,
  ) async {
    for (final String name in tagNames) {
      if (name.isEmpty) continue;
      final int tagId = await _db.getOrCreateTagByName(name);
      await _db.addTagToVideoBook(bookUid, tagId);
    }
  }

  /// tags 稳健档 LWW：把远端标签快照（名→加入戳 + 移除墓碑）合并进视频 [bookUid]。
  /// 删除/改名跨端传播、防复活（见 [HibikiDatabase.mergeRemoteVideoTags]）。
  Future<void> mergeRemoteVideoTags(
    String bookUid, {
    required Map<String, int> remoteAddedAt,
    Map<String, int> remoteTombstones = const <String, int>{},
  }) =>
      _db.mergeRemoteVideoTags(
        bookUid,
        remoteAddedAt: remoteAddedAt,
        remoteTombstones: remoteTombstones,
      );

  /// 统一合集 Phase 2：把一个多集播放列表拆成 N 条独立 VideoBooks 行 + 一个 playlist
  /// [MediaCollections]（成员按序）。是「导入时拆集」的单一真相源，与 v38 迁移
  /// `splitPlaylistVideoBooksV38` 落库形状对齐（每集自带 positionMs 进 lastPositionMs；
  /// 每集 uid = coreUniqueVideoBookUid(coreSingleVideoBookUid(path))；playlistJson 不写、
  /// currentEpisode 恒 0；completed_at 不设）。整批包一个事务：全成或全回滚。
  ///
  /// 封面不在此处理（ffmpeg 属 app 层，且需先知集 uid 命名封面文件）——调用方在拿到
  /// [episodeUids] 后自行抽封面并 [updateCover] 到首集。返回合集 id + 各集 uid（有序）。
  Future<({int collectionId, List<String> episodeUids})> importSplitPlaylist({
    required String collectionName,
    required List<PlaylistEntry> entries,
    int? sourceId,
    bool reuseExistingPaths = false,
  }) async {
    final List<String> epUids = <String>[];
    int collectionId = 0;
    await _db.transaction(() async {
      final List<VideoBookRow> existingBooks = await listAll();
      final Set<String> taken =
          existingBooks.map((VideoBookRow r) => r.bookUid).toSet();
      for (final PlaylistEntry e in entries) {
        if (reuseExistingPaths) {
          VideoBookRow? existing;
          final String normalized = normalizeVideoPath(e.path);
          for (final VideoBookRow row in existingBooks) {
            if (normalizeVideoPath(row.videoPath) == normalized) {
              existing = row;
              break;
            }
          }
          if (existing != null) {
            epUids.add(existing.bookUid);
            continue;
          }
        }
        final String uid = coreUniqueVideoBookUid(
          coreSingleVideoBookUid(e.path),
          taken,
        );
        taken.add(uid);
        epUids.add(uid);
        await saveVideoBook(
          VideoBooksCompanion(
            bookUid: Value(uid),
            title: Value(
              e.title.isNotEmpty ? e.title : p.basenameWithoutExtension(e.path),
            ),
            videoPath: Value(e.path),
            lastPositionMs: Value(e.positionMs),
            embeddedSubtitleTrack: const Value<int?>(0),
            importedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
          sourceId: sourceId,
        );
        if (reuseExistingPaths) {
          existingBooks.add((await _db.getVideoBookByBookUid(uid))!);
        }
      }
      collectionId = await _db.createMediaCollection(
        collectionName,
        collectionType: 'playlist',
      );
      for (final String uid in epUids) {
        await _db.addToCollection(collectionId, MediaKind.video, uid);
      }
    });
    return (collectionId: collectionId, episodeUids: epUids);
  }

  /// 统一合集：把**已存在**的 playlist 合集 [collectionId] 的成员对齐到当前 m3u8 清单
  /// [entries]（增删差异同步）。补 [importSplitPlaylist] 只在首次导入落库、之后再没有
  /// 任何路径拿「当前清单」对账成员表的缺口（BUG-830：磁盘上编辑 m3u8 增删某集后，
  /// 合集成员永不更新）。
  ///
  /// 对齐以**清单为准**、按集的**稳定基身份** [coreSingleVideoBookUid]（取文件名去
  /// 扩展名、与目录/绝对路径无关，见 hibiki_core `video_book_uid`）匹配，**不是**按
  /// 完整 `videoPath`：同一集换目录（相对路径改绝对 / 移动文件夹）基身份不变 → 判为
  /// 「未变」不增删、不误制孤儿行（对齐首导 uid 派生规则与重扫 relocation 幂等契约）。
  /// - 清单有、成员没有的基身份 → 建独立 VideoBook 行（uid 同 [importSplitPlaylist] 去重）
  ///   + `addToCollection`；
  /// - 成员有、清单已删的基身份 → **只 `removeFromCollection` 解绑，不删 VideoBook 本体**
  ///   （保留其观看进度；条目脱离合集后作为独立视频存在，非破坏性）。
  ///
  /// 先加后删：整批替换时先加新集让合集非空，再删旧集，绝不让合集瞬时空掉被
  /// [HibikiDatabase.removeFromCollection] 的「移空自删」误删。已在清单里的集不重建
  /// （不重跑 [importSplitPlaylist]，避免 [coreUniqueVideoBookUid] 撞已存在 uid 加后缀
  /// 造重复行——这正是重扫从前整体跳过的原因）。返回 (新增, 移除) 计数。
  Future<({int added, int removed})> reconcileSplitPlaylist({
    required int collectionId,
    required List<PlaylistEntry> entries,
    int? sourceId,
  }) async {
    // 当前成员 bookUid → 其稳定基身份（用于与清单按基身份对齐）。
    final List<MediaCollectionItemRow> items = await _db.getCollectionItems(
      collectionId,
    );
    final Map<String, String> memberBaseByUid = <String, String>{};
    for (final MediaCollectionItemRow item in items) {
      if (item.mediaType != MediaKind.video.dbValue) continue;
      final VideoBookRow? row = await _db.getVideoBookByBookUid(item.entryKey);
      if (row != null) {
        memberBaseByUid[item.entryKey] = coreSingleVideoBookUid(row.videoPath);
      }
    }
    final Set<String> memberBases = memberBaseByUid.values.toSet();
    final Set<String> manifestBases = entries
        .map((PlaylistEntry e) => coreSingleVideoBookUid(e.path))
        .toSet();

    int added = 0;
    int removed = 0;
    final Set<String> taken =
        (await listAll()).map((VideoBookRow r) => r.bookUid).toSet();
    await _db.transaction(() async {
      // 先加：清单有、成员没有的基身份。
      for (final PlaylistEntry e in entries) {
        final String base = coreSingleVideoBookUid(e.path);
        if (memberBases.contains(base)) continue;
        final String uid = coreUniqueVideoBookUid(base, taken);
        taken.add(uid);
        await saveVideoBook(
          VideoBooksCompanion(
            bookUid: Value(uid),
            title: Value(
              e.title.isNotEmpty ? e.title : p.basenameWithoutExtension(e.path),
            ),
            videoPath: Value(e.path),
            lastPositionMs: Value(e.positionMs),
            embeddedSubtitleTrack: const Value<int?>(0),
            importedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
          sourceId: sourceId,
        );
        await _db.addToCollection(collectionId, MediaKind.video, uid);
        added++;
      }
      // 后删：成员有、清单已删的基身份（只解绑，保留 VideoBook 本体）。
      for (final MapEntry<String, String> m in memberBaseByUid.entries) {
        if (manifestBases.contains(m.value)) continue;
        await _db.removeFromCollection(collectionId, MediaKind.video, m.key);
        removed++;
      }
    });
    return (added: added, removed: removed);
  }

  Future<VideoBookRow?> getByBookUid(String bookUid) =>
      _db.getVideoBookByBookUid(bookUid);

  /// 统一合集：某合集的成员引用行（按 sortIndex 有序）。播放器据此建播放列表兄弟集。
  Future<List<MediaCollectionItemRow>> getCollectionItems(int collectionId) =>
      _db.getCollectionItems(collectionId);

  /// 统一合集：按 id 取合集（播放器取 playlist 合集名做制卡 documentTitle 系列名）。
  Future<MediaCollectionRow?> getMediaCollectionById(int id) =>
      _db.getMediaCollectionById(id);

  Future<List<VideoBookRow>> listAll() => _db.allVideoBooks();

  /// 监听视频库行集合（uid）变化，供库页在任意导入路径（页内 / 拖拽 / 外部
  /// 「用 Hibiki 打开」/ 远端下载）落库后自动刷新（BUG-793）。
  Stream<List<String>> watchVideoBookUids() => _db.watchVideoBookUids();

  /// 视频库书架展示用列表：在 [listAll] 基础上自愈被数据根迁移遗弃的封面绝对路径
  /// （[_repairMovedCoverPaths]）。**只给展示层用**——删除 GC（[collectReferencedAssetPaths]）
  /// 与去重（[findByVideoPath]）走纯 [listAll]，不引入 path_provider 依赖与写副作用。
  Future<List<VideoBookRow>> listForShelf() async =>
      _repairMovedCoverPaths(await _db.allVideoBooks());

  /// TODO-1255：自愈被数据根迁移遗弃的封面绝对路径。
  ///
  /// 视频封面（[extractVideoCover] / 手动设封面）恒落 `<documents>/video_covers`，
  /// DB `cover_path` 存的是**绝对路径**。桌面自定义数据根迁移会把 `video_covers/*`
  /// 物理搬到新根，但历史迁移漏改 `video_books.cover_path`（epub/srt 都改了），使这些
  /// 行的封面路径指向已空的旧 Documents → 书架封面全占位。迁移侧已补 rebase
  /// （[DataRootMigrator]），但**已经迁移过的旧库**里的坏路径无法再靠迁移修复。
  ///
  /// 这里在列出时兜底：某行 `cover_path` 非空且**文件不存在**，但当前
  /// [VideoStorage.coversDir] 里有同名文件（封面文件名由 bookUid 派生、1:1 对应），
  /// 就把 `cover_path` 回写到当前根下的真实位置（幂等、只指向已存在的文件、不搬不删，
  /// 修好后后续 [File.existsSync] 命中不再触发写）。文件名兜底同时也让**未来任何一次
  /// 数据根变动**都能自愈，不依赖迁移逐列覆盖。远端视频（`RemoteVideoInfo`，coverUrl）
  /// 不经本表，天然不受影响。
  Future<List<VideoBookRow>> _repairMovedCoverPaths(
    List<VideoBookRow> rows,
  ) async {
    Directory? coversDir;
    final List<VideoBookRow> out = <VideoBookRow>[];
    for (final VideoBookRow row in rows) {
      final String? cover = row.coverPath;
      if (cover == null || cover.isEmpty || File(cover).existsSync()) {
        out.add(row);
        continue;
      }
      coversDir ??= await VideoStorage.coversDir();
      final String candidate = p.join(coversDir.path, p.basename(cover));
      if (candidate != cover && File(candidate).existsSync()) {
        await _db.updateVideoBookCover(row.bookUid, candidate);
        out.add(row.copyWith(coverPath: Value<String?>(candidate)));
      } else {
        out.add(row);
      }
    }
    return out;
  }

  Future<void> updatePosition(String bookUid, int positionMs) =>
      _db.updateVideoBookPosition(bookUid, positionMs);

  /// Updates local file paths after app-owned media is relocated.
  ///
  /// Only fields with non-null arguments are written. This keeps progress,
  /// title, playlist state, audio preferences, and statistics untouched.
  Future<void> updateLocalMediaPaths(
    String bookUid, {
    String? videoPath,
    String? subtitleSource,
  }) {
    if (videoPath == null && subtitleSource == null) {
      return Future<void>.value();
    }
    return (_db.update(
      _db.videoBooks,
    )..where((tbl) => tbl.bookUid.equals(bookUid)))
        .write(
      VideoBooksCompanion(
        videoPath:
            videoPath == null ? const Value.absent() : Value<String>(videoPath),
        subtitleSource: subtitleSource == null
            ? const Value.absent()
            : Value<String?>(subtitleSource),
      ),
    );
  }

  /// TODO-1961-d：把库里落在 [fromPath] 下的路径整体重映射到 [toPath]，
  /// 返回实际改动的行数。
  ///
  /// 引擎侧改名 / 移动（TODO-1961-c）之后必须**立刻**调这个 —— 两件事成对完成，
  /// 缺一即断：只改引擎 = 做种保住了但库里全是死路径；只改库 = 库对了但引擎按
  /// 旧路径读盘，做种当场断。
  ///
  /// 三列（videoPath / subtitleSource / secondarySubtitleSource）各自判断，
  /// 哨兵值（`embedded:<n>` / `off:`）与流媒体 URL 一律不动，规则见
  /// [remapVideoBookPaths]。整批在一个事务里写，中途失败不会留下改了一半的库。
  Future<int> migrateMediaPaths({
    required String fromPath,
    required String toPath,
  }) async {
    if (fromPath.trim().isEmpty || toPath.trim().isEmpty) return 0;
    final List<VideoBookRow> rows = await _db.allVideoBooks();
    final Map<String, VideoPathRemap> pending = <String, VideoPathRemap>{};
    for (final VideoBookRow row in rows) {
      final VideoPathRemap remap = remapVideoBookPaths(
        videoPath: row.videoPath,
        subtitleSource: row.subtitleSource,
        secondarySubtitleSource: row.secondarySubtitleSource,
        fromPath: fromPath,
        toPath: toPath,
      );
      if (!remap.isEmpty) pending[row.bookUid] = remap;
    }
    if (pending.isEmpty) return 0;
    await _db.transaction(() async {
      for (final MapEntry<String, VideoPathRemap> entry in pending.entries) {
        final VideoPathRemap remap = entry.value;
        await (_db.update(
          _db.videoBooks,
        )..where((tbl) => tbl.bookUid.equals(entry.key)))
            .write(
          VideoBooksCompanion(
            videoPath: remap.videoPath == null
                ? const Value.absent()
                : Value<String>(remap.videoPath!),
            subtitleSource: remap.subtitleSource == null
                ? const Value.absent()
                : Value<String?>(remap.subtitleSource),
            secondarySubtitleSource: remap.secondarySubtitleSource == null
                ? const Value.absent()
                : Value<String?>(remap.secondarySubtitleSource),
          ),
        );
      }
    });
    return pending.length;
  }

  /// 更新播放列表当前集索引（多集导航切集后持久化）。
  Future<void> updateCurrentEpisode(String bookUid, int episodeIndex) =>
      _db.updateVideoBookEpisode(bookUid, episodeIndex);

  /// 回写整段播放列表 JSON（各集 positionMs 改变时持久化每集进度）。
  Future<void> updatePlaylistJson(String bookUid, String playlistJson) =>
      _db.updateVideoBookPlaylistJson(bookUid, playlistJson);

  /// 更新音画延迟（毫秒）：字幕 cue 同步偏移，跨重启保留。
  Future<void> updateDelayMs(String bookUid, int delayMs) =>
      _db.updateVideoBookDelayMs(bookUid, delayMs);

  /// 更新用户选中的字幕源（外挂存绝对路径；内嵌存 `embedded:<n>`；用户显式关闭存
  /// `off:` 哨兵 `SubtitleSource.offSentinel`，TODO-818；null=无偏好/从未选过，按
  /// 「自动选默认」恢复，与「显式关闭」区分，勿混用）。
  Future<void> updateSubtitleSource(String bookUid, String? subtitleSource) =>
      _db.updateVideoBookSubtitleSource(bookUid, subtitleSource);

  /// 更新用户选中的副字幕源（TODO-857 视频双字幕 Path A）：与 [updateSubtitleSource]
  /// 同款四态编码（外挂绝对路径 / `embedded:<n>` / `off:` / null）。副字幕由 libmpv
  /// `secondary-sid` 自渲染（不进 cue 流，不可查词），故无 cue，独立于 cue 事务写入。
  Future<void> updateSecondarySubtitleSource(
    String bookUid,
    String? secondarySubtitleSource,
  ) =>
      _db.updateVideoBookSecondarySubtitleSource(
        bookUid,
        secondarySubtitleSource,
      );

  /// 更新用户选中的音轨 id（libmpv `AudioTrack.id`；清除存 null）。
  Future<void> updateAudioTrackId(String bookUid, String? audioTrackId) =>
      _db.updateVideoBookAudioTrackId(bookUid, audioTrackId);

  /// 更新系列（合集）级音轨偏好（schema v52，同系列音轨记忆）。合集内任一集选音轨
  /// 写这里，全系列共享；null=清除（加载回退各集 per-book / libmpv 默认）。
  Future<void> updateCollectionAudioTrackId(
    int collectionId,
    String? audioTrackId,
  ) =>
      _db.updateMediaCollectionAudioTrackId(collectionId, audioTrackId);

  /// 更新系列（合集）级字幕调轴（音画延迟毫秒，schema v52，同系列调轴记忆）。合集内
  /// 任一集调轴写这里，全系列共享；null=清除（加载回退各集 per-book / 0）。
  Future<void> updateCollectionSubtitleDelayMs(
    int collectionId,
    int? delayMs,
  ) =>
      _db.updateMediaCollectionSubtitleDelayMs(collectionId, delayMs);

  /// 更新视频封面图绝对路径（书架/视频库长按菜单手动设置封面）。
  Future<void> updateCover(String bookUid, String coverPath) =>
      _db.updateVideoBookCover(bookUid, coverPath);

  /// 更新视频/播放列表标题（视频库长按菜单「重命名」）。
  Future<void> updateTitle(String bookUid, String title) =>
      _db.updateVideoBookTitle(bookUid, title);

  /// 删除视频书：DB 行 + 本视频的字幕 cue 行一并删（[HibikiDatabase.deleteVideoBook]
  /// 在一个事务里删 videoBooks + audio_cues；标签映射经 FK cascade）。on-disk 的
  /// 封面/字幕副本回收交给调用方的 [VideoStorage.deleteBookAssets]（按被删 book 精确
  /// 删，不全库 sweep，BUG-276）。
  /// [scope]：[DeleteScope.syncEverywhere] 记一条 sync 删除墓碑供同步传播；
  /// [DeleteScope.keepLocalOnly]（默认，含消费远端删除标记路径）只删本机不回写墓碑。
  Future<void> deleteVideoBook(
    String bookUid, {
    DeleteScope scope = DeleteScope.keepLocalOnly,
  }) async {
    await _db.deleteVideoBook(bookUid);
    // 统一合集：删条目时清其全部合集引用（逻辑外键无 DB cascade）；被清空的 playlist
    // 合集随之自删，避免留孤儿成员 / 合集卡数量虚高。
    await _db.removeEntryFromAllCollections(MediaKind.video, bookUid);
    // 删除传播（显式确认式）：仅当用户选「同步删除」才记 sync 删除墓碑，供同步发布到远端
    // 标记、其他设备逐条确认后也删。keepLocalOnly 不记，避免删本地→回写墓碑循环。best-effort。
    if (scope == DeleteScope.syncEverywhere) {
      try {
        await _db.writeSyncDeletionTombstone(
          SyncTombstoneKind.video.dbValue,
          bookUid,
          DateTime.now().millisecondsSinceEpoch,
        );
      } catch (_) {
        // best-effort：记账失败不影响视频已删。
      }
    }
  }

  /// Deletes one video row and then reclaims the app-owned files that can be
  /// proven safe to delete.
  ///
  /// The DB row is read first so cleanup can use the deleted row's `coverPath`,
  /// `subtitleSource`, and `videoPath` after the row is gone. File cleanup and
  /// DB compaction are best-effort and run outside the delete transaction.
  Future<bool> deleteVideoBookAndReclaimAssets(
    String bookUid, {
    bool compactDatabase = true,
  }) async {
    final VideoBookRow? book = await getByBookUid(bookUid);
    if (book == null) return false;

    final String? deletedCoverPath = book.coverPath;
    final String? deletedSubtitlePath = book.subtitleSource;
    final String deletedVideoPath = book.videoPath;
    await deleteVideoBook(bookUid);
    await reclaimDeletedVideoBookAssets(
      deletedBookUid: bookUid,
      deletedCoverPath: deletedCoverPath,
      deletedSubtitlePath: deletedSubtitlePath,
      deletedVideoPath: deletedVideoPath,
    );
    if (compactDatabase) {
      await compactAfterVideoDeleteBestEffort();
    }
    return true;
  }

  /// Reclaims app-owned video assets for a row that has already been deleted.
  ///
  /// Only the deleted row's own cover/subtitle paths are considered, and each
  /// candidate must still live under Hibiki's app-owned video asset directory
  /// and be unreferenced by all remaining videos. The embedded subtitle cache is
  /// derived from [deletedVideoPath] and is skipped while another video still
  /// points at the same original path.
  Future<void> reclaimDeletedVideoBookAssets({
    required String deletedBookUid,
    required String? deletedCoverPath,
    required String? deletedSubtitlePath,
    required String deletedVideoPath,
  }) async {
    try {
      final ({Set<String> covers, Set<String> subtitles}) refs =
          await collectReferencedAssetPaths(excludeBookUid: deletedBookUid);
      await VideoStorage.deleteBookAssets(
        deletedCoverPath: deletedCoverPath,
        deletedSubtitlePath: deletedSubtitlePath,
        stillReferencedCoverPaths: refs.covers,
        stillReferencedSubtitlePaths: refs.subtitles,
      );
      await VideoStorage.gcOrphanCovers(referencedCoverPaths: refs.covers);
      if (!await isDuplicateVideoPath(
        deletedVideoPath,
        excludeBookUid: deletedBookUid,
      )) {
        await VideoStorage.deleteEmbeddedSubtitleCacheForVideoPath(
          deletedVideoPath,
        );
      }
    } catch (e, stack) {
      debugPrint('VideoBookRepository: video asset cleanup failed: $e\n$stack');
    }
  }

  /// Best-effort SQLite space reclamation after video deletion. Keep this
  /// outside delete transactions; callers doing batch deletes should call it
  /// once after the batch, not once per row.
  Future<void> compactAfterVideoDeleteBestEffort() async {
    try {
      await _db.customStatement('VACUUM');
      await _db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (e, stack) {
      debugPrint(
        'VideoBookRepository: compact after video delete failed: $e\n$stack',
      );
    }
  }

  /// 收集「当前 DB 仍引用的、app 拥有的视频副本路径」，供删除回收做护栏 / 封面历史
  /// GC 用作保留集。
  ///
  /// - `covers`：每本视频的 `coverPath`（落在 `<appDocs>/video_covers/`，文件名由
  ///   bookUid 1:1 派生，引用集对封面完整）。
  /// - `subtitles`：每本视频的 `subtitleSource`（手动导入/Jimaku 下载的外挂字幕落在
  ///   `<appDocs>/video_subtitles/`；sidecar/内嵌源也会被收进来，但它们不在该目录里，
  ///   无害）。**注意**：播放列表只在该列存最后选中那集的字幕路径，其余各集副本不在
  ///   DB，故字幕引用集**不完整**——只可用作删除护栏（命中则保留），不可拿去全库 sweep
  ///   删字幕，否则会误删别集活副本（见 [VideoStorage] 类注释 / BUG-276）。
  ///
  /// [excludeBookUid] 非 null 时跳过该 book 自己的引用（删除时取「全库其余 book」的
  /// 引用集，避免被删 book 自己的路径反而把自己的资产护住不删）。
  Future<({Set<String> covers, Set<String> subtitles})>
      collectReferencedAssetPaths({String? excludeBookUid}) async {
    final List<VideoBookRow> all = await listAll();
    final Set<String> covers = <String>{};
    final Set<String> subtitles = <String>{};
    for (final VideoBookRow row in all) {
      if (excludeBookUid != null && row.bookUid == excludeBookUid) continue;
      final String? cover = row.coverPath;
      if (cover != null && cover.isNotEmpty) covers.add(cover);
      final String? sub = row.subtitleSource;
      if (sub != null && sub.isNotEmpty) subtitles.add(sub);
    }
    return (covers: covers, subtitles: subtitles);
  }

  /// 按 `videoPath` 匹配返回第一条引用该物理文件的视频书行；无则 null。
  ///
  /// 比对前两侧都经 [normalizeVideoPath] 归一（统一分隔符 / 去冗余路径段，与
  /// [externalVideoBookUid] 同款语义），因此 Windows 上 `D:\Foo\bar.mkv` 与
  /// `D:/Foo/bar.mkv`（file_picker 原始路径 vs argv 路径分隔符不一致）视为同一
  /// 文件命中同一行——既覆盖新写入行也覆盖存的是未归一路径的旧库内导入行。
  /// 与 [isDuplicateVideoPath] 同一比对语义（后者即据此实现），是「同一物理
  /// 文件是否已入库」的单一真相源。外部「打开方式」入库前用它复用库内已导入的
  /// 同文件 bookUid，避免派生 `video/ext/<sha1>` 第二身份重复插行（TODO-903）。
  ///
  /// [excludeBookUid] 非 null 时跳过该 book 自己（与其余方法一致）。
  Future<VideoBookRow?> findByVideoPath(
    String videoPath, {
    String? excludeBookUid,
  }) async {
    if (videoPath.isEmpty) return null;
    final List<VideoBookRow> all = await listAll();
    for (final VideoBookRow row in all) {
      if (excludeBookUid != null && row.bookUid == excludeBookUid) continue;
      if (normalizeVideoPath(row.videoPath) == normalizeVideoPath(videoPath)) {
        return row;
      }
    }
    return null;
  }

  Future<bool> isDuplicateVideoPath(
    String videoPath, {
    String? excludeBookUid,
  }) async =>
      (await findByVideoPath(videoPath, excludeBookUid: excludeBookUid)) !=
      null;

  Future<void> saveCues({
    required String bookUid,
    required List<AudioCue> cues,
  }) =>
      _db.replaceCuesForBook(bookUid, cues.map(AudioCue.toCompanion).toList());

  Future<List<AudioCue>> loadCues(String bookUid) async {
    final List<AudioCueRow> rows = await _db.getCuesForBook(bookUid);
    return rows.map(AudioCue.fromRow).toList();
  }

  /// 原子地写入「选中字幕源 + 解析出的 cue」（BUG-081，单视频用）。两步合进一个
  /// 事务，避免 cue 落库但 source 未更新（或反之）导致下次恢复时显示内容与字幕源
  /// 标签不一致。播放列表不走此路（每集按磁盘动态解析，见 VideoHibikiPage）。
  Future<void> saveSubtitleSelection({
    required String bookUid,
    required String? subtitleSource,
    required List<AudioCue> cues,
  }) =>
      _db.transaction(() async {
        await _db.replaceCuesForBook(
          bookUid,
          cues.map(AudioCue.toCompanion).toList(),
        );
        await _db.updateVideoBookSubtitleSource(bookUid, subtitleSource);
      });
}
