/// 本地 sidecar 视频封面维护服务。
///
/// 本服务只识别视频同目录下的 `poster.jpg` / `folder.jpg` / `<name>-poster.*`，
/// 并把用户提供的图片复制到 Hibiki 封面目录。它没有标题匹配、候选、别名缓存、
/// 图片下载或外部元数据源；动画在线元数据统一由 `VideoSourceScrapeCoordinator`
/// 走 AniDB → TMDB。
library;

import 'dart:io';

import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/scraper/sidecar_scanner.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_cover_extractor.dart'
    show videoCoverFileName;
import 'package:fushi/src/media/video/video_storage.dart';
import 'package:fushi_core/fushi_core.dart' show VideoBookRow;
import 'package:path/path.dart' as p;

sealed class ScrapeOutcome {
  const ScrapeOutcome();
}

/// 用户 sidecar 已复制并登记为受保护封面。
class ScrapeApplied extends ScrapeOutcome {
  const ScrapeApplied({required this.coverPath});

  final String coverPath;
  CoverOrigin get origin => CoverOrigin.sidecar;
}

/// 本地目录没有可采用的用户 sidecar。
class ScrapeNoSidecar extends ScrapeOutcome {
  const ScrapeNoSidecar();
}

/// 既有封面来源或多成员合集规则不允许自动覆盖。
class ScrapeSkippedProtected extends ScrapeOutcome {
  const ScrapeSkippedProtected(this.origin);

  final CoverOrigin origin;
}

/// 远端流媒体或空路径不具备本地 sidecar 目录。
class ScrapeNotEligible extends ScrapeOutcome {
  const ScrapeNotEligible(this.reason);

  final String reason;
}

/// 单本本地读取或写盘失败；批处理继续处理下一本。
class ScrapeFailed extends ScrapeOutcome {
  const ScrapeFailed(this.error);

  final Object error;
}

class BatchScrapeProgress {
  const BatchScrapeProgress({
    required this.index,
    required this.total,
    required this.book,
    required this.outcome,
  });

  final int index;
  final int total;
  final VideoBookRow book;
  final ScrapeOutcome outcome;
}

class CoverScraperService {
  CoverScraperService({
    required VideoBookRepository repository,
    required CoverMetaStore coverMetaStore,
    SidecarGeneratedArtifactChecker? generatedSidecarArtifactChecker,
    Directory? coversDirectory,
  })  : _repo = repository,
        _coverMeta = coverMetaStore,
        _generatedSidecarArtifactChecker = generatedSidecarArtifactChecker,
        _coversDirectory = coversDirectory;

  final VideoBookRepository _repo;
  final CoverMetaStore _coverMeta;
  final SidecarGeneratedArtifactChecker? _generatedSidecarArtifactChecker;
  final Directory? _coversDirectory;

  /// 对单个本地视频应用用户 sidecar；未命中时不修改任何状态。
  Future<ScrapeOutcome> applySidecarCover(
    VideoBookRow book, {
    bool requireBatchEligibility = false,
  }) async {
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterOperation();
    if (lease == null) return const ScrapeFailed('scrape-cleanup-running');
    try {
      return await _applySidecarCoverUnlocked(
        book,
        requireBatchEligibility: requireBatchEligibility,
      );
    } finally {
      lease.release();
    }
  }

  Future<ScrapeOutcome> _applySidecarCoverUnlocked(
    VideoBookRow book, {
    required bool requireBatchEligibility,
  }) async {
    final String path = book.videoPath;
    if (path.isEmpty || _isRemotePath(path)) {
      return const ScrapeNotEligible('remote-or-empty-path');
    }

    final SidecarResult sidecar = await SidecarScanner.scan(
      path,
      generatedArtifactChecker: _generatedSidecarArtifactChecker,
    );
    final File? poster = sidecar.posterFile;
    if (poster == null || sidecar.posterIsUnmodifiedGeneratedArtifact) {
      return const ScrapeNoSidecar();
    }

    return VideoCoverMutationGate.runExclusive(() async {
      if (requireBatchEligibility) {
        final CoverOrigin origin =
            (await _coverMeta.getFresh(book.bookUid))?.origin ??
            CoverOrigin.autoFrame;
        final bool becameCollectionMember =
            (await _repo.multiMemberCollectionIds())[book.bookUid] != null;
        if (origin != CoverOrigin.autoFrame || becameCollectionMember) {
          return ScrapeSkippedProtected(origin);
        }
      }
      // 来源标记先落稳；失败时不覆盖用户/旧封面。后续失败只会留下过度保护标记，
      // 比暴露一张无 provenance 的用户 sidecar 安全。
      await _coverMeta.set(
        book.bookUid,
        const CoverMeta(origin: CoverOrigin.sidecar),
      );
      final String coverPath = await _copySidecarCover(poster, book.bookUid);
      await _repo.updateCover(book.bookUid, coverPath);
      return ScrapeApplied(coverPath: coverPath);
    });
  }

  /// 批量检查 sidecar。只允许覆盖自动抽帧占位封面；用户封面、历史刮削封面和
  /// 多成员合集中的子篇均保持不动。
  Stream<BatchScrapeProgress> scrapeLibrary(
    List<VideoBookRow> books,
  ) async* {
    final Map<String, int> memberCollectionIds =
        await _repo.multiMemberCollectionIds();
    for (int index = 0; index < books.length; index++) {
      final VideoBookRow book = books[index];
      ScrapeOutcome outcome;
      try {
        if (book.videoPath.isEmpty || _isRemotePath(book.videoPath)) {
          outcome = const ScrapeNotEligible('remote-or-empty-path');
        } else {
          final CoverMeta? meta = await _coverMeta.get(book.bookUid);
          final CoverOrigin origin = meta?.origin ?? CoverOrigin.autoFrame;
          final bool allowed = memberCollectionIds[book.bookUid] == null &&
              origin == CoverOrigin.autoFrame;
          outcome = allowed
              ? await applySidecarCover(book, requireBatchEligibility: true)
              : ScrapeSkippedProtected(origin);
        }
      } catch (error) {
        outcome = ScrapeFailed(error);
      }
      yield BatchScrapeProgress(
        index: index,
        total: books.length,
        book: book,
        outcome: outcome,
      );
    }
  }

  Future<String> _copySidecarCover(File poster, String bookUid) async {
    final Directory covers = _coversDirectory ?? await VideoStorage.coversDir();
    await covers.create(recursive: true);
    final String finalPath = p.join(covers.path, videoCoverFileName(bookUid));
    await MediaCoverService.applyCoverFile(
      source: poster,
      destPath: finalPath,
    );
    return finalPath;
  }

  static bool _isRemotePath(String path) =>
      path.startsWith('http://') || path.startsWith('https://');
}
