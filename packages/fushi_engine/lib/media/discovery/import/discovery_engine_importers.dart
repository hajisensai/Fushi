/// [DiscoveryDomainImporters] 里纯 Dart 的那几个域原语：EPUB / 文本 / 漫画图包 /
/// 有声书对齐。app 的生产装配（`discovery_import_production.dart`）与无头服务端
/// （`fushi_server` 的 `ServerDownloadHost`）共用这一份，两边对同一个下载包的
/// 入库结果一致。
///
/// 不在这里的两个域：PDF（`PdfImporter` 靠 pdfrx 插件栅格化封面）与游戏登记
/// （`GalgameRepository` 是 app 的库），它们只在 app 里接线；没有它们的宿主用
/// [unsupportedDiscoveryImporter] 如实挡下。
///
/// 策略全部是 `DuplicatePolicy.skip()`：后台批量入库不弹交互，同名已在库即跳过
/// （返回 null，任务显示 0 条新增）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart';
import 'package:fushi_engine/media/audiobook/text_to_epub.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:fushi_engine/media/manga/manga_archive_importer.dart';

/// EPUB：`EpubImporter.importFromPath`。
Future<String?> importDiscoveryEpub(FushiDatabase db, String filePath) async {
  try {
    return await EpubImporter.importFromPath(
      db: db,
      filePath: filePath,
      fileName: discoveryImportFileName(filePath),
      policy: const DuplicatePolicy.skip(),
    );
  } on DuplicateImportCancelledException {
    return null;
  }
}

/// 文本：`TextToEpub.convert` → `EpubImporter.import`（与书导入对话框同路）。
Future<String?> importDiscoveryText(FushiDatabase db, String filePath) async {
  final String title = discoveryImportStem(filePath);
  final Uint8List bytes = await TextToEpub.convert(
    file: File(filePath),
    title: title,
  );
  try {
    return await EpubImporter.import(
      db: db,
      bytes: bytes,
      fileName: '$title.epub',
      policy: const DuplicatePolicy.skip(),
    );
  } on DuplicateImportCancelledException {
    return null;
  }
}

/// 漫画图包：`MangaArchiveImporter.importArchive`（自建 staging、7-Zip/内置解码
/// 解包、识别包内 `.mokuro` sidecar、防穿越、失败回滚）。它的默认策略是
/// `.suffix()`（适合用户手动点的导入）；自动入库留副本会让重复下载悄悄堆出
/// 「XXX (2)」「XXX (3)」，所以这里显式 skip。
Future<String?> importDiscoveryMangaArchive(
  FushiDatabase db,
  String archivePath,
) async {
  try {
    return await MangaArchiveImporter.importArchive(
      db: db,
      archivePath: archivePath,
      title: discoveryImportStem(archivePath),
      policy: const DuplicatePolicy.skip(),
    );
  } on DuplicateImportCancelledException {
    return null;
  }
}

/// 有声书：正文（EPUB/文本）先入库拿 bookKey，再 `alignAndPersistAudiobook`
/// （与对话框 `_importEpubWithAlignment` 同路，进度/文案省略）。
Future<String?> importDiscoveryAudiobook({
  required FushiDatabase db,
  required SrtBookRepository srtBookRepo,
  required AudiobookRepository audiobookRepo,
  required AlignAudiobookPlan plan,
}) async {
  final String? bookKey = plan.contentPath.toLowerCase().endsWith('.epub')
      ? await importDiscoveryEpub(db, plan.contentPath)
      : await importDiscoveryText(db, plan.contentPath);
  if (bookKey == null) {
    // 同名书已在库：v1 不做「附着到既有书」的自动决策（换音频/换字幕是
    // 有损操作，交互入口是 AudiobookImportDialog）。音频并没有入库，不能
    // 装成「0 条新增」——那会落成一句没头没脑的 import failed（BUG-2775），
    // 以稳定原因码报出去，UI 告诉用户去已有书里手动导入有声书。
    throw DiscoveryImportBlockedException(
      DiscoveryImportBlocker.audiobookBookAlreadyInLibrary,
      discoveryImportFileName(plan.contentPath),
    );
  }
  await alignAndPersistAudiobook(
    db: db,
    repo: srtBookRepo,
    audiobookRepo: audiobookRepo,
    bookKey: bookKey,
    title: discoveryImportStem(plan.contentPath),
    subtitlePath: plan.subtitlePath,
    audioPaths: plan.audioPaths,
  );
  return bookKey;
}

/// 本宿主接不了的域原语：抛 [DiscoveryImportBlocker.unsupportedOnThisHost]，
/// [what] 进 detail（如 `pdf` / `game`）。任务落成 needsAttention 并带稳定原因码，
/// 而不是假装导入了 0 条。
Never unsupportedDiscoveryImporter(String what, String path) =>
    throw DiscoveryImportBlockedException(
      DiscoveryImportBlocker.unsupportedOnThisHost,
      '$what: ${discoveryImportFileName(path)}',
    );

String discoveryImportFileName(String path) {
  final String normalized = path.replaceAll('\\', '/');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

String discoveryImportStem(String path) {
  final String base = discoveryImportFileName(path);
  final int dot = base.lastIndexOf('.');
  return dot <= 0 ? base : base.substring(0, dot);
}
