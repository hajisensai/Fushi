import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_sidecar_artifact_store.dart';
import 'package:fushi_engine/media/video/scraper/sidecar_scanner.dart'
    show SidecarGeneratedArtifactChecker;

/// 合集竖版封面「自有层」的唯一解析点。
///
/// 优先级：合集自有封面（`MediaCollections.coverPath`：用户手选 / 下载导入写的
/// 作品海报）→ 原盘竖版盘面图（`media_images` 的 [MediaImageKind.discCover]）→
/// 调用方自己的后续回退（刮削作品海报、成员借用链……）。
///
/// 盘面图单独登记、不写进 `coverPath`（PR #2606 审查）：写进去它就和用户手选分
/// 不开——清封面后下次扫描又写回、刮削覆盖判据把它当手选永远不换、谁先跑结果
/// 不同。分开存以后两条写入互不覆盖，谁先谁后由这里的优先级统一裁决。
///
/// 返回按优先级排列的非空候选路径；调用方取第一个**文件存在**的（悬空路径——
/// 备份恢复带来的、被删掉的——必须表现得像没有这一层）。[images] 是该合集的附加
/// 图组（库页一次全表预取后分桶的那份），null 视同空。
List<String> collectionOwnCoverCandidates(
  MediaCollectionRow collection,
  Iterable<MediaImageRow>? images,
) => <String>[
  if (collection.coverPath case final String own when own.isNotEmpty) own,
  if (collectionDiscCoverPath(images) case final String disc) disc,
];

/// 该合集的原盘竖版盘面图路径（[MediaImageKind.discCover]），没有为 null。
String? collectionDiscCoverPath(Iterable<MediaImageRow>? images) {
  for (final MediaImageRow row in images ?? const <MediaImageRow>[]) {
    if (row.kind == MediaImageKind.discCover.dbValue && row.path.isNotEmpty) {
      return row.path;
    }
  }
  return null;
}

/// 候选里第一张文件存在的（async stat，不阻塞 UI isolate）；都不在为 null。
Future<String?> firstExistingCoverPath(Iterable<String> candidates) async {
  for (final String path in candidates) {
    if (await File(path).exists()) return path;
  }
  return null;
}

/// [collectionOwnCoverCandidates] 的单合集查库版（不在库页批量预取里的调用方用）。
Future<List<String>> loadCollectionOwnCoverCandidates(
  FushiDatabase db,
  MediaCollectionRow collection,
) async => collectionOwnCoverCandidates(
  collection,
  await db.getMediaImagesForCollection(collection.id),
);

/// 刮削把作品海报写进合集自有层（`coverPath`）的唯一入口：只在自有层空着或
/// 是未被改动的刮削生成图（[SidecarGeneratedArtifactChecker]，`video_sidecar_
/// artifacts` 登记且 sha256 一致）时写——用户手选 / 导入海报 / 改过的图结构性
/// 不被覆盖。合集登记了原盘竖版盘面图时刮削海报排在它后面，不占自有层（原先占着
/// 的刮削图也退出）。调用方须已持有封面写互斥（`VideoCoverMutationGate`）。
Future<void> applyScrapedCollectionCover(
  FushiDatabase db,
  int collectionId,
  String scrapedCoverPath, {
  required SidecarGeneratedArtifactChecker generated,
}) async {
  final MediaCollectionRow? current = await db.getMediaCollectionById(
    collectionId,
  );
  if (current == null) return;
  final String? own = current.coverPath;
  if (own != null && !await generated.isUnmodifiedGeneratedArtifact(own)) {
    return;
  }
  final String? next = await collectionHasDiscCover(db, collectionId)
      ? null
      : scrapedCoverPath;
  if (next != own) await db.updateMediaCollectionCoverPath(collectionId, next);
}

/// 登记原盘竖版盘面图之后调用：`coverPath` 里未被改动的刮削生成图退出自有层
/// （置 null），否则它会按「自有封面」压过盘面图；用户手选 / 导入海报 / 改过的
/// 图一概不动。与 [applyScrapedCollectionCover] 是同一条规则的两个入口——先刮削
/// 后扫描走这里、先扫描后刮削走那里，终态相同。调用方须已持有封面写互斥。返回
/// 是否清了。
Future<bool> yieldGeneratedCollectionCoverToDiscCover(
  FushiDatabase db,
  int collectionId, {
  SidecarGeneratedArtifactChecker? generated,
}) async {
  final MediaCollectionRow? collection = await db.getMediaCollectionById(
    collectionId,
  );
  final String? own = collection?.coverPath;
  if (own == null || own.isEmpty) return false;
  if (!await collectionHasDiscCover(db, collectionId)) return false;
  if (!await (generated ?? DatabaseSidecarGeneratedArtifactChecker(db))
      .isUnmodifiedGeneratedArtifact(own)) {
    return false;
  }
  await db.updateMediaCollectionCoverPath(collectionId, null);
  return true;
}

/// 该合集是否登记了原盘竖版盘面图。
Future<bool> collectionHasDiscCover(FushiDatabase db, int collectionId) async =>
    collectionDiscCoverPath(
      await db.getMediaImagesForCollection(collectionId),
    ) !=
    null;
