/// 删除一部作品时「跟着它走」的附属视频行（fuQcFmZZxb / BUG-3802）。
///
/// 用户在视频库里删「一部动漫」，删除集合是**合集成员**（正片各集）。但同一部作品
/// 名下还有两类不是合集成员的视频行：
/// 1. **本地特典**：来源扫描把 `Extras/`、`SPs/`、NCOP 等附件也建成视频行，再由
///    元数据索引器绑成作品的 `video_metadata_extras`（`source_kind = 'local'`），
///    作品页「特典」一栏就是它们。它们不在合集里；
/// 2. **下载整理产物**：整理器把种子里的特典镜像进 `<作品>/Extras/`，任务文件行记成
///    `kind: 'extra'` + `finalAbsolutePath`。
///
/// 只删合集成员 = 正片没了、特典行和特典文件原样留在库里与磁盘上。这里把「作品被
/// 整体删除」时它名下的附属行找出来，交给同一条删除链（行、app 副本、勾了「同时
/// 删除本地文件」时连原件）一起删。
///
/// 「整体删除」的判据刻意保守——只删一部分集时附属行一条不碰：
/// - 电影作品：`video_metadata_works.book_uid` 在删除集合里；
/// - 剧集作品：绑定合集的**每个**视频成员都在删除集合里；
/// - 下载任务：任务记过的**每条** `kind: 'video'` 行（本作正片 + 同包并列作品）的
///   落盘路径都是被删行的视频文件。并列作品还在库里时任务不算被整体删除，它的
///   特典也不碰。
library;

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_local_files.dart'
    show localVideoFileCandidates;

/// 删除 [bookUids] 时应一并删除的附属视频行 uid（不含 [bookUids] 自身，去重，
/// 顺序稳定）。纯查询，不写库。
Future<List<String>> videoWorkCompanionBookUids(
  FushiDatabase database,
  Iterable<String> bookUids,
) async {
  final Set<String> deleting = bookUids.toSet();
  if (deleting.isEmpty) return const <String>[];
  final Set<String> out = <String>{};

  // ① 作品被整体删除 → 它绑定的本地特典行。
  final List<VideoMetadataWorkRow> works = await database
      .select(database.videoMetadataWorks)
      .get();
  // 成员表一次读完按合集分组：逐作品查成员会让每次删除都是「作品数」次查询。
  final Map<int, List<String>> videoMembersByCollection = <int, List<String>>{};
  for (final MediaCollectionItemRow item
      in await database.select(database.mediaCollectionItems).get()) {
    if (MediaKind.tryParse(item.mediaType) != MediaKind.video) continue;
    (videoMembersByCollection[item.collectionId] ??= <String>[]).add(
      item.entryKey,
    );
  }
  final Set<int> deletedWorkIds = <int>{};
  for (final VideoMetadataWorkRow work in works) {
    final String? movieUid = work.bookUid;
    if (movieUid != null && deleting.contains(movieUid)) {
      deletedWorkIds.add(work.id);
      continue;
    }
    final int? collectionId = work.collectionId;
    if (collectionId == null) continue;
    final List<String> members =
        videoMembersByCollection[collectionId] ?? const <String>[];
    if (members.isNotEmpty && members.every(deleting.contains)) {
      deletedWorkIds.add(work.id);
    }
  }
  if (deletedWorkIds.isNotEmpty) {
    final List<VideoMetadataExtraRow> extras =
        await (database.select(database.videoMetadataExtras)..where(
              ($VideoMetadataExtrasTable t) =>
                  t.workId.isIn(deletedWorkIds) &
                  t.sourceKind.equals('local') &
                  t.bookUid.isNotNull(),
            ))
            .get();
    for (final VideoMetadataExtraRow extra in extras) {
      out.add(extra.bookUid!);
    }
  }

  // ② 下载任务的视频产物被整体删除 → 任务记过的附件（`kind: 'extra'`）对应的行。
  final List<VideoBookRow> library = await database.allVideoBooks();
  final Map<String, String> uidByPathKey = <String, String>{};
  final Set<String> deletingPathKeys = <String>{};
  for (final VideoBookRow row in library) {
    for (final String path in localVideoFileCandidates(
      videoPath: row.videoPath,
      playlistJson: row.playlistJson,
    )) {
      final String key = platformPathKey(path);
      uidByPathKey.putIfAbsent(key, () => row.bookUid);
      if (deleting.contains(row.bookUid)) deletingPathKeys.add(key);
    }
  }
  if (deletingPathKeys.isNotEmpty) {
    for (final VideoDownloadJobRow job
        in await database.getVideoDownloadJobs()) {
      final List<VideoDownloadJobFileRow> files = await database
          .getVideoDownloadJobFiles(job.jobId);
      String? keyOf(VideoDownloadJobFileRow file) {
        final String path = file.finalAbsolutePath?.trim() ?? '';
        return path.isEmpty ? null : platformPathKey(path);
      }

      final List<VideoDownloadJobFileRow> videos = <VideoDownloadJobFileRow>[
        for (final VideoDownloadJobFileRow file in files)
          if (file.kind == 'video') file,
      ];
      // 没记路径的视频行判不出指向哪，不能拿它当「整体删除」的依据。
      final bool wholeJobDeleted =
          videos.isNotEmpty &&
          videos.every((VideoDownloadJobFileRow file) {
            final String? key = keyOf(file);
            return key != null && deletingPathKeys.contains(key);
          });
      if (!wholeJobDeleted) continue;
      for (final VideoDownloadJobFileRow file in files) {
        if (file.kind != 'extra') continue;
        final String? key = keyOf(file);
        final String? uid = key == null ? null : uidByPathKey[key];
        if (uid != null) out.add(uid);
      }
    }
  }

  return <String>[
    for (final String uid in out)
      if (!deleting.contains(uid)) uid,
  ];
}
