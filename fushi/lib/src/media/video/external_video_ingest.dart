/// 「库外的一个本地视频文件 → 视频库一行」的单一入口（不复制文件，`videoPath` 存原路径）。
///
/// 两类调用方共用：app 外打开视频（argv / 单实例转交 / 文件关联 / `fushi_cli`，经
/// `main.dart` 的 `_ingestExternalVideo`，见 docs/agent/external-video-open.md）与音乐库里的
/// 本地 MV「在视频播放页观看」（`music_mv_page.dart` 的 `openMusicTrackVideo`，拍板台
/// jeNKF9u0WJ）。此前这段逻辑只写在 `main.dart` 的私有 State 方法里，别的入口复用不了。
///
/// 模块门、文件存在性、失败提示由调用方各自负责（提示文案与落点不同）；这里只管去重、
/// 自动封面和落库。
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi_core/fushi_core.dart'
    show VideoBookRow, VideoBooksCompanion;
import 'package:fushi_engine/media/video/external_video.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/scraper/cover_meta_store.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart'
    show extractVideoCover;
import 'package:fushi_engine/media/video/video_storage.dart';
import 'package:path/path.dart' as p;

/// [upsertExternalVideoBook] 的结果。
class ExternalVideoUpsert {
  const ExternalVideoUpsert({required this.bookUid, required this.created});

  final String bookUid;

  /// 这次新建了视频库行（false = 同一文件已在库里，复用旧行与进度）。
  final bool created;
}

/// 外部打开新视频时的自动封面锁边界。maintenance 已开始时 [action] 仍可按
/// `allowAutoCover == false` 建立无封面的媒体行，但不得产生自动封面文件。
Future<T> runExternalVideoCoverMutation<T>(
  Future<T> Function(bool allowAutoCover) action,
) async {
  final VideoScrapeOperationLease? lease =
      VideoScrapeOperationGate.tryEnterOperation();
  if (lease == null) return action(false);
  try {
    return await VideoCoverMutationGate.runExclusive<T>(() => action(true));
  } finally {
    lease.release();
  }
}

/// 按路径去重建 / 取一条视频库行。同一物理文件已库内导入（任何 bookUid 身份）时复用它；
/// 否则用 [externalVideoBookUid]（全路径 sha1，幂等）新建，仅新建时抽一次自动封面。
/// 落库失败抛出，由调用方提示。
Future<ExternalVideoUpsert> upsertExternalVideoBook(
  VideoBookRepository repo,
  String videoPath,
) => runExternalVideoCoverMutation((bool allowAutoCover) async {
  // ② 去重：同一物理文件若已库内导入（`video/<basename>` 身份），复用其旧
  // bookUid，不再派生 `video/ext/<sha1>` 第二身份插第二行。按 videoPath 命中
  // 走仓库单一真相源 findByVideoPath（与 isDuplicateVideoPath 同比对语义）。
  final VideoBookRow? sameFile = await repo.findByVideoPath(videoPath);
  if (sameFile != null) {
    return ExternalVideoUpsert(bookUid: sameFile.bookUid, created: false);
  }

  final String candidateUid = externalVideoBookUid(videoPath);
  final VideoBookRow? existing = await repo.getByBookUid(candidateUid);
  if (existing != null) {
    return ExternalVideoUpsert(bookUid: candidateUid, created: false);
  }

  CoverMetaStore? coverMetaStore;
  String? coverPath;
  if (allowAutoCover) {
    try {
      final CoverMetaStore store = CoverMetaStore(
        await VideoStorage.coversDir(),
      );
      if (await store.allowsAutoFrameWrite(candidateUid)) {
        coverMetaStore = store;
        // ① 封面：复用库内导入同款 extractVideoCover（桌面 ffmpeg 抽帧；移动端无
        // ffmpeg 时返 null 留空占位）。仅新建外部条目时抽一次。
        coverPath = await extractVideoCover(
          videoPath: videoPath,
          bookUid: candidateUid,
        );
      }
    } on Object catch (error) {
      // provenance 不可读时 fail closed：仍建无封面的媒体行。
      debugPrint('[Fushi] external video cover admission failed: $error');
    }
  }
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(candidateUid),
      title: Value(p.basenameWithoutExtension(videoPath)),
      videoPath: Value(videoPath),
      coverPath: Value<String?>(coverPath),
      importedAt: Value(DateTime.now().millisecondsSinceEpoch),
    ),
  );
  if (coverPath != null && coverMetaStore != null) {
    try {
      final bool committed = await coverMetaStore.markAutoFrameAfterWrite(
        candidateUid,
      );
      if (!committed) {
        debugPrint(
          '[Fushi] external video cover provenance changed during '
          'automatic write: $candidateUid',
        );
      }
    } on Object catch (error) {
      debugPrint(
        '[Fushi] external video cover provenance commit failed: '
        '$error',
      );
    }
  }
  return ExternalVideoUpsert(bookUid: candidateUid, created: true);
});
