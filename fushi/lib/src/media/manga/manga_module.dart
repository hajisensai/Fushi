import 'dart:io';

import 'package:flutter/material.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/epub/book_title_conflict.dart';
import 'package:fushi/src/media/manga/import/manga_archive_importer.dart';
import 'package:fushi/src/media/manga/import/manga_folder_batch.dart';
import 'package:fushi/src/media/manga/manga_importer.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_dialog.dart';
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_catalog_dialog.dart';
import 'package:fushi/src/sync/interconnect_manga_ocr_client.dart';
import 'package:fushi/utils.dart';

/// Narrow application-facing facade for the manga feature.
///
/// Generic book/navigation UI must call this facade instead of importing
/// reader, OCR, online-catalog, and storage implementations independently.
abstract final class MangaModule {
  static bool canImportPath(String path) =>
      mangaImportCanImport(<String>[path]);

  static Future<String> importMokuro({
    required FushiDatabase db,
    required String path,
    String? title,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
  }) =>
      MangaImporter.importFromMokuroPath(
        db: db,
        mokuroPath: path,
        title: title,
        policy: policy,
        onProgress: onProgress,
      );

  static bool isImageArchive(String path) =>
      MangaArchiveImporter.looksLikeImageArchive(path);

  /// 目录里有没有页图（[ImportCarrier] 的目录分支判据）。
  static bool directoryHasPageImages(String path) =>
      mangaDirectoryHasPageImages(path);

  /// 目录直接子层的整卷载体文件数（[ImportCarrier] 的目录分支判据）。
  static int directoryCarrierFileCount(String path) =>
      mangaCarrierFilesIn(Directory(path)).length;

  /// 一个装着整卷载体文件的目录 → 逐卷导入（BUG-1646）。一卷失败不中断整批，
  /// 每卷结局在返回的报告里，由调用方一次性汇报。
  static Future<MangaBatchImportReport> importBatchFolder({
    required FushiDatabase db,
    required String path,
    void Function(int done, int total)? onVolumeProgress,
  }) =>
      importMangaBatchFolder(
        db: db,
        path: path,
        onVolumeProgress: onVolumeProgress,
      );

  /// 整目录页图导入（拖入一个漫画文件夹的落地路径）。OCR blocks 留空，之后可由
  /// 任一整卷引擎补齐——故 OCR 失败绝不会导致这本书消失。
  static Future<String> importImageFolder({
    required FushiDatabase db,
    required String path,
    String? title,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
  }) =>
      MangaImporter.importFromImageFolder(
        db: db,
        imageDirPath: path,
        title: title,
        policy: policy,
        onProgress: onProgress,
      );

  static Future<String> importArchive({
    required FushiDatabase db,
    required String path,
    String? title,
    DuplicatePolicy policy = const DuplicatePolicy.suffix(),
    void Function(int done, int total)? onProgress,
  }) =>
      MangaArchiveImporter.importArchive(
        db: db,
        archivePath: path,
        title: title,
        policy: policy,
        onProgress: onProgress,
      );

  /// 未入库的裸图片文件夹 → 选引擎 → 整卷 OCR → 落库，返回新建 bookKey。
  ///
  /// [remoteRunnerOverride] / [desktopOverride] 只是测试缝，生产传 null 即可；
  /// 引擎依赖集由 [MangaOcrWizardEngines.resolve] 统一装配，本入口不再手抄。
  static Future<String?> openOcrImportWizard({
    required BuildContext context,
    required FushiDatabase db,
    MangaOcrRemoteRunner? remoteRunnerOverride,
    bool? desktopOverride,
  }) {
    final MangaOcrWizardEngines engines = MangaOcrWizardEngines.resolve(
      context: context,
      db: db,
      remoteRunnerOverride: remoteRunnerOverride,
      desktopOverride: desktopOverride,
    );
    return showAppDialog<String>(
      context: context,
      builder: (_) => MangaOcrWizardDialog(engines: engines, db: db),
    );
  }

  /// 对已入书架的漫画直接运行整卷 OCR。阅读器从当前页触发时，Lens 会先扫
  /// 当前页到末页，再从首页补齐；完成后原子替换本书的 `manga.json`。
  ///
  /// 引擎依赖集与 [openOcrImportWizard] **共用同一个装配点**：两个入口各自手抄
  /// 参数表时，本入口漏掉了 `remoteRunner`，「配对主机」引擎在阅读器里永久不可见
  /// （BUG-1418）。
  static Future<MangaOcrBackgroundJob?> openBookOcr({
    required BuildContext context,
    required FushiDatabase db,
    required EpubBookRow book,
    required int startPage,
    MangaOcrRemoteRunner? remoteRunnerOverride,
    bool? desktopOverride,
  }) {
    final MangaOcrWizardEngines engines = MangaOcrWizardEngines.resolve(
      context: context,
      db: db,
      remoteRunnerOverride: remoteRunnerOverride,
      desktopOverride: desktopOverride,
    );
    return showAppDialog<MangaOcrBackgroundJob>(
      context: context,
      builder: (_) => MangaOcrWizardDialog(
        engines: engines,
        db: db,
        existingBook: book,
        startPage: startPage,
        onlyMissing: true,
        launchInBackground: true,
      ),
    );
  }

  static Future<void> openOnlineCatalog({
    required BuildContext context,
    required FushiDatabase db,
  }) =>
      showAppDialog<void>(
        context: context,
        builder: (_) => MokuroMoeCatalogDialog(db: db),
      );
}
