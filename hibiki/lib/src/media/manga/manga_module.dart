import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/epub/book_title_conflict.dart';
import 'package:hibiki/src/media/manga/external_mokuro_runner.dart';
import 'package:hibiki/src/media/manga/import/manga_archive_importer.dart';
import 'package:hibiki/src/media/manga/manga_importer.dart';
import 'package:hibiki/src/media/manga/manga_ocr_provider.dart';
import 'package:hibiki/src/media/manga/manga_ocr_wizard_dialog.dart';
import 'package:hibiki/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_catalog_dialog.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/ocr/manga_ocr_service.dart';
import 'package:hibiki/src/sync/interconnect_manga_ocr_client.dart';
import 'package:hibiki/utils.dart';

/// Narrow application-facing facade for the manga feature.
///
/// Generic book/navigation UI must call this facade instead of importing
/// reader, OCR, online-catalog, and storage implementations independently.
abstract final class MangaModule {
  static bool canImportPath(String path) =>
      mangaImportCanImport(<String>[path]);

  static Future<String> importMokuro({
    required HibikiDatabase db,
    required String path,
    String? title,
    DuplicateTitleCallback? onDuplicateTitle,
    void Function(int done, int total)? onProgress,
  }) =>
      MangaImporter.importFromMokuroPath(
        db: db,
        mokuroPath: path,
        title: title,
        onDuplicateTitle: onDuplicateTitle,
        onProgress: onProgress,
      );

  static bool isImageArchive(String path) =>
      MangaArchiveImporter.looksLikeImageArchive(path);

  static Future<String> importArchive({
    required HibikiDatabase db,
    required String path,
    String? title,
    DuplicateTitleCallback? onDuplicateTitle,
    void Function(int done, int total)? onProgress,
  }) =>
      MangaArchiveImporter.importArchive(
        db: db,
        archivePath: path,
        title: title,
        onDuplicateTitle: onDuplicateTitle,
        onProgress: onProgress,
      );

  static Future<String?> openOcrImportWizard({
    required BuildContext context,
    required HibikiDatabase db,
    required MangaOcrRemoteRunner remoteRunner,
    required bool desktop,
  }) {
    final ProviderContainer container =
        ProviderScope.containerOf(context, listen: false);
    final AppModel appModel = container.read(appProvider);
    final MangaOcrService service = container.read(mangaOcrServiceProvider);
    final String configured = appModel.mangaExternalMokuroPath.trim();
    final ExternalMokuroRunner? externalRunner = desktop
        ? ExternalMokuroRunner(
            configuredPath: configured.isEmpty ? null : configured,
          )
        : null;
    return showAppDialog<String>(
      context: context,
      builder: (_) => MangaOcrWizardDialog(
        service: service,
        db: db,
        externalRunner: externalRunner,
        remoteRunner: remoteRunner,
        lensRunner: GoogleLensMangaOcrService(),
        initialEnginePreference: appModel.mangaOcrEnginePreference,
      ),
    );
  }

  static Future<void> openOnlineCatalog({
    required BuildContext context,
    required HibikiDatabase db,
  }) =>
      showAppDialog<void>(
        context: context,
        builder: (_) => MokuroMoeCatalogDialog(db: db),
      );
}
