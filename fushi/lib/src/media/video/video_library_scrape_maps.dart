import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/video/video_home_layout.dart'
    show VideoFileEpisodeStills, videoAirYear;

/// 视频库页的刮削展示映射（海报 / 剧照 / 年份 / 合集资料 / 特典 / 媒体图组）。
///
/// 整表重读时由 [VideoLibraryScrapeMaps.load] 一次建好；刮削写入之后由
/// [VideoLibraryScrapeMaps.patched] 只替换变了的键（拍板
/// design-nmv-video16-scrape-refresh：大库刮削批次里每 2 s 整表重算一次，
/// 3000 行实测每轮占 UI isolate 中位 19.8 ms / P95 35.3 ms）。
///
/// 两条路径共用同一组聚合函数，按键分桶：增量只重算 [VideoScrapePresentationDelta]
/// 点名的键，结果与整表重算逐项相同（`video_library_scrape_maps_test.dart` 钉死）。
/// 没被点名的映射保持原对象不换，下游按 identity 判变的不会白重建。
class VideoLibraryScrapeMaps {
  const VideoLibraryScrapeMaps({
    required this.airYearByUid,
    required this.collectionScrapeMetaById,
    required this.metadataWorkByCollection,
    required this.metadataWorkByBook,
    required this.metadataImagesByWork,
    required this.fileEpisodesByBook,
    required this.runtimeMinutesByBookUid,
    required this.localExtraBookUids,
    required this.mediaImagesByCollection,
    required this.mediaImagesByBookUid,
  });

  /// 还没加载过（首轮整表读取落地前）。
  static const VideoLibraryScrapeMaps empty = VideoLibraryScrapeMaps(
    airYearByUid: <String, int>{},
    collectionScrapeMetaById: <int, CollectionScrapeMetaRow>{},
    metadataWorkByCollection: <int, VideoMetadataWorkRow>{},
    metadataWorkByBook: <String, VideoMetadataWorkRow>{},
    metadataImagesByWork: <int, List<VideoMetadataImageRow>>{},
    fileEpisodesByBook: <String, List<VideoFileEpisodeStills>>{},
    runtimeMinutesByBookUid: <String, int>{},
    localExtraBookUids: <String>{},
    mediaImagesByCollection: <int, List<MediaImageRow>>{},
    mediaImagesByBookUid: <String, List<MediaImageRow>>{},
  );

  /// 条目刮削年份（uid → 年份；无资料不入映射 = 「未知」桶）。
  final Map<String, int> airYearByUid;

  /// 合集刮削资料（hero 轮播的 backdrop / 简介 / airDate）。
  final Map<int, CollectionScrapeMetaRow> collectionScrapeMetaById;

  final Map<int, VideoMetadataWorkRow> metadataWorkByCollection;
  final Map<String, VideoMetadataWorkRow> metadataWorkByBook;
  final Map<int, List<VideoMetadataImageRow>> metadataImagesByWork;

  /// 每个本地视频文件绑定的分集与各集刮削图，只收至少一集带图的文件。
  final Map<String, List<VideoFileEpisodeStills>> fileEpisodesByBook;

  /// 一文件多集（v110）时同一文件有多条分集行：时长按集累加。
  final Map<String, int> runtimeMinutesByBookUid;

  /// 刮削挂上的本地特典。
  final Set<String> localExtraBookUids;

  /// v68 附加图组按归属分桶：合集（hero 背景 / logo、续播行横卡）与散装视频。
  final Map<int, List<MediaImageRow>> mediaImagesByCollection;
  final Map<String, List<MediaImageRow>> mediaImagesByBookUid;

  /// 整表读取：八个查询一次全部发出，交给 Drift 后台执行器流水线化。
  static Future<VideoLibraryScrapeMaps> load(FushiDatabase db) async {
    final Future<List<VideoScrapeMetaRow>> scrapeMetaF = db
        .getAllVideoScrapeMeta();
    final Future<List<CollectionScrapeMetaRow>> collectionScrapeMetaF = db
        .getAllCollectionScrapeMeta();
    final Future<List<VideoMetadataWorkRow>> worksF = db
        .getAllVideoMetadataWorks();
    final Future<List<VideoMetadataImageRow>> imagesF = db
        .getAllVideoMetadataImages();
    final Future<List<VideoMetadataEpisodeRow>> episodesF = db
        .getAllVideoMetadataEpisodes();
    final Future<List<VideoMetadataSeasonRow>> seasonsF = db
        .getAllVideoMetadataSeasons();
    final Future<List<VideoMetadataExtraRow>> extrasF = db
        .getAllVideoMetadataExtras();
    final Future<List<MediaImageRow>> mediaImagesF = db.getAllMediaImages();
    // 先挂上监听再逐个 await：某个查询失败时其余错误不会成为无人接的异常。
    await Future.wait<Object?>(<Future<Object?>>[
      scrapeMetaF,
      collectionScrapeMetaF,
      worksF,
      imagesF,
      episodesF,
      seasonsF,
      extrasF,
      mediaImagesF,
    ]);
    final List<VideoMetadataImageRow> images = await imagesF;
    return VideoLibraryScrapeMaps.fromRows(
      scrapeMeta: await scrapeMetaF,
      collectionScrapeMeta: await collectionScrapeMetaF,
      works: await worksF,
      workImages: images,
      episodes: await episodesF,
      seasons: await seasonsF,
      episodeImages: images,
      extras: await extrasF,
      mediaImages: await mediaImagesF,
    );
  }

  /// 由行建全部映射。[workImages] / [episodeImages] 可以是同一份全表图片：前者只看
  /// `work_id`，后者只看 `episode_id`。
  factory VideoLibraryScrapeMaps.fromRows({
    required List<VideoScrapeMetaRow> scrapeMeta,
    required List<CollectionScrapeMetaRow> collectionScrapeMeta,
    required List<VideoMetadataWorkRow> works,
    required List<VideoMetadataImageRow> workImages,
    required List<VideoMetadataEpisodeRow> episodes,
    required List<VideoMetadataSeasonRow> seasons,
    required List<VideoMetadataImageRow> episodeImages,
    required List<VideoMetadataExtraRow> extras,
    required List<MediaImageRow> mediaImages,
  }) {
    final _FileEpisodes fileEpisodes = _buildFileEpisodes(
      episodes,
      seasons,
      episodeImages,
    );
    final _MediaImageBuckets buckets = _bucketMediaImages(mediaImages);
    return VideoLibraryScrapeMaps(
      airYearByUid: _buildAirYears(scrapeMeta),
      collectionScrapeMetaById: buildCollectionScrapeMetaById(
        collectionScrapeMeta,
      ),
      metadataWorkByCollection: buildVideoWorksByCollection(works),
      metadataWorkByBook: _buildWorksByBook(works),
      metadataImagesByWork: _buildImagesByWork(workImages),
      fileEpisodesByBook: fileEpisodes.byBook,
      runtimeMinutesByBookUid: fileEpisodes.runtimeMinutes,
      localExtraBookUids: videoLocalExtraBookUids(extras),
      mediaImagesByCollection: buckets.byCollection,
      mediaImagesByBookUid: buckets.byBook,
    );
  }

  /// 按 [delta] 点名的键重读回来的 [rows] 替换这些键，其余原样保留。
  VideoLibraryScrapeMaps patched(
    VideoScrapePresentationDelta delta,
    VideoScrapePresentationRows rows,
  ) {
    final Set<String> books = delta.bookUids;
    final Set<int> collections = delta.collectionIds;
    final _FileEpisodes fileEpisodes = books.isEmpty
        ? const _FileEpisodes.none()
        : _buildFileEpisodes(rows.episodes, rows.seasons, rows.episodeImages);
    final _MediaImageBuckets buckets = _bucketMediaImages(rows.mediaImages);
    return VideoLibraryScrapeMaps(
      airYearByUid: _replaceKeys(
        airYearByUid,
        books,
        () => _buildAirYears(rows.scrapeMeta),
      ),
      collectionScrapeMetaById: _replaceKeys(
        collectionScrapeMetaById,
        collections,
        () => buildCollectionScrapeMetaById(rows.collectionScrapeMeta),
      ),
      metadataWorkByCollection: _replaceKeys(
        metadataWorkByCollection,
        collections,
        () => buildVideoWorksByCollection(rows.works),
      ),
      metadataWorkByBook: _replaceKeys(
        metadataWorkByBook,
        books,
        () => _buildWorksByBook(rows.works),
      ),
      metadataImagesByWork: _replaceKeys(
        metadataImagesByWork,
        delta.workIds,
        () => _buildImagesByWork(rows.workImages),
      ),
      fileEpisodesByBook: _replaceKeys(
        fileEpisodesByBook,
        books,
        () => fileEpisodes.byBook,
      ),
      runtimeMinutesByBookUid: _replaceKeys(
        runtimeMinutesByBookUid,
        books,
        () => fileEpisodes.runtimeMinutes,
      ),
      localExtraBookUids: books.isEmpty
          ? localExtraBookUids
          : <String>{
              ...localExtraBookUids.where((String uid) => !books.contains(uid)),
              ...videoLocalExtraBookUids(
                rows.extras,
              ).where((String uid) => books.contains(uid)),
            },
      mediaImagesByCollection: _replaceKeys(
        mediaImagesByCollection,
        collections,
        () => buckets.byCollection,
      ),
      mediaImagesByBookUid: _replaceKeys(
        mediaImagesByBookUid,
        books,
        () => buckets.byBook,
      ),
    );
  }
}

/// 书架行按 uid 换成重读回来的新行（不再存在的删掉），其余行与顺序不动。
List<VideoBookRow> mergeVideoShelfRows(
  List<VideoBookRow> base,
  List<VideoBookRow> fresh,
  Set<String> bookUids,
) {
  final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
    for (final VideoBookRow row in fresh) row.bookUid: row,
  };
  return <VideoBookRow>[
    for (final VideoBookRow row in base)
      if (!bookUids.contains(row.bookUid))
        row
      else if (byUid[row.bookUid] case final VideoBookRow replaced)
        replaced,
  ];
}

/// [keys] 为空 → 原对象；否则复制一份，删掉 [keys] 再放回 [fresh] 里属于 [keys] 的项。
Map<K, V> _replaceKeys<K, V>(
  Map<K, V> base,
  Set<K> keys,
  Map<K, V> Function() fresh,
) {
  if (keys.isEmpty) return base;
  final Map<K, V> out = Map<K, V>.of(base)
    ..removeWhere((K key, V _) => keys.contains(key));
  for (final MapEntry<K, V> entry in fresh().entries) {
    if (keys.contains(entry.key)) out[entry.key] = entry.value;
  }
  return out;
}

Map<String, int> _buildAirYears(List<VideoScrapeMetaRow> rows) => <String, int>{
  for (final VideoScrapeMetaRow r in rows)
    if (videoAirYear(r.airDate) case final int year) r.bookUid: year,
};

/// 合集刮削元数据按合集 id 索引。
Map<int, CollectionScrapeMetaRow> buildCollectionScrapeMetaById(
  List<CollectionScrapeMetaRow> rows,
) => <int, CollectionScrapeMetaRow>{
  for (final CollectionScrapeMetaRow r in rows) r.collectionId: r,
};

/// 刮削作品按所属合集 id 索引（只收挂在合集上的作品）。
Map<int, VideoMetadataWorkRow> buildVideoWorksByCollection(
  List<VideoMetadataWorkRow> works,
) => <int, VideoMetadataWorkRow>{
  for (final VideoMetadataWorkRow work in works)
    if (work.collectionId case final int collectionId) collectionId: work,
};

Map<String, VideoMetadataWorkRow> _buildWorksByBook(
  List<VideoMetadataWorkRow> works,
) => <String, VideoMetadataWorkRow>{
  for (final VideoMetadataWorkRow work in works)
    if (work.bookUid case final String bookUid) bookUid: work,
};

Map<int, List<VideoMetadataImageRow>> _buildImagesByWork(
  List<VideoMetadataImageRow> images,
) {
  final Map<int, List<VideoMetadataImageRow>> out =
      <int, List<VideoMetadataImageRow>>{};
  for (final VideoMetadataImageRow image in images) {
    if (image.workId case final int workId) {
      (out[workId] ??= <VideoMetadataImageRow>[]).add(image);
    }
  }
  return out;
}

class _FileEpisodes {
  const _FileEpisodes(this.byBook, this.runtimeMinutes);

  const _FileEpisodes.none()
    : byBook = const <String, List<VideoFileEpisodeStills>>{},
      runtimeMinutes = const <String, int>{};

  final Map<String, List<VideoFileEpisodeStills>> byBook;
  final Map<String, int> runtimeMinutes;
}

/// 每个文件绑定的全部分集（含没有剧照的——一文件多集时按片长定位续播点要完整
/// 的集序），主卡渲染时按续播点挑那一集的剧照；没有任何一集带图的文件不进表。
_FileEpisodes _buildFileEpisodes(
  List<VideoMetadataEpisodeRow> episodes,
  List<VideoMetadataSeasonRow> seasons,
  List<VideoMetadataImageRow> images,
) {
  final Map<int, List<VideoMetadataImageRow>> imagesByEpisode =
      <int, List<VideoMetadataImageRow>>{};
  for (final VideoMetadataImageRow image in images) {
    if (image.episodeId case final int episodeId) {
      (imagesByEpisode[episodeId] ??= <VideoMetadataImageRow>[]).add(image);
    }
  }
  final Map<int, int> seasonNumberById = <int, int>{
    for (final VideoMetadataSeasonRow season in seasons)
      season.id: season.seasonNumber,
  };
  final Map<String, List<VideoFileEpisodeStills>> byBook =
      <String, List<VideoFileEpisodeStills>>{};
  final Map<String, int> runtimeMinutes = <String, int>{};
  for (final VideoMetadataEpisodeRow episode in episodes) {
    final String? uid = episode.bookUid;
    if (uid == null) continue;
    (byBook[uid] ??= <VideoFileEpisodeStills>[]).add(
      VideoFileEpisodeStills(
        episodeId: episode.id,
        seasonNumber: seasonNumberById[episode.seasonId],
        episodeNumber: episode.episodeNumber,
        runtimeMinutes: episode.runtimeMinutes,
        stills: imagesByEpisode[episode.id] ?? const <VideoMetadataImageRow>[],
      ),
    );
    if (episode.runtimeMinutes case final int minutes) {
      runtimeMinutes[uid] = (runtimeMinutes[uid] ?? 0) + minutes;
    }
  }
  byBook.removeWhere(
    (String _, List<VideoFileEpisodeStills> list) =>
        !list.any((VideoFileEpisodeStills ep) => ep.stills.isNotEmpty),
  );
  return _FileEpisodes(byBook, runtimeMinutes);
}

class _MediaImageBuckets {
  const _MediaImageBuckets(this.byCollection, this.byBook);

  final Map<int, List<MediaImageRow>> byCollection;
  final Map<String, List<MediaImageRow>> byBook;
}

/// 有 collection_id 的归合集；否则按 book_uid 归散装视频。
_MediaImageBuckets _bucketMediaImages(List<MediaImageRow> rows) {
  final Map<int, List<MediaImageRow>> byCollection =
      <int, List<MediaImageRow>>{};
  final Map<String, List<MediaImageRow>> byBook =
      <String, List<MediaImageRow>>{};
  for (final MediaImageRow row in rows) {
    final int? cid = row.collectionId;
    if (cid != null) {
      (byCollection[cid] ??= <MediaImageRow>[]).add(row);
    } else if (row.bookUid case final String uid) {
      (byBook[uid] ??= <MediaImageRow>[]).add(row);
    }
  }
  return _MediaImageBuckets(byCollection, byBook);
}

/// 刮削认定为特典的本地视频（不进继续观看）。
Set<String> videoLocalExtraBookUids(List<VideoMetadataExtraRow> extras) =>
    <String>{
      for (final VideoMetadataExtraRow extra in extras)
        if (extra.bookUid case final String bookUid) bookUid,
    };

/// 合集卡 / 继续观看上显示的作品名：刮削作品标题 → 合集刮削元数据标题 → 合集名。
/// 视频首页与侧栏速览同一条回落链（BUG-5276）。
String videoCollectionWorkTitle(
  MediaCollectionRow collection, {
  required Map<int, VideoMetadataWorkRow> metadataWorkByCollection,
  required Map<int, CollectionScrapeMetaRow> collectionScrapeMetaById,
}) =>
    metadataWorkByCollection[collection.id]?.title ??
    collectionScrapeMetaById[collection.id]?.title ??
    collection.name;
