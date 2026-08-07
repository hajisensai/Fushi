/// 存量子篇作品海报清理（BUG-1393 ③；用户 2026-08-02 的第三段：闸住新的还不够，
/// 已经被刷上竖版海报的子篇不回退，用户开 app 看到的还是坏的）。
///
/// 判据（[planMemberCoverCleanup]）是**无 IO 的纯函数**，落地（[runMemberCoverCleanup]）
/// 与它分开：这样**误删方向**（多清了别人的）可以被穷举断言——非子篇、单成员合集、用户
/// 手选/sidecar/来源不明的存量封面、抽帧封面、指向自有目录之外的封面，全部必须
/// 不出现在计划里。
///
/// 安全边界（每一条都是「不该动的绝不动」）：
/// * **只认 [CoverOrigin.autoScraped]**——它是当前代码里**唯一**由自动刮削写下
///   作品海报时打的标记。`manual` / `userScraped` / `sidecar` 是用户亲自定的
///   （BUG-1325 的红线），`scraped` 是来源不明的存量（分不清是自动刮的还是用户
///   在旧版本弹窗里选的，按 [CoverOverwritePolicy.legacyStrict] 同样保守放过），
///   `autoFrame` / 无记录本来就是我们想保留的抽帧缩略图。
/// * **路径只来自被清那一行自己的 `coverPath` 字段**：不枚举目录、不按 uid 猜
///   文件名——猜出来的路径可能是别人的封面。
/// * **必须严格落在自有封面目录的第一层**（`p.isWithin` + 直接父目录相等）：目录
///   外 = 用户自己放的图，`collections/` 子目录 = 合集自有封面，两者都在射程外。
/// * **不删文件**：只清 DB 列 + `cover_meta.json` 记录，孤儿文件由既有
///   `VideoStorage.gcOrphanCovers` 回收（它保留全库 `video_books.cover_path`、且
///   非递归所以 `collections/` 天然免疫）。少一个删除动作就少一整类误删。
library;

import 'dart:io';

import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart'
    show CoverMeta, CoverOrigin;
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_cover_extractor.dart'
    show videoCoverFileName;
import 'package:fushi/src/media/video/video_storage.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart'
    show MediaCollectionRow, VideoBookRow;
import 'package:path/path.dart' as p;

/// 一条存量清理动作：把 [bookUid] 这个子篇身上的作品海报摘掉。
class MemberCoverCleanup {
  const MemberCoverCleanup({
    required this.bookUid,
    required this.collectionId,
    required this.coverPath,
    required this.promoteToCollection,
  });

  /// 要摘掉封面的子篇条目。
  final String bookUid;

  /// 它所属的多成员合集（海报的正确归宿）。
  final int collectionId;

  /// 该子篇当前的封面绝对路径（**规范化后**，取自它自己的 `coverPath` 列）。
  final String coverPath;

  /// 是否把这张海报升格成 [collectionId] 的自有封面。
  ///
  /// 合集还没有自有封面时为 true（每个合集只有第一顺位成员升格，其余成员只清
  /// 自己那一列）——用户要的是「海报归合集」，不是「海报消失」。合集已有自有
  /// 封面（用户设的或刮过的）时为 false：绝不覆盖。
  final bool promoteToCollection;

  @override
  String toString() => 'MemberCoverCleanup($bookUid → collection $collectionId,'
      ' promote=$promoteToCollection)';
}

/// 算出存量清理计划。全部入参都是快照，函数本身无 IO、可穷举断言。
///
/// * [multiMemberCollectionIdByVideoUid]：子篇 → 所属多成员合集 id
///   （`multiMemberCollectionIdByVideoUid` 的结果）。
/// * [coverMetaByUid]：`cover_meta.json` 全量快照（`CoverMetaStore.all()`）。
/// * [coverPathByUid]：全库视频条目的当前 `coverPath`。
/// * [collectionsWithOwnCover]：已经有自有封面（`coverPath` 非空）的合集 id。
/// * [coversDirectoryPath]：成员封面目录（`VideoStorage.coversDir()`）。
///
/// 返回按 bookUid 升序的稳定计划（同一合集只有排序最前的成员会 promote）。
List<MemberCoverCleanup> planMemberCoverCleanup({
  required Map<String, int> multiMemberCollectionIdByVideoUid,
  required Map<String, CoverMeta> coverMetaByUid,
  required Map<String, String?> coverPathByUid,
  required Set<int> collectionsWithOwnCover,
  required String coversDirectoryPath,
}) {
  final String coversDir = p.normalize(coversDirectoryPath);
  final Set<int> promoted = <int>{...collectionsWithOwnCover};
  final List<String> uids = multiMemberCollectionIdByVideoUid.keys.toList()
    ..sort();

  final List<MemberCoverCleanup> plan = <MemberCoverCleanup>[];
  for (final String uid in uids) {
    // ① 只清自动刮削打下的作品海报标记；其余来源（用户的 / 来源不明的存量 /
    //    抽帧）一律放过。无记录 = 视同 autoFrame，同样放过。
    if (coverMetaByUid[uid]?.origin != CoverOrigin.autoScraped) continue;

    // ② 路径只来自这一行自己的字段。
    final String? raw = coverPathByUid[uid];
    if (raw == null || raw.isEmpty) continue;
    final String normalized = p.normalize(raw);

    // ③ 必须是自有封面目录**第一层**里的文件：目录外是用户自己的图，
    //    `collections/` 子目录是合集自有封面，两者都不许碰。
    if (!p.isWithin(coversDir, normalized)) continue;
    if (!p.equals(p.dirname(normalized), coversDir)) continue;

    final int collectionId = multiMemberCollectionIdByVideoUid[uid]!;
    plan.add(MemberCoverCleanup(
      bookUid: uid,
      collectionId: collectionId,
      coverPath: normalized,
      promoteToCollection: promoted.add(collectionId),
    ));
  }
  return plan;
}

/// 跑一遍存量清理并落地（判据见 [planMemberCoverCleanup]）。返回清理条数。
///
/// 逐条两步：
/// 1. `promoteToCollection` 的那一条把海报**升格**成合集自有封面（走统一收口
///    [MediaCoverService.applyCoverFile]：原子 `.tmp`+rename + 双键驱逐）——用户
///    要的是「作品海报归合集封面」，不是「作品海报消失」；
/// 2. 清成员 `cover_path` 列 + 删它的 `cover_meta.json` 记录（回落到「无记录 =
///    autoFrame」，视频页的 `_maybeBackfillCovers` 下一轮会补一张真正的抽帧图）。
///
/// 单条失败只记日志继续：判据幂等，下次进页面重跑。
///
/// [coversDirectory] / [collectionCoversDirectory] 是测试接缝，默认生产目录。
Future<int> runMemberCoverCleanup({
  required VideoBookRepository repo,
  CoverMetaStore? coverMetaStore,
  Directory? coversDirectory,
  Directory? collectionCoversDirectory,
}) async {
  final Map<String, int> memberCollectionIds =
      await repo.multiMemberCollectionIds();
  if (memberCollectionIds.isEmpty) return 0;

  final Directory covers = coversDirectory ?? await VideoStorage.coversDir();
  final CoverMetaStore coverMeta = coverMetaStore ?? CoverMetaStore(covers);
  final List<VideoBookRow> books = await repo.listAll();
  final List<MediaCollectionRow> collections =
      await repo.getAllMediaCollections();

  final List<MemberCoverCleanup> plan = planMemberCoverCleanup(
    multiMemberCollectionIdByVideoUid: memberCollectionIds,
    coverMetaByUid: await coverMeta.all(),
    coverPathByUid: <String, String?>{
      for (final VideoBookRow b in books) b.bookUid: b.coverPath,
    },
    collectionsWithOwnCover: <int>{
      for (final MediaCollectionRow c in collections)
        if ((c.coverPath ?? '').isNotEmpty) c.id,
    },
    coversDirectoryPath: covers.path,
  );
  if (plan.isEmpty) return 0;

  final Directory collectionCovers =
      collectionCoversDirectory ?? await VideoStorage.collectionCoversDir();
  int cleaned = 0;
  for (final MemberCoverCleanup action in plan) {
    try {
      if (action.promoteToCollection) {
        final File source = File(action.coverPath);
        if (await source.exists()) {
          await collectionCovers.create(recursive: true);
          final String destPath = p.join(
            collectionCovers.path,
            videoCoverFileName('${action.collectionId}'),
          );
          await MediaCoverService.applyCoverFile(
            source: source,
            destPath: destPath,
          );
          await repo.updateMediaCollectionCoverPath(
            action.collectionId,
            destPath,
          );
        }
      }
      await repo.clearCover(action.bookUid);
      await coverMeta.remove(action.bookUid);
      cleaned++;
    } catch (e, stack) {
      ErrorLogService.instance.log('runMemberCoverCleanup', e, stack);
    }
  }
  return cleaned;
}
