/// 服务端代下载的「按域入库」：非视频任务下载完成后，整包交给引擎的
/// `DiscoveryImportExecutor`（分类 → 需要时解压 → 各域导入原语），落进服务端
/// 自己的库，客户端经 `/api/library/books` / `/manga` / `/audiobooks` 消费。
///
/// 与 app 当 host 的差别只在域原语的装配：EPUB / 文本 / 漫画图包 / 有声书对齐
/// 与 app 共用引擎同一份（`discovery_engine_importers.dart`）；PDF 要 pdfrx 插件
/// 栅格化、游戏要 app 的游戏库，服务端都没有——能力位不宣告 `game`，小说包里的
/// PDF 以 `unsupportedOnThisHost` 原因码挡下（任务 needsAttention），不假装导入了。
library;

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart' show DiscoveryImportOutcome;
import 'package:fushi_engine/media/discovery/discovery_models.dart' show DiscoveryMediaKind;
import 'package:fushi_engine/media/discovery/import/discovery_archive_extractor.dart';
import 'package:fushi_engine/media/discovery/import/discovery_engine_importers.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_executor.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadDiscoveryImporter;

/// 服务端能按域入库的发现域（`DiscoveryMediaKind.name`）。`game` 不在内：服务端
/// 没有游戏库（exe 登记只在 app 里有意义，也没有对端能消费的游戏端点）。
const Set<String> kServerDownloadDiscoveryKinds = <String>{'novel', 'manga', 'audiobook'};

/// 服务端的域原语装配（PDF / 游戏如实挡下）。
DiscoveryDomainImporters buildServerDiscoveryImporters(FushiDatabase db) => DiscoveryDomainImporters(
      importEpub: (String path) => importDiscoveryEpub(db, path),
      importText: (String path) => importDiscoveryText(db, path),
      importPdf: (String path) async => unsupportedDiscoveryImporter('pdf', path),
      importAudiobook: (AlignAudiobookPlan plan) => importDiscoveryAudiobook(
            db: db,
            srtBookRepo: SrtBookRepository(db),
            audiobookRepo: AudiobookRepository(db),
            plan: plan,
          ),
      importSubtitleAudiobook: (SubtitleAudiobookPlan plan) => importDiscoverySubtitleAudiobook(
            db: db,
            srtBookRepo: SrtBookRepository(db),
            plan: plan,
          ),
      // 服务端不自动转录（模型要显式 `fushi_server models pull`，转录排队也还没
      // 接）：只有音频的包与改前同一个原因码挡下。
      transcribeAudiobook: (TranscribeAudiobookPlan plan) async =>
          throw const DiscoveryImportBlockedException(DiscoveryImportBlocker.audiobookMissingSubtitle),
      importMangaArchive: (String path) => importDiscoveryMangaArchive(db, path),
      registerGameExes: (List<String> exePaths) async =>
          unsupportedDiscoveryImporter('game', exePaths.isEmpty ? '' : exePaths.first),
    );

/// 管线的 `discoveryImporter` 端口。能力位之外的域（防御：旧行 / 手改 DB）在这里
/// 同样按 `unsupportedOnThisHost` 挡下，而不是交给执行器去碰没有的原语。
///
/// [extractor] 是测试缝；默认按 `FUSHI_7ZA` / 可执行文件旁 / PATH 找 7-Zip，
/// 找不到时 zip 走内置解码，rar / 7z 报 `archiveToolMissing`。
VideoDownloadDiscoveryImporter serverDiscoveryImporter(
  FushiDatabase db, {
  DiscoveryArchiveExtractor? extractor,
}) {
  final DiscoveryImportExecutor executor = DiscoveryImportExecutor(
    importers: buildServerDiscoveryImporters(db),
    extractor: extractor,
  );
  return (DiscoveryMediaKind kind, List<String> paths) async {
    if (!kServerDownloadDiscoveryKinds.contains(kind.name)) {
      throw DiscoveryImportBlockedException(DiscoveryImportBlocker.unsupportedOnThisHost, kind.name);
    }
    final DiscoveryImportOutcome outcome = await executor.importPaths(kind, paths);
    return outcome;
  };
}
