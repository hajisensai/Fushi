import 'package:fushi/src/media/video/external_video.dart'
    show normalizeVideoPath;
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 一次文件夹视频分组的可核对结果。
typedef VideoFolderGroupSummary = ({
  List<String> createdVideoUids,
  List<String> reusedVideoUids,
  List<int> createdCollectionIds,
  List<int> updatedCollectionIds,
});

/// 把已经入库的视频路径整理成「作品合集 → 独立分集」。
///
/// 文件发现、字幕解析、封面抽取仍由调用方负责；本类只拥有来源回填、作品/分集归组
/// 与自然顺序这一条数据职责。来源扫描和兼容导入入口因此能共用同一套文件名解析、
/// 合集复用与保守重扫规则，而不复制媒体 IO。
class VideoFolderGroupCoordinator {
  const VideoFolderGroupCoordinator({
    required FushiDatabase database,
    required VideoBookRepository repository,
  })  : _database = database,
        _repository = repository;

  final FushiDatabase _database;
  final VideoBookRepository _repository;

  /// 按现有 [groupVideosIntoPlaylists] 规则归组 [videoPaths]。
  ///
  /// [createdVideoPaths] 是调用方在同一批逐文件入库时真新建的路径，只用于形成准确
  /// 摘要；归组本身始终以数据库中的路径为准。
  ///
  /// - 全新单片不创建合集；命中旧 playlist 的单集重扫会补入旧合集；
  /// - 多集优先复用成员重叠或同作品的 playlist 合集；
  /// - 重扫只补成员并按全集自然顺序整理，不移除本轮未发现的旧成员；
  /// - [sourceId] 非空时，只把尚无来源的复用视频归到当前来源。
  Future<VideoFolderGroupSummary> groupPaths({
    required List<String> videoPaths,
    List<String> createdVideoPaths = const <String>[],
    int? sourceId,
  }) async {
    final Map<String, String> uniquePaths = <String, String>{};
    for (final String path in videoPaths) {
      uniquePaths.putIfAbsent(normalizeVideoPath(path), () => path);
    }
    final List<String> paths = uniquePaths.values.toList()
      ..sort((String a, String b) =>
          normalizeVideoPath(a).compareTo(normalizeVideoPath(b)));
    if (paths.isEmpty) return _emptySummary;

    final Set<String> createdPathKeys =
        createdVideoPaths.map(normalizeVideoPath).toSet();
    List<VideoBookRow> books = await _repository.listAll();
    Map<String, VideoBookRow> booksByPath = <String, VideoBookRow>{
      for (final VideoBookRow row in books)
        normalizeVideoPath(row.videoPath): row,
    };
    final List<String> createdVideoUids = <String>[];
    final List<String> reusedVideoUids = <String>[];
    for (final String path in paths) {
      final VideoBookRow? row = booksByPath[normalizeVideoPath(path)];
      if (row == null) continue;
      if (createdPathKeys.contains(normalizeVideoPath(path))) {
        createdVideoUids.add(row.bookUid);
      } else {
        reusedVideoUids.add(row.bookUid);
      }
      if (sourceId != null && row.sourceId == null) {
        await _repository.assignSourceIfNull(row.bookUid, sourceId);
      }
    }

    // 来源回填后重读，让候选合集的来源判定与数据库一致。
    books = await _repository.listAll();
    booksByPath = <String, VideoBookRow>{
      for (final VideoBookRow row in books)
        normalizeVideoPath(row.videoPath): row,
    };
    final Map<String, VideoBookRow> booksByUid = <String, VideoBookRow>{
      for (final VideoBookRow row in books) row.bookUid: row,
    };

    final List<MediaCollectionRow> collections =
        await _database.getAllMediaCollections();
    final Map<int, List<MediaCollectionItemRow>> itemsByCollection =
        <int, List<MediaCollectionItemRow>>{};
    for (final MediaCollectionItemRow item
        in await _database.getAllCollectionItems()) {
      itemsByCollection
          .putIfAbsent(item.collectionId, () => <MediaCollectionItemRow>[])
          .add(item);
    }

    final List<int> createdCollectionIds = <int>[];
    final List<int> updatedCollectionIds = <int>[];
    for (final VideoGroup group in groupVideosIntoPlaylists(paths)) {
      final List<VideoBookRow> groupRows = <VideoBookRow>[];
      for (final VideoEpisode episode in group.episodes) {
        final VideoBookRow? row = booksByPath[normalizeVideoPath(episode.path)];
        if (row != null) groupRows.add(row);
      }
      if (groupRows.isEmpty) continue;

      final String seriesKey = _seriesKey(group.series);
      final Set<String> groupUids =
          groupRows.map((VideoBookRow row) => row.bookUid).toSet();
      final List<_CollectionCandidate> candidates = <_CollectionCandidate>[];
      for (final MediaCollectionRow collection in collections) {
        if (collection.collectionType != 'playlist') continue;
        int overlap = 0;
        int sameSeriesMembers = 0;
        int sameSourceSeriesMembers = 0;
        for (final MediaCollectionItemRow item
            in itemsByCollection[collection.id] ??
                const <MediaCollectionItemRow>[]) {
          if (item.mediaType != MediaKind.video.dbValue) continue;
          final VideoBookRow? member = booksByUid[item.entryKey];
          if (member == null) continue;
          if (groupUids.contains(member.bookUid)) overlap++;
          if (_seriesKeyForPath(member.videoPath) == seriesKey) {
            sameSeriesMembers++;
            if (sourceId != null && member.sourceId == sourceId) {
              sameSourceSeriesMembers++;
            }
          }
        }
        final bool exactName = _seriesKey(collection.name) == seriesKey;
        final bool eligible = overlap > 0 ||
            sameSeriesMembers > 0 ||
            (exactName && (group.isPlaylist || sourceId != null));
        if (eligible) {
          candidates.add(_CollectionCandidate(
            collection: collection,
            overlap: overlap,
            sameSourceSeriesMembers: sameSourceSeriesMembers,
            sameSeriesMembers: sameSeriesMembers,
            exactName: exactName,
          ));
        }
      }
      candidates.sort(_compareCandidates);

      MediaCollectionRow? collection =
          candidates.isEmpty ? null : candidates.first.collection;
      if (collection == null && !group.isPlaylist) continue;
      bool createdCollection = false;
      if (collection == null) {
        final MediaCollectionRow? natural =
            await _database.getMediaCollectionByNaturalKey(
          group.series,
          'playlist',
        );
        if (natural != null) {
          collection = natural;
        } else {
          // BUG-1739：用户删过的同名 playlist 合集不由重扫复活。没有这道门，
          // 「删除合集（保留条目）」会在成员文件仍在来源目录时被下一次扫描按
          // 自然键原样重建（createMediaCollection 还会清墓碑），删除永远不生效。
          // 成员视频本身照常入库/保留，只是不再被自动归组。
          if (await _database.hasCollectionDeletionTombstone(
            group.series,
            'playlist',
          )) {
            continue;
          }
          final int id = await _database.createMediaCollection(
            group.series,
            collectionType: 'playlist',
          );
          collection = (await _database.getMediaCollectionById(id))!;
          createdCollection = true;
          createdCollectionIds.add(id);
        }
        collections.add(collection);
        itemsByCollection.putIfAbsent(
          collection.id,
          () => <MediaCollectionItemRow>[],
        );
      }

      bool changed = false;
      List<MediaCollectionItemRow> current =
          itemsByCollection[collection.id] ?? <MediaCollectionItemRow>[];
      final Set<String> currentVideoUids = current
          .where((MediaCollectionItemRow item) =>
              item.mediaType == MediaKind.video.dbValue)
          .map((MediaCollectionItemRow item) => item.entryKey)
          .toSet();
      for (final VideoBookRow row in groupRows) {
        if (currentVideoUids.add(row.bookUid)) {
          await _database.addToCollection(
            collection.id,
            MediaKind.video,
            row.bookUid,
          );
          changed = true;
        }
      }

      current = await _database.getCollectionItems(collection.id);
      final List<MediaCollectionItemRow> currentVideos = current
          .where((MediaCollectionItemRow item) =>
              item.mediaType == MediaKind.video.dbValue)
          .toList();
      final List<MediaCollectionItemRow> orderedVideos =
          List<MediaCollectionItemRow>.of(currentVideos)
            ..sort((MediaCollectionItemRow a, MediaCollectionItemRow b) =>
                _compareVideoMembers(a, b, booksByUid));
      final bool orderChanged = !_sameMemberOrder(
        currentVideos,
        orderedVideos,
      );
      if (orderChanged) {
        await _database.reorderCollectionItemsAutomatically(
          collection.id,
          <CollectionMemberKey>[
            for (final MediaCollectionItemRow item in orderedVideos)
              (mediaType: item.mediaType, entryKey: item.entryKey),
          ],
        );
        changed = true;
      }
      itemsByCollection[collection.id] =
          await _database.getCollectionItems(collection.id);
      if (!createdCollection && changed) {
        updatedCollectionIds.add(collection.id);
      }
    }

    return (
      createdVideoUids: List<String>.unmodifiable(createdVideoUids),
      reusedVideoUids: List<String>.unmodifiable(reusedVideoUids),
      createdCollectionIds: List<int>.unmodifiable(createdCollectionIds),
      updatedCollectionIds: List<int>.unmodifiable(updatedCollectionIds),
    );
  }
}

const VideoFolderGroupSummary _emptySummary = (
  createdVideoUids: <String>[],
  reusedVideoUids: <String>[],
  createdCollectionIds: <int>[],
  updatedCollectionIds: <int>[],
);

class _CollectionCandidate {
  const _CollectionCandidate({
    required this.collection,
    required this.overlap,
    required this.sameSourceSeriesMembers,
    required this.sameSeriesMembers,
    required this.exactName,
  });

  final MediaCollectionRow collection;
  final int overlap;
  final int sameSourceSeriesMembers;
  final int sameSeriesMembers;
  final bool exactName;
}

int _compareCandidates(_CollectionCandidate a, _CollectionCandidate b) {
  int result = b.overlap.compareTo(a.overlap);
  if (result != 0) return result;
  result = b.sameSourceSeriesMembers.compareTo(a.sameSourceSeriesMembers);
  if (result != 0) return result;
  result = b.sameSeriesMembers.compareTo(a.sameSeriesMembers);
  if (result != 0) return result;
  if (a.exactName != b.exactName) return a.exactName ? -1 : 1;
  return a.collection.id.compareTo(b.collection.id);
}

int _compareVideoMembers(
  MediaCollectionItemRow a,
  MediaCollectionItemRow b,
  Map<String, VideoBookRow> booksByUid,
) {
  final VideoBookRow? aRow = booksByUid[a.entryKey];
  final VideoBookRow? bRow = booksByUid[b.entryKey];
  if (aRow == null || bRow == null) {
    if (aRow == null && bRow != null) return 1;
    if (aRow != null && bRow == null) return -1;
    return a.entryKey.compareTo(b.entryKey);
  }
  final VideoNameInfo aInfo = parseVideoFilename(p.basename(aRow.videoPath));
  final VideoNameInfo bInfo = parseVideoFilename(p.basename(bRow.videoPath));
  int result = (aInfo.season ?? 1).compareTo(bInfo.season ?? 1);
  if (result != 0) return result;
  result = (aInfo.episode ?? (1 << 30)).compareTo(bInfo.episode ?? (1 << 30));
  if (result != 0) return result;
  result = aRow.title.toLowerCase().compareTo(bRow.title.toLowerCase());
  if (result != 0) return result;
  result = normalizeVideoPath(aRow.videoPath)
      .compareTo(normalizeVideoPath(bRow.videoPath));
  if (result != 0) return result;
  return a.entryKey.compareTo(b.entryKey);
}

bool _sameMemberOrder(
  List<MediaCollectionItemRow> a,
  List<MediaCollectionItemRow> b,
) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i].mediaType != b[i].mediaType || a[i].entryKey != b[i].entryKey) {
      return false;
    }
  }
  return true;
}

String _seriesKeyForPath(String path) =>
    _seriesKey(parseVideoFilename(p.basename(path)).series);

String _seriesKey(String value) => value.trim().toLowerCase();
