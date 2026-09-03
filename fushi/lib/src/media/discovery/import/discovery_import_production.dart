/// [DiscoveryDomainImporters] 的生产装配：把各域**已有**导入原语接到发现页
/// 下载队列的自动入库端口上。零新导入逻辑——EPUB/文本/PDF/有声书对齐/游戏
/// 登记全部复用既有单一真相：
///
/// - EPUB：`EpubImporter.importFromPath`（`DuplicatePolicy.skip()`，同名已在库
///   → 跳过不重复入库，任务显示 0 新增）
/// - 文本：`TextToEpub.convert` → `EpubImporter.import`（与书导入对话框同路）
/// - PDF：`PdfImporter.importFromPath`
/// - 有声书：EPUB/文本先入库拿 bookKey，再 `alignAndPersistAudiobook`
///   （与对话框 `_importEpubWithAlignment` 同路，进度/文案省略）
/// - 游戏：`filterOutDuplicateGameExes` 查重 → `newGalgameEntryFromExe` →
///   `GalgameRepository.addAll`（批内 id 微秒错开，同拖拽入库）
/// - 漫画图包：`MangaModule.importArchive`（= `MangaArchiveImporter`，与手动
///   导入对话框的 `mangaArchive` 分支同一条路：自建 staging、7-Zip/内置解码
///   解包、识别包内 `.mokuro` sidecar、防穿越、失败回滚）
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/epub/book_title_conflict.dart';
import 'package:fushi/src/epub/epub_importer.dart';
import 'package:fushi/src/media/audiobook/audiobook_alignment_service.dart';
import 'package:fushi/src/media/audiobook/text_to_epub.dart';
import 'package:fushi/src/media/discovery/import/discovery_import_executor.dart';
import 'package:fushi/src/media/discovery/import/discovery_import_plan.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/pdf/pdf_importer.dart';

DiscoveryDomainImporters buildProductionDiscoveryImporters({
  required FushiDatabase db,
  required SrtBookRepository srtBookRepo,
  required AudiobookRepository audiobookRepo,
  required GalgameRepository galgameRepo,
}) {
  Future<String?> importEpub(String filePath) async {
    try {
      return await EpubImporter.importFromPath(
        db: db,
        filePath: filePath,
        fileName: _fileName(filePath),
        policy: const DuplicatePolicy.skip(),
      );
    } on DuplicateImportCancelledException {
      return null;
    }
  }

  Future<String?> importText(String filePath) async {
    final String title = _stem(filePath);
    final Uint8List bytes =
        await TextToEpub.convert(file: File(filePath), title: title);
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

  return DiscoveryDomainImporters(
    importEpub: importEpub,
    importText: importText,
    importPdf: (String filePath) async {
      try {
        return await PdfImporter.importFromPath(
          db: db,
          filePath: filePath,
          fileName: _fileName(filePath),
          title: _stem(filePath),
          policy: const DuplicatePolicy.skip(),
        );
      } on DuplicateImportCancelledException {
        return null;
      }
    },
    importAudiobook: (AlignAudiobookPlan plan) async {
      final String? bookKey = plan.contentPath.toLowerCase().endsWith('.epub')
          ? await importEpub(plan.contentPath)
          : await importText(plan.contentPath);
      if (bookKey == null) {
        // 同名书已在库：v1 不做「附着到既有书」的自动决策（换音频/换字幕是
        // 有损操作，交互入口是 AudiobookImportDialog），按跳过处理。
        return null;
      }
      await alignAndPersistAudiobook(
        db: db,
        repo: srtBookRepo,
        audiobookRepo: audiobookRepo,
        bookKey: bookKey,
        title: _stem(plan.contentPath),
        subtitlePath: plan.subtitlePath,
        audioPaths: plan.audioPaths,
      );
      return bookKey;
    },
    importMangaArchive: (String archivePath) async {
      try {
        return await MangaModule.importArchive(
          db: db,
          path: archivePath,
          title: _stem(archivePath),
          // 与本文件其余各域一致：批量后台导入不弹交互，同名已在库即跳过。
          // `MangaModule.importArchive` 的默认策略是 `.suffix()`（留副本），
          // 那适合用户手动点的导入；自动入库留副本会让重复下载悄悄堆出
          // 「XXX (2)」「XXX (3)」。
          policy: const DuplicatePolicy.skip(),
        );
      } on DuplicateImportCancelledException {
        return null;
      }
    },
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

String _fileName(String path) {
  final String normalized = path.replaceAll('\\', '/');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

String _stem(String path) {
  final String base = _fileName(path);
  final int dot = base.lastIndexOf('.');
  return dot <= 0 ? base : base.substring(0, dot);
}
