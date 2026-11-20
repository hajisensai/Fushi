import 'package:fushi_engine/media/media_extensions.dart'
    show isAudioOnlyMediaPath;
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/bluray/bluray_disc_extras.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart'
    show isDiscMemberPath;
import 'package:fushi_engine/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi_engine/media/video/metadata/video_local_extra_classifier.dart';
import 'package:fushi_engine/media/video/metadata/video_web_download_classifier.dart';
import 'package:fushi_engine/media/video/scraper/collection_member_policy.dart'
    show multiMemberCollectionIdByVideoUid;
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 一个来源内的作品刮削单元。
///
/// 多成员合集只匹配一次，成员仍保持独立 [VideoBookRow]，后续按季集号写分集资料与
/// sidecar；不属于多成员合集的视频保持独立电影候选。混来源合集只携带当前来源成员，
/// 从数据入口上保证“刮削来源 A”不会写来源 B 的路径。
class VideoSourceScrapeWork {
  const VideoSourceScrapeWork({
    required this.source,
    required this.title,
    required this.members,
    this.collection,
  });

  /// 作品所属的扫描来源。计划器产出的单元恒非 null；**null 只出现在不经计划器
  /// 的元数据写入目标**（互联 7b 回写 / 7c 客户端同步，`resolveMetadataWorkTarget`）
  /// ——那条路只走 `VideoMetadataDatabaseStore.apply`，它不读来源；任何要真的去
  /// 刮（`scrapeSource`）的入口都要求非 null。
  final SourceLibraryRow? source;
  final MediaCollectionRow? collection;
  final String title;
  final List<VideoBookRow> members;

  bool get isEpisodic => collection != null;

  String get stableKey => collection == null
      ? 'book:${members.single.bookUid}'
      : 'collection:${collection!.id}';

  /// 标题本身是否携带可识别的作品信息。
  ///
  /// 「特典 S00E01」「S01E02」这类条目标题只是集号标签：单独一个没进合集的
  /// 集号文件（BUG-2001）拿它去资料源搜索必然失败，而按目录名候选反查又会把
  /// 特典误绑成正片作品。这类作品仍进计划（用户可在待确认队列里手动指定），
  /// 但自动补刮不该反复对它做注定失败或注定误绑的尝试。
  bool get hasIdentifiableTitle => !_bareEpisodeLabel.hasMatch(title.trim());

  /// 纯集号标签：可选的「特典/SP/OVA/Special/Extra」前缀 + SxxEyy，别无其他。
  static final RegExp _bareEpisodeLabel = RegExp(
    r'^(?:特典|SP|OVA|Special|Extras?)?[\s._-]*S\d{1,3}E\d{1,4}$',
    caseSensitive: false,
  );
}

/// [VideoSourceWorkPlanner.plan] 会不会为 [source] 产出作品单元：只有视频来源，
/// 且不是目录分组模式（目录模式按导入目录组织，不按作品识别）。
bool videoSourcePlansScrapeWorks(SourceLibraryRow source) =>
    source.mediaKind == 'video' && source.videoGroupingMode != 'folder';

/// [VideoSourceWorkPlanner.plan] 会不会把 [book] 放进某个作品单元：NCOP/NCED/
/// 预告/花絮仍是 VideoBook，但不是可独立识别的作品；纯音频（原声专辑曲目等）
/// 同理——拿曲名去动画资料源搜只会失败或误绑，封面走同目录专辑封面。yt-dlp
/// 默认命名下载的 YouTube 视频（`标题 [videoId].ext`）也没有资料源作品身份，
/// 不进计划（[isYtDlpYoutubeDownloadPath]）。
bool videoBookJoinsScrapePlan(VideoBookRow book) =>
    !isAudioOnlyMediaPath(book.videoPath) &&
    classifyLocalVideoExtra(book.videoPath) == null &&
    !isYtDlpYoutubeDownloadPath(book.videoPath);

/// [VideoSourceWorkPlanner.plan] 要读的三张整表的一次性快照。
///
/// 计划只按 `sourceId` 过滤、按合集归组，三张表与来源无关；一轮里要规划多个
/// 来源的调用方（后台补刮的待确认清单）读一次、每个来源复用，而不是每个来源
/// 各读三次整表。快照只在一轮计划内有效，不跨轮缓存。
class VideoLibraryPlanSnapshot {
  const VideoLibraryPlanSnapshot({
    required this.books,
    required this.collectionItems,
    required this.collections,
  });

  final List<VideoBookRow> books;
  final List<MediaCollectionItemRow> collectionItems;
  final List<MediaCollectionRow> collections;

  static Future<VideoLibraryPlanSnapshot> load(FushiDatabase database) async =>
      VideoLibraryPlanSnapshot(
        books: await database.allVideoBooks(),
        collectionItems: await database.getAllCollectionItems(),
        collections: await database.getAllMediaCollections(),
      );
}

/// 从已入库的 `sourceId` 与合集成员关系生成按作品去重的刮削计划。
class VideoSourceWorkPlanner {
  const VideoSourceWorkPlanner(this._database);

  final FushiDatabase _database;

  /// [snapshot] 省略时自己读三张表（单来源调用方）；传入时不再读这三张表。
  Future<List<VideoSourceScrapeWork>> plan(
    SourceLibraryRow source, {
    VideoLibraryPlanSnapshot? snapshot,
  }) async {
    if (!videoSourcePlansScrapeWorks(source)) {
      return const <VideoSourceScrapeWork>[];
    }

    final List<VideoBookRow> sourceBooks =
        (snapshot?.books ?? await _database.allVideoBooks())
            .where((VideoBookRow row) => row.sourceId == source.id)
            .toList();
    if (sourceBooks.isEmpty) return const <VideoSourceScrapeWork>[];
    // 蓝光盘的特典（正片集合之外、远短于正片的标题，以及没被选成标题的播放
    // 列表）：盘名就是片名，各自拿去识别只会把制作特辑认成整部电影。正片不在库时
    // 最长的那条特典顶上、照常进计划（[discMemberExtras]）。
    final Map<String, String> discExtras = await discMemberExtras(
      sourceBooks.map((VideoBookRow row) => row.videoPath),
    );

    final List<MediaCollectionItemRow> allItems =
        snapshot?.collectionItems ?? await _database.getAllCollectionItems();
    final Map<int, MediaCollectionRow> collections = <int, MediaCollectionRow>{
      for (final MediaCollectionRow row
          in snapshot?.collections ?? await _database.getAllMediaCollections())
        row.id: row,
    };
    // 目录合集是用户组织容器，切回作品模式后仍保留，但不能充当动画身份。
    final Map<String, int> primaryCollections =
        multiMemberCollectionIdByVideoUid(<MediaCollectionItemRow>[
          for (final MediaCollectionItemRow item in allItems)
            if (collections[item.collectionId]?.sourceFolderPath == null) item,
        ]);
    final Map<int, List<VideoBookRow>> grouped = <int, List<VideoBookRow>>{};
    final List<VideoSourceScrapeWork> result = <VideoSourceScrapeWork>[];

    for (final VideoBookRow book in sourceBooks) {
      // NCOP/NCED/预告/花絮仍是 VideoBook，继续出现在“全部视频”；但它们不是
      // 可独立识别的作品，不能让一次来源刮削多出四个必失败任务。
      if (!videoBookJoinsScrapePlan(book)) continue;
      if (discExtras.containsKey(normalizeVideoPath(book.videoPath))) continue;
      final int? collectionId = primaryCollections[book.bookUid];
      final VideoNameInfo parsed = parseVideoFilename(
        p.basename(book.videoPath),
      );
      // 原盘标题（BUG-4245）：盘合集整体是一部作品。成员名是 `00001.mpls` /
      // `TITLE_01.dvdtitle`，按文件名解集号要么解不出、要么把播放列表号当集号；
      // 修前每条标题被拆成一部单独的「作品」，各自拿盘名去搜、下载任务的确认身份
      // 也绑不回任何一部。
      final bool discMember = isDiscMemberPath(book.videoPath);
      if (collectionId == null ||
          collections[collectionId] == null ||
          (parsed.episode == null && !discMember)) {
        result.add(
          VideoSourceScrapeWork(
            source: source,
            title: book.title,
            members: <VideoBookRow>[book],
          ),
        );
        continue;
      }
      grouped.putIfAbsent(collectionId, () => <VideoBookRow>[]).add(book);
    }

    final Map<(int, String), int> sortIndex = <(int, String), int>{
      for (final MediaCollectionItemRow item in allItems)
        (item.collectionId, item.entryKey): item.sortIndex,
    };
    for (final MapEntry<int, List<VideoBookRow>> entry in grouped.entries) {
      final MediaCollectionRow collection = collections[entry.key]!;
      // 盘合集按盘上的标题顺序（入库时就按标题序写进合集，见
      // `DiscLibraryImporter`），不按路径字典序（`MYGO_10` 会排到 `MYGO_2` 前面）；
      // 其余合集沿用路径序。
      final bool discWork = entry.value.every(
        (VideoBookRow book) => isDiscMemberPath(book.videoPath),
      );
      if (discWork && entry.value.length == 1) {
        // 电影盘：盘合集里除正片外的标题都是特典（[discMemberExtras] 已剔除），
        // 剩下的唯一正片就是这部电影本身，与修前同形（书作品），特典挂在它下面。
        final VideoBookRow book = entry.value.single;
        result.add(
          VideoSourceScrapeWork(
            source: source,
            title: book.title,
            members: <VideoBookRow>[book],
          ),
        );
        continue;
      }
      if (!discWork &&
          _membersAreDifferentWorks(entry.value) &&
          !await _collectionHasIdentity(collection.id)) {
        // 清单合集装的是几部不同的作品（「剧场版合集」「观看顺序」这类 m3u8：
        // 成员各在自己的作品目录、集位撞车）。把整个合集当一部作品去认，只能
        // 得到「候选都不像」的待确认；各成员各自识别才对得上（BUG-4696）。合集
        // 本身不动，它仍是用户的播放清单。合集上已记着作品身份（用户确认 / 已
        // 刮过）时那份身份优先，不按推断拆开绕过它。
        for (final VideoBookRow book in entry.value) {
          result.add(
            VideoSourceScrapeWork(
              source: source,
              title: book.title,
              members: <VideoBookRow>[book],
            ),
          );
        }
        continue;
      }
      entry.value.sort((VideoBookRow a, VideoBookRow b) {
        if (discWork) {
          final int byIndex = (sortIndex[(entry.key, a.bookUid)] ?? 0)
              .compareTo(sortIndex[(entry.key, b.bookUid)] ?? 0);
          if (byIndex != 0) return byIndex;
        }
        return a.videoPath.toLowerCase().compareTo(b.videoPath.toLowerCase());
      });
      result.add(
        VideoSourceScrapeWork(
          source: source,
          collection: collection,
          title: collection.name,
          members: List<VideoBookRow>.unmodifiable(entry.value),
        ),
      );
    }

    result.sort((VideoSourceScrapeWork a, VideoSourceScrapeWork b) {
      final int byTitle = a.title.toLowerCase().compareTo(
        b.title.toLowerCase(),
      );
      if (byTitle != 0) return byTitle;
      return a.stableKey.compareTo(b.stableKey);
    });
    return List<VideoSourceScrapeWork>.unmodifiable(result);
  }

  /// 合集是不是一份装着不同作品的清单（而不是一部作品的各集），只看结构证据，
  /// 两条同时成立才算：
  ///
  /// - **集位冲突**：有两个成员解出同一个（季, 集）（[parseVideoPath]，季号回落
  ///   父目录的季目录）。一部作品的集位不会重复；混装的剧场版个个都是 `S00E01`。
  /// - **作品根目录两两不同**（[videoWorkRootDirectory]，剥掉纯季目录那层）：每个
  ///   成员各在自己的作品目录里。有两个成员同根就不算——那种部分混装靠文件哈希
  ///   按作品拆（`_splitByAnidbWork`），这里不猜归属。
  ///
  /// 不拿文件名解出的作品名文本当判据：`01.mkv`、`第01集.mp4`、`S01E01 - Pilot`、
  /// `第01話 旅立ち` 这类「作品名只在目录上」的集文件，解出的「作品名」是集号或
  /// 集标题，整部剧会两两不同。
  static bool _membersAreDifferentWorks(List<VideoBookRow> members) {
    if (members.length < 2) return false;
    final Set<String> roots = <String>{};
    final Set<(int, int)> slots = <(int, int)>{};
    bool slotConflict = false;
    for (final VideoBookRow member in members) {
      if (!roots.add(videoWorkRootDirectory(member.videoPath))) return false;
      final VideoNameInfo info = parseVideoPath(member.videoPath);
      final int? episode = info.episode;
      if (episode == null) continue;
      if (!slots.add((info.season ?? 1, episode))) slotConflict = true;
    }
    return slotConflict;
  }

  /// 合集上是否已记着作品身份（用户确认过、或刮削写下的资料源 id）。
  Future<bool> _collectionHasIdentity(int collectionId) async {
    final VideoMetadataWorkRow? work = await _database
        .getVideoMetadataWorkByCollection(collectionId);
    if (work == null) return false;
    return (await _database.getVideoMetadataProviderIdentities(
      workId: work.id,
    )).isNotEmpty;
  }
}
