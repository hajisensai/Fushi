import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/video_local_extra_classifier.dart';
import 'package:fushi/src/media/video/scraper/collection_member_policy.dart'
    show multiMemberCollectionIdByVideoUid;
import 'package:fushi/src/media/video/video_filename_parser.dart';
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

  final SourceLibraryRow source;
  final MediaCollectionRow? collection;
  final String title;
  final List<VideoBookRow> members;

  bool get isEpisodic => collection != null;

  String get stableKey => collection == null
      ? 'book:${members.single.bookUid}'
      : 'collection:${collection!.id}';
}

/// 从已入库的 `sourceId` 与合集成员关系生成按作品去重的刮削计划。
class VideoSourceWorkPlanner {
  const VideoSourceWorkPlanner(this._database);

  final FushiDatabase _database;

  Future<List<VideoSourceScrapeWork>> plan(SourceLibraryRow source) async {
    if (source.mediaKind != 'video') return const <VideoSourceScrapeWork>[];

    final List<VideoBookRow> sourceBooks = (await _database.allVideoBooks())
        .where((VideoBookRow row) => row.sourceId == source.id)
        .toList();
    if (sourceBooks.isEmpty) return const <VideoSourceScrapeWork>[];

    final List<MediaCollectionItemRow> allItems =
        await _database.getAllCollectionItems();
    final Map<String, int> primaryCollections =
        multiMemberCollectionIdByVideoUid(allItems);
    final Map<int, MediaCollectionRow> collections = <int, MediaCollectionRow>{
      for (final MediaCollectionRow row
          in await _database.getAllMediaCollections())
        row.id: row,
    };
    final Map<int, List<VideoBookRow>> grouped = <int, List<VideoBookRow>>{};
    final List<VideoSourceScrapeWork> result = <VideoSourceScrapeWork>[];

    for (final VideoBookRow book in sourceBooks) {
      // NCOP/NCED/预告/花絮仍是 VideoBook，继续出现在“全部视频”；但它们不是
      // 可独立识别的作品，不能让一次来源刮削多出四个必失败任务。
      if (classifyLocalVideoExtra(book.videoPath) != null) continue;
      final int? collectionId = primaryCollections[book.bookUid];
      final VideoNameInfo parsed =
          parseVideoFilename(p.basename(book.videoPath));
      if (collectionId == null ||
          collections[collectionId] == null ||
          parsed.episode == null) {
        result.add(VideoSourceScrapeWork(
          source: source,
          title: book.title,
          members: <VideoBookRow>[book],
        ));
        continue;
      }
      grouped.putIfAbsent(collectionId, () => <VideoBookRow>[]).add(book);
    }

    for (final MapEntry<int, List<VideoBookRow>> entry in grouped.entries) {
      final MediaCollectionRow collection = collections[entry.key]!;
      entry.value.sort((VideoBookRow a, VideoBookRow b) =>
          a.videoPath.toLowerCase().compareTo(b.videoPath.toLowerCase()));
      result.add(VideoSourceScrapeWork(
        source: source,
        collection: collection,
        title: collection.name,
        members: List<VideoBookRow>.unmodifiable(entry.value),
      ));
    }

    result.sort((VideoSourceScrapeWork a, VideoSourceScrapeWork b) {
      final int byTitle =
          a.title.toLowerCase().compareTo(b.title.toLowerCase());
      if (byTitle != 0) return byTitle;
      return a.stableKey.compareTo(b.stableKey);
    });
    return List<VideoSourceScrapeWork>.unmodifiable(result);
  }
}
