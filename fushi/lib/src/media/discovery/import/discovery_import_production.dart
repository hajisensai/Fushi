/// [DiscoveryDomainImporters] 的生产装配：把各域**已有**导入原语接到发现页
/// 下载队列的自动入库端口上。零新导入逻辑——EPUB/文本/PDF/有声书对齐/游戏
/// 登记全部复用既有单一真相：
///
/// - EPUB / 文本 / 有声书 / 漫画图包：引擎 `discovery_engine_importers.dart`
///   （与无头服务端的代下载共用同一份；`DuplicatePolicy.skip()`，同名已在库
///   → 跳过不重复入库，任务显示 0 新增）
/// - PDF：`PdfImporter.importFromPath`（pdfrx 插件，只在 app 里）
/// - 游戏：`filterOutDuplicateGameExes` 查重 → `newGalgameEntryFromExe` →
///   `GalgameRepository.addAll`（批内 id 微秒错开，同拖拽入库）
library;

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart'
    show DiscoveryImportOutcome;
import 'package:fushi_engine/media/discovery/import/discovery_engine_importers.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_executor.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/pdf/pdf_importer.dart';

DiscoveryDomainImporters buildProductionDiscoveryImporters({
  required FushiDatabase db,
  required SrtBookRepository srtBookRepo,
  required AudiobookRepository audiobookRepo,
  required GalgameRepository galgameRepo,
  required Future<DiscoveryImportOutcome> Function(TranscribeAudiobookPlan plan)
      transcribeAudiobook,
}) {
  return DiscoveryDomainImporters(
    importEpub: (String filePath) => importDiscoveryEpub(db, filePath),
    importText: (String filePath) => importDiscoveryText(db, filePath),
    importPdf: (String filePath) async {
      try {
        return await PdfImporter.importFromPath(
          db: db,
          filePath: filePath,
          fileName: discoveryImportFileName(filePath),
          title: discoveryImportStem(filePath),
          policy: const DuplicatePolicy.skip(),
        );
      } on DuplicateImportCancelledException {
        return null;
      }
    },
    importAudiobook: (AlignAudiobookPlan plan) => importDiscoveryAudiobook(
      db: db,
      srtBookRepo: srtBookRepo,
      audiobookRepo: audiobookRepo,
      plan: plan,
    ),
    importSubtitleAudiobook: (SubtitleAudiobookPlan plan) =>
        importDiscoverySubtitleAudiobook(
      db: db,
      srtBookRepo: srtBookRepo,
      plan: plan,
    ),
    transcribeAudiobook: transcribeAudiobook,
    importMangaArchive: (String archivePath) =>
        importDiscoveryMangaArchive(db, archivePath),
    registerGameExes: (List<String> exePaths) async {
      final List<String> fresh =
          filterOutDuplicateGameExes(galgameRepo.games, exePaths);
      if (fresh.isEmpty) return 0;
      final DateTime base = DateTime.now();
      // 批内 id 用微秒错开，防同微秒撞 id（同 games_library_page 拖拽入库）。
      final List<GalgameEntry> entries = <GalgameEntry>[
        for (int i = 0; i < fresh.length; i++)
          newGalgameEntryFromExe(
            fresh[i],
            now: base.add(Duration(microseconds: i)),
          ),
      ];
      await galgameRepo.addAll(entries);
      return entries.length;
    },
  );
}
