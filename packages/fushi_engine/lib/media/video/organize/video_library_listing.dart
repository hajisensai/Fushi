/// 全库视频文件的联表清单：每个本机视频文件属于哪部作品、那部作品被认成什么、
/// 文件绑在第几季第几集、多长、在哪。
///
/// 起因（所有者 2026-11-20：「为什么不直接让 ai 看？」）：AI 助手原先只能逐部作品
/// 打开看，几百部作品一轮看不完；而「哪些文件放错了」这类问题要把作品、季、集、
/// 文件路径、时长联起来才看得出。这里一次查询给出联表结果，筛选与分页由宿主做。
///
/// 只读；时长取已有的规格缓存（不现探——全库现探是分钟级的事，要判断的那些文件
/// 由 `auditVideoPlacement` 现探）。
///
/// 纯 Dart（不 import flutter / 插件 / `package:fushi`）。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/organize/video_work_regroup.dart'
    show primaryVideoWorkCollections;

/// 清单里的一个文件。
class VideoLibraryFile {
  const VideoLibraryFile({
    required this.bookUid,
    required this.title,
    required this.videoPath,
    required this.workId,
    required this.minutes,
    required this.workTitle,
    required this.mediaType,
    required this.slots,
  });

  final String bookUid;
  final String title;

  /// 绝对路径（宿主输出前换成相对来源库根的）。
  final String videoPath;

  /// 所属作品单元：`collection:<id>` / `book:<uid>`。
  final String workId;
  final int? minutes;

  /// 作品的刮削标题与形态（`tv` / `movie`）；null = 这部作品还没认出身份。
  final String? workTitle;
  final String? mediaType;

  /// 绑到的集位（季号, 集号），按季集排序；空 = 没绑到任何一集。
  final List<(int, int)> slots;

  bool get isUnbound => slots.isEmpty;
}

/// 全库清单，按作品单元、再按路径排序（同一部作品的文件挨在一起）。
Future<List<VideoLibraryFile>> listVideoLibraryFiles(FushiDatabase db) async {
  final List<VideoBookRow> books = await db.allVideoBooks();
  final Map<String, int> collectionOf = await primaryVideoWorkCollections(db);
  final Map<String, VideoMetadataWorkRow> workByUnit =
      <String, VideoMetadataWorkRow>{};
  final Map<int, VideoMetadataWorkRow> workById = <int, VideoMetadataWorkRow>{};
  for (final VideoMetadataWorkRow w in await db.getAllVideoMetadataWorks()) {
    workById[w.id] = w;
    final int? collectionId = w.collectionId;
    if (collectionId != null) {
      workByUnit['collection:$collectionId'] = w;
    } else if (w.bookUid != null) {
      workByUnit['book:${w.bookUid}'] = w;
    }
  }
  final Map<int, VideoMetadataSeasonRow> seasonById =
      <int, VideoMetadataSeasonRow>{
        for (final VideoMetadataSeasonRow s
            in await db.getAllVideoMetadataSeasons())
          s.id: s,
      };
  final Map<String, List<(int, int)>> slotsOf = <String, List<(int, int)>>{};
  for (final VideoMetadataEpisodeRow e
      in await db.getAllVideoMetadataEpisodes()) {
    final String? uid = e.bookUid;
    final VideoMetadataSeasonRow? season = seasonById[e.seasonId];
    if (uid == null || season == null) continue;
    slotsOf.putIfAbsent(uid, () => <(int, int)>[]).add((
      season.seasonNumber,
      e.episodeNumber,
    ));
  }
  final Map<String, VideoFileSpecRow> specs = await db.videoFileSpecsByPath(
    <String>{for (final VideoBookRow b in books) b.videoPath},
  );
  final List<VideoLibraryFile> out = <VideoLibraryFile>[
    for (final VideoBookRow b in books)
      () {
        final int? collectionId = collectionOf[b.bookUid];
        final String workId = collectionId == null
            ? 'book:${b.bookUid}'
            : 'collection:$collectionId';
        final VideoMetadataWorkRow? work = workByUnit[workId];
        final int? ms = specs[b.videoPath]?.durationMs;
        return VideoLibraryFile(
          bookUid: b.bookUid,
          title: b.title,
          videoPath: b.videoPath,
          workId: workId,
          minutes: ms == null ? null : (ms / 60000).round(),
          workTitle: work?.title,
          mediaType: work?.mediaType,
          slots: (slotsOf[b.bookUid] ?? <(int, int)>[])
            ..sort(
              ((int, int) a, (int, int) c) =>
                  a.$1 != c.$1 ? a.$1 - c.$1 : a.$2 - c.$2,
            ),
        );
      }(),
  ];
  return out..sort((VideoLibraryFile a, VideoLibraryFile b) {
    final int byWork = a.workId.compareTo(b.workId);
    return byWork != 0 ? byWork : a.videoPath.compareTo(b.videoPath);
  });
}
