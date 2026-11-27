library;

export 'package:fushi_engine/media/video/metadata/video_local_extra_classifier.dart';

import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:fushi_engine/media/video/bluray/bluray_disc_extras.dart';
import 'package:fushi_engine/media/video/bluray/bluray_library_title.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart'
    show blurayDiscRootForPlaylistPath, isBlurayPlaylistPath;
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
import 'package:fushi_engine/media/video/metadata/video_scrape_scope.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 扫描完成后的本地作品索引：即使尚未联网刮削，也建立可展示的规范作品；同时绑定
/// 唯一可判定归属的本地预告/花絮。
///
/// 索引的单位是刮削范围（`video_scrape_scope.dart`）：已登记的本机视频来源，或
/// 无来源范围 [sourcelessLocalVideoScrapeScope]（「导入文件夹（仅此一次）」扫完删掉
/// 临时来源行后、手动导入的单文件、来源被移除后留下的视频）。无来源范围与刮削链
/// 同口径：成员按 [videoBookInScrapeScope] 取，NFO / 作品根的边界按
/// [videoScrapeRootFor] 现算（BUG-5418：修前只认来源行，一次性导入的视频永远没有
/// 本地作品与特典绑定，`SPs\` 里的特典在系列墙上各自成卡）。
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
    if (source.mediaKind != 'video' ||
        source.transport != 'local' ||
        source.videoGroupingMode == 'folder' ||
        // 一次性导入的临时行扫完即删：在它上面建的绑定没有意义，行删掉后由无来源
        // 范围（调用方在删行后索引 [sourcelessLocalVideoScrapeScope]）接手。
        isOneShotImportSource(source)) {
      return Future<bool>.value(false);
    }
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterOperation();
    if (lease == null) return Future<bool>.value(false);
    return _indexUnlocked(source).whenComplete(lease.release);
  }

  Future<bool> _indexUnlocked(SourceLibraryRow source) async {
    // 认领孤儿蓝光标题要把它们挂到一个真实来源行上；无来源范围没有扫描根、也没有
    // 可写的来源 id，不认领（它们本身就落在无来源范围里，下面照常索引）。
    bool changed =
        !isSourcelessVideoScrapeScope(source) &&
        await _adoptOrphanBlurayTitles(source);
    final List<VideoSourceScrapeWork> allWorks = await VideoSourceWorkPlanner(
      database,
    ).plan(source);
    final List<VideoSourceScrapeWork> works = <VideoSourceScrapeWork>[
      for (final VideoSourceScrapeWork work in allWorks)
        if (work.members.any(
          (VideoBookRow member) =>
              classifyLocalVideoExtra(member.videoPath) == null,
        ))
          work,
    ];
    final VideoMetadataDatabaseStore store = VideoMetadataDatabaseStore(
      database,
    );
    final VideoNfoReader nfoReader = VideoNfoReader(
      generatedArtifactChecker: DatabaseSidecarGeneratedArtifactChecker(
        database,
      ),
    );
    final Map<int, _IndexedWorkRoot> indexed = <int, _IndexedWorkRoot>{};
    for (final VideoSourceScrapeWork work in works) {
      final VideoMetadataWorkRow? existing = work.collection == null
          ? await database.getVideoMetadataWorkByBook(
              work.members.single.bookUid,
            )
          : await database.getVideoMetadataWorkByCollection(
              work.collection!.id,
            );
      final List<String> videoPaths = <String>[
        for (final VideoBookRow member in work.members) member.videoPath,
      ];
      final String scopeRoot = videoScrapeRootFor(source, videoPaths);
      if (existing != null) {
        // 已建档作品：NFO 自作品行上次落库后没改过（或根本没有 NFO），这次读到的
        // 内容上次已经吃进去了（在线刮削也经 mergeNfoAuthority 合并过），下面的
        // 分支必然保留现行——只 stat 不解析，直接跳过。
        final DateTime? nfoModifiedAt = await nfoReader.newestModifiedAt(
          sourceRoot: scopeRoot,
          videoPaths: videoPaths,
        );
        if (nfoModifiedAt == null ||
            nfoModifiedAt.millisecondsSinceEpoch <= existing.updatedAt) {
          indexed[existing.id] = _IndexedWorkRoot(
            workId: existing.id,
            root: _workRoot(work.members, scopeRoot),
            memberPaths: _memberPaths(work),
            episodic: work.isEpisodic,
          );
          continue;
        }
      }
      final VideoMetadataWork? nfoMetadata = await nfoReader.readForPaths(
        sourceRoot: scopeRoot,
        fallbackTitle: work.title,
        videoPaths: videoPaths,
      );
      final VideoMetadataLookup? existingLookup = existing == null
          ? null
          : await store.confirmedLookup(work);
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
          // 占位作品（没有 NFO）只补旧投影的空位：库里已有的旧刮削行带着在线身份与
          // 简介，不能被文件名推出的空壳顶掉（BUG-5418 审查）。
          preserveExistingLegacyProjection: nfoMetadata == null,
          seasonEpisodesAuthoritative: metadata.seasons.isNotEmpty,
        )).workId;
        changed = true;
      }
      indexed[workId] = _IndexedWorkRoot(
        workId: workId,
        root: _workRoot(work.members, scopeRoot),
        memberPaths: _memberPaths(work),
        episodic: work.isEpisodic,
      );
    }

    final List<VideoBookRow> books = (await database.allVideoBooks())
        .where((VideoBookRow row) => videoBookInScrapeScope(row, source))
        .toList(growable: false);
    final Map<String, String> discExtras = await discMemberExtras(
      books.map((VideoBookRow row) => row.videoPath),
    );
    for (final VideoBookRow book in books) {
      final VideoLocalExtraMatch? match = classifyLocalVideoExtra(
        book.videoPath,
      );
      final String? discMain = discExtras[normalizeVideoPath(book.videoPath)];
      final _IndexedWorkRoot? owner;
      if (match != null) {
        owner = _ownerByDirectory(indexed.values, book.videoPath);
      } else if (discMain != null) {
        if (await _dropStaleDiscExtraEpisode(book)) changed = true;
        // 蓝光特典挂在同盘父标题的作品下：同一个 PLAYLIST 目录里可能并排着几条
        // 正片级标题，按目录就近会二义，按「含父标题那条 .mpls 的作品」才唯一。
        // 正片不在库时父标题是顶上来的最长特典，它自己进了计划、有作品
        // （[discMemberExtras]）。
        final String main = normalizeVideoPath(discMain);
        final List<_IndexedWorkRoot> candidates = <_IndexedWorkRoot>[
          for (final _IndexedWorkRoot value in indexed.values)
            if (value.memberPaths.contains(main)) value,
        ];
        owner = candidates.length == 1 ? candidates.single : null;
      } else {
        continue;
      }
      if (owner == null) continue;
      // 旧版本把 NCOP/NCED 当独立电影建立过 book-owned work。现在已能唯一绑定
      // 父作品时原地清掉这份错误规范实体；VideoBook 本身不删，仍留在“全部视频”。
      final int removed = await (database.delete(
        database.videoMetadataWorks,
      )..where((table) => table.bookUid.equals(book.bookUid))).go();
      if (removed > 0) changed = true;
      final String kind = _kindName(
        match?.kind ?? VideoMetadataExtraKind.extra,
      );
      final VideoMetadataExtraRow? current = await database
          .getVideoMetadataExtraByBook(book.bookUid);
      if (current != null &&
          current.extraKey == 'local:${book.bookUid}' &&
          current.workId == owner.workId &&
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
          workId: owner.workId,
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

  /// 原盘特典 [book] 身上残留的刮削身份：选片判据改过之前它被选成盘标题、进了盘
  /// 合集，刮削按合集顺序给了它集号（《ぼっち・ざ・ろっく！》BD 每卷的采访被编成
  /// 第 3 集，集名、剧照都是「馳せサンズ」），或者单独成过一部作品（临时资料行顶着
  /// 「BOCCHI THE ROCK! 6 - 03」）。特典不进刮削计划，重刮不会再写它，这些行只会
  /// 一直顶着正片的集名 / 剧照。结构上已确证它是特典：删掉它的刮削行、解开分集
  /// 绑定——用户手动钉死的绑定（[kUserVerifiedMatchRating]）除外。有改动时返回 true。
  Future<bool> _dropStaleDiscExtraEpisode(VideoBookRow book) async {
    bool changed = false;
    final VideoScrapeMetaRow? meta = await database.getVideoScrapeMeta(
      book.bookUid,
    );
    if (meta != null) {
      await database.deleteVideoScrapeMeta(book.bookUid);
      changed = true;
    }
    final int unbound =
        await (database.update(database.videoMetadataEpisodes)..where(
              (table) =>
                  table.bookUid.equals(book.bookUid) &
                  (table.anidbMatchRating.isNull() |
                      table.anidbMatchRating
                          .equals(kUserVerifiedMatchRating)
                          .not()),
            ))
            .write(
              const VideoMetadataEpisodesCompanion(
                bookUid: Value<String?>(null),
              ),
            );
    return changed || unbound > 0;
  }

  /// 认领本来源目录下没有来源的蓝光盘标题（BUG-3231 / 3233）。
  ///
  /// 原盘菜单首版从菜单进入特典时当场手写建行：没有来源、名字是「盘目录名 ·
  /// MPLS 号」。没有来源的行不在任何来源的计划与索引里，所以它既刮不到、也挂不到
  /// 正片作品下，只能当一张孤零零的卡片留在库首层。这一步按入库规则
  /// （[ensureBlurayTitleInLibrary]）补来源、把首版自动名改回盘名，接下来的索引就把
  /// 它当特典挂到正片下。启动回填对每个来源都跑这里，旧版本留下的行开一次 app 就
  /// 自愈；没有孤儿时零写入。
  Future<bool> _adoptOrphanBlurayTitles(SourceLibraryRow source) async {
    final String root = p.normalize(p.absolute(source.rootPath));
    // 按盘归组：一张盘读一次、一个事务认领完（[ensureBlurayDiscTitlesInLibrary]）。
    final Map<String, List<String>> orphansByDisc = <String, List<String>>{};
    final Map<String, String> discRootOf = <String, String>{};
    for (final VideoBookRow row in await database.allVideoBooks()) {
      if (row.sourceId != null || !isBlurayPlaylistPath(row.videoPath)) {
        continue;
      }
      if (!p.isWithin(root, p.normalize(p.absolute(row.videoPath)))) continue;
      final String? discRoot = blurayDiscRootForPlaylistPath(row.videoPath);
      if (discRoot == null) continue;
      final String key = normalizeVideoPath(discRoot);
      discRootOf.putIfAbsent(key, () => discRoot);
      orphansByDisc.putIfAbsent(key, () => <String>[]).add(row.videoPath);
    }
    bool changed = false;
    for (final MapEntry<String, List<String>> entry in orphansByDisc.entries) {
      final List<VideoBookRow> adopted = await ensureBlurayDiscTitlesInLibrary(
        database,
        discRoot: discRootOf[entry.key]!,
        playlistPaths: entry.value,
        sourceId: source.id,
      );
      if (adopted.any((VideoBookRow row) => row.sourceId != null)) {
        changed = true;
      }
    }
    return changed;
  }

  static VideoMetadataWork _provisional(VideoSourceScrapeWork work) {
    final Map<int, List<VideoMetadataEpisode>> episodes =
        <int, List<VideoMetadataEpisode>>{};
    for (final VideoBookRow member in work.members) {
      final VideoNameInfo parsed = parseVideoFilename(
        p.basename(member.videoPath),
      );
      if (parsed.episode == null) continue;
      final int season = parsed.season ?? 1;
      episodes
          .putIfAbsent(season, () => <VideoMetadataEpisode>[])
          .add(
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
              ..sort(
                (VideoMetadataEpisode a, VideoMetadataEpisode b) =>
                    a.episodeNumber.compareTo(b.episodeNumber),
              ),
          ),
      ],
    );
  }

  static Set<String> _memberPaths(VideoSourceScrapeWork work) => <String>{
    for (final VideoBookRow member in work.members)
      normalizeVideoPath(member.videoPath),
  };

  /// 路径型特典（NCOP / 预告 / Kodi extras 目录）的父作品：根目录离它最近的那一层
  /// 作品里唯一的一部；那一层有好几部时，其中**唯一的剧集作品**（多集合集）认领。
  ///
  /// 反馈 yMd0aT-fLN：BD 发布目录里正片 26 集旁并排着 `[OVA01]`～`[OVA06]`。OVA 解不出
  /// 集号，计划器把它们各自立成单部作品（它们在资料源上本就常是独立条目），作品根与
  /// 正片相同；修前同根即判二义、一个都不绑，`SPs\` 里的 NCOP / NCED / Menu 于是在系列
  /// 墙上各自成卡。发布目录的特典属于那部剧集：同一层只有一部剧集作品时由它认领；
  /// 有两部以上剧集作品（或一部都没有、只有几部单片）仍判二义不绑，不随便挑一个。
  static _IndexedWorkRoot? _ownerByDirectory(
    Iterable<_IndexedWorkRoot> indexed,
    String videoPath,
  ) {
    final String directory = p.dirname(p.normalize(p.absolute(videoPath)));
    final List<_IndexedWorkRoot> enclosing = indexed
        .where(
          (_IndexedWorkRoot value) =>
              p.equals(value.root, directory) ||
              p.isWithin(value.root, directory),
        )
        .toList(growable: false);
    if (enclosing.isEmpty) return null;
    final int nearest = enclosing
        .map((_IndexedWorkRoot value) => value.root.length)
        .reduce((int a, int b) => a > b ? a : b);
    final List<_IndexedWorkRoot> tier = <_IndexedWorkRoot>[
      for (final _IndexedWorkRoot value in enclosing)
        if (value.root.length == nearest) value,
    ];
    if (tier.length == 1) return tier.single;
    final List<_IndexedWorkRoot> series = <_IndexedWorkRoot>[
      for (final _IndexedWorkRoot value in tier)
        if (value.episodic) value,
    ];
    return series.length == 1 ? series.single : null;
  }

  static String _workRoot(List<VideoBookRow> members, String sourceRoot) {
    List<String> parts = p.split(
      p.dirname(p.normalize(p.absolute(members.first.videoPath))),
    );
    for (final VideoBookRow member in members.skip(1)) {
      final List<String> other = p.split(
        p.dirname(p.normalize(p.absolute(member.videoPath))),
      );
      int length = 0;
      while (length < parts.length &&
          length < other.length &&
          parts[length].toLowerCase() == other[length].toLowerCase()) {
        length++;
      }
      parts = parts.take(length).toList(growable: false);
    }
    String root = p.joinAll(parts);
    if (RegExp(
      r'^(season|s)\s*\d+|specials$',
      caseSensitive: false,
    ).hasMatch(p.basename(root))) {
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
    required this.episodic,
  });
  final int workId;
  final String root;

  /// 剧集作品（多集合集，[VideoSourceScrapeWork.isEpisodic]）。同一层根目录上并排
  /// 几部作品时，路径型特典归其中唯一的剧集作品（[VideoSourceMetadataIndexer._ownerByDirectory]）。
  final bool episodic;

  /// 作品成员的归一路径（蓝光特典按「含同盘正片」认父作品）。
  final Set<String> memberPaths;
}
