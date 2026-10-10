library;

export 'package:fushi_engine/media/video/metadata/video_local_extra_classifier.dart';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_engine/media/video/bluray/bluray_disc_extras.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_local_extra_classifier.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_nfo_reader.dart';
import 'package:fushi_engine/media/video/metadata/video_sidecar_artifact_store.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 扫描完成后的本地作品索引：即使尚未联网刮削，也建立可展示的规范作品；同时绑定
/// 唯一可判定归属的本地预告/花絮。
class VideoSourceMetadataIndexer {
  const VideoSourceMetadataIndexer(this.database);

  final FushiDatabase database;

  /// 返回这一轮有没有真的写库（新建 / 重写作品、绑定 / 解绑特典）。
  ///
  /// 启动时对每个来源都跑一遍（HomePage 回填），所以「什么都没变」必须是零写入、
  /// 零 NFO 解析：旧实现对每个带 NFO 的已有作品都整部 `apply` 重写、对每个特典
  /// 都删一次插一次，调用方再无条件整页刷新视频库——每次打开 app 都像在重新
  /// 加载资料。
  Future<bool> index(SourceLibraryRow source) {
    if (source.mediaKind != 'video' || source.transport != 'local' ||
        source.videoGroupingMode == 'folder') {
      return Future<bool>.value(false);
    }
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterOperation();
    if (lease == null) return Future<bool>.value(false);
    return _indexUnlocked(source).whenComplete(lease.release);
  }

  Future<bool> _indexUnlocked(SourceLibraryRow source) async {
    bool changed = false;
    final List<VideoSourceScrapeWork> allWorks =
        await VideoSourceWorkPlanner(database).plan(source);
    final List<VideoSourceScrapeWork> works = <VideoSourceScrapeWork>[
      for (final VideoSourceScrapeWork work in allWorks)
        if (work.members.any((VideoBookRow member) =>
            classifyLocalVideoExtra(member.videoPath) == null))
          work,
    ];
    final VideoMetadataDatabaseStore store =
        VideoMetadataDatabaseStore(database);
    final VideoNfoReader nfoReader = VideoNfoReader(
      generatedArtifactChecker:
          DatabaseSidecarGeneratedArtifactChecker(database),
    );
    final Map<int, _IndexedWorkRoot> indexed = <int, _IndexedWorkRoot>{};
    for (final VideoSourceScrapeWork work in works) {
      final VideoMetadataWorkRow? existing = work.collection == null
          ? await database
              .getVideoMetadataWorkByBook(work.members.single.bookUid)
          : await database
              .getVideoMetadataWorkByCollection(work.collection!.id);
      final List<String> videoPaths = <String>[
        for (final VideoBookRow member in work.members) member.videoPath,
      ];
      if (existing != null) {
        // 已建档作品：NFO 自作品行上次落库后没改过（或根本没有 NFO），这次读到的
        // 内容上次已经吃进去了（在线刮削也经 mergeNfoAuthority 合并过），下面的
        // 分支必然保留现行——只 stat 不解析，直接跳过。
        final DateTime? nfoModifiedAt = await nfoReader.newestModifiedAt(
          sourceRoot: source.rootPath,
          videoPaths: videoPaths,
        );
        if (nfoModifiedAt == null ||
            nfoModifiedAt.millisecondsSinceEpoch <= existing.updatedAt) {
          indexed[existing.id] = _IndexedWorkRoot(
            workId: existing.id,
            root: _workRoot(work.members, source.rootPath),
            memberPaths: _memberPaths(work),
          );
          continue;
        }
      }
      final VideoMetadataWork? nfoMetadata = await nfoReader.readForPaths(
        sourceRoot: source.rootPath,
        fallbackTitle: work.title,
        videoPaths: videoPaths,
      );
      final VideoMetadataLookup? existingLookup =
          existing == null ? null : await store.confirmedLookup(work);
      final bool existingIsAniDb =
          existingLookup?.provider == VideoMetadataProviderKind.anidb;
      int workId;
      if (existing != null && (existingIsAniDb || nfoMetadata == null)) {
        // A source rescan never replaces an established AniDB identity (or
        // its TMDB cross references) from a sidecar snapshot. With no external
        // NFO it also preserves pre-AniDB metadata and historical identities;
        // the canonical scrape path can migrate those only after AniDB has
        // resolved successfully instead of erasing them during local indexing.
        workId = existing.id;
      } else {
        final VideoMetadataWork metadata = nfoMetadata ?? _provisional(work);
        workId = (await store.apply(
          work,
          metadata,
          seasonEpisodesAuthoritative: metadata.seasons.isNotEmpty,
        ))
            .workId;
        changed = true;
      }
      indexed[workId] = _IndexedWorkRoot(
        workId: workId,
        root: _workRoot(work.members, source.rootPath),
        memberPaths: _memberPaths(work),
      );
    }

    final List<VideoBookRow> books = (await database.allVideoBooks())
        .where((VideoBookRow row) => row.sourceId == source.id)
        .toList(growable: false);
    final Map<String, String> discExtras = await blurayDiscExtras(
      books.map((VideoBookRow row) => row.videoPath),
    );
    for (final VideoBookRow book in books) {
      final VideoLocalExtraMatch? match =
          classifyLocalVideoExtra(book.videoPath);
      final String? discMain = discExtras[normalizeVideoPath(book.videoPath)];
      final List<_IndexedWorkRoot> candidates;
      if (match != null) {
        candidates = _candidatesByDirectory(indexed.values, book.videoPath);
      } else if (discMain != null) {
        // 蓝光特典挂在同盘正片的作品下：同一个 PLAYLIST 目录里可能并排着几条
        // 正片级标题，按目录就近会二义，按「含正片那条 .mpls 的作品」才唯一。
        final String main = normalizeVideoPath(discMain);
        candidates = <_IndexedWorkRoot>[
          for (final _IndexedWorkRoot value in indexed.values)
            if (value.memberPaths.contains(main)) value,
        ];
      } else {
        continue;
      }
      if (candidates.isEmpty ||
          (candidates.length > 1 &&
              candidates[0].root.length == candidates[1].root.length)) {
        continue;
      }
      // 旧版本把 NCOP/NCED 当独立电影建立过 book-owned work。现在已能唯一绑定
      // 父作品时原地清掉这份错误规范实体；VideoBook 本身不删，仍留在“全部视频”。
      final int removed = await (database.delete(database.videoMetadataWorks)
            ..where((table) => table.bookUid.equals(book.bookUid)))
          .go();
      if (removed > 0) changed = true;
      final String kind =
          _kindName(match?.kind ?? VideoMetadataExtraKind.extra);
      final VideoMetadataExtraRow? current =
          await database.getVideoMetadataExtraByBook(book.bookUid);
      if (current != null &&
          current.extraKey == 'local:${book.bookUid}' &&
          current.workId == candidates.first.workId &&
          current.kind == kind &&
          current.sourceKind == 'local' &&
          current.title == book.title &&
          current.thumbnailPath == book.coverPath &&
          current.sortOrder == 0) {
        // 绑定没变：不写，免得每次启动都刷新 updatedAt、触发展示层整页重载。
        continue;
      }
      changed = true;
      final int now = DateTime.now().millisecondsSinceEpoch;
      await database.upsertVideoMetadataExtra(
        VideoMetadataExtrasCompanion.insert(
          extraKey: 'local:${book.bookUid}',
          workId: candidates.first.workId,
          bookUid: Value<String?>(book.bookUid),
          kind: kind,
          sourceKind: 'local',
          title: book.title,
          thumbnailPath: Value<String?>(book.coverPath),
          sortOrder: const Value<int>(0),
          updatedAt: now,
        ),
      );
    }
    return changed;
  }

  static VideoMetadataWork _provisional(VideoSourceScrapeWork work) {
    final Map<int, List<VideoMetadataEpisode>> episodes =
        <int, List<VideoMetadataEpisode>>{};
    for (final VideoBookRow member in work.members) {
      final VideoNameInfo parsed =
          parseVideoFilename(p.basename(member.videoPath));
      if (parsed.episode == null) continue;
      final int season = parsed.season ?? 1;
      episodes.putIfAbsent(season, () => <VideoMetadataEpisode>[]).add(
            VideoMetadataEpisode(
              seasonNumber: season,
              episodeNumber: parsed.episode!,
              title: member.title,
            ),
          );
    }
    final bool episodic = work.isEpisodic || episodes.isNotEmpty;
    return VideoMetadataWork(
      provider: VideoMetadataProviderKind.local,
      kind: episodic ? VideoMetadataMediaKind.tv : VideoMetadataMediaKind.movie,
      title: work.title,
      seasons: <VideoMetadataSeason>[
        for (final MapEntry<int, List<VideoMetadataEpisode>> entry
            in episodes.entries)
          VideoMetadataSeason(
            seasonNumber: entry.key,
            title: 'Season ${entry.key}',
            episodeCount: entry.value.length,
            episodes: entry.value
              ..sort((VideoMetadataEpisode a, VideoMetadataEpisode b) =>
                  a.episodeNumber.compareTo(b.episodeNumber)),
          ),
      ],
    );
  }

  static Set<String> _memberPaths(VideoSourceScrapeWork work) => <String>{
        for (final VideoBookRow member in work.members)
          normalizeVideoPath(member.videoPath),
      };

  /// 路径型特典（NCOP / 预告 / Kodi extras 目录）的父作品：目录最近、且唯一。
  static List<_IndexedWorkRoot> _candidatesByDirectory(
    Iterable<_IndexedWorkRoot> indexed,
    String videoPath,
  ) {
    final String directory = p.dirname(p.normalize(p.absolute(videoPath)));
    return indexed
        .where((_IndexedWorkRoot value) =>
            p.equals(value.root, directory) ||
            p.isWithin(value.root, directory))
        .toList()
      ..sort((_IndexedWorkRoot a, _IndexedWorkRoot b) =>
          b.root.length.compareTo(a.root.length));
  }

  static String _workRoot(List<VideoBookRow> members, String sourceRoot) {
    List<String> parts =
        p.split(p.dirname(p.normalize(p.absolute(members.first.videoPath))));
    for (final VideoBookRow member in members.skip(1)) {
      final List<String> other =
          p.split(p.dirname(p.normalize(p.absolute(member.videoPath))));
      int length = 0;
      while (length < parts.length &&
          length < other.length &&
          parts[length].toLowerCase() == other[length].toLowerCase()) {
        length++;
      }
      parts = parts.take(length).toList(growable: false);
    }
    String root = p.joinAll(parts);
    if (RegExp(r'^(season|s)\s*\d+|specials$', caseSensitive: false)
        .hasMatch(p.basename(root))) {
      root = p.dirname(root);
    }
    final String source = p.normalize(p.absolute(sourceRoot));
    return p.isWithin(source, root) ? root : source;
  }

  static String _kindName(VideoMetadataExtraKind kind) => switch (kind) {
        VideoMetadataExtraKind.behindTheScenes => 'behind_the_scenes',
        VideoMetadataExtraKind.deletedScene => 'deleted_scene',
        _ => kind.name,
      };
}

class _IndexedWorkRoot {
  const _IndexedWorkRoot({
    required this.workId,
    required this.root,
    required this.memberPaths,
  });
  final int workId;
  final String root;

  /// 作品成员的归一路径（蓝光特典按「含同盘正片」认父作品）。
  final Set<String> memberPaths;
}
