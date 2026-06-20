// GENERATED-NOTE: extracted from sync_settings_schema.dart (TODO-585).
part of '../sync_settings_schema.dart';

// Local backup export / import widgets + default category set.
// Shares the parent library's imports + private scope (_syncSettings / _showSnackBar / _SyncSettingsState); moved verbatim.

@visibleForTesting
Set<BackupCategory> defaultBackupExportCategories() => BackupCategory.values
    .where((BackupCategory c) => c != BackupCategory.videos)
    .toSet();

class _BackupExportWidget extends StatefulWidget {
  const _BackupExportWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_BackupExportWidget> createState() => _BackupExportWidgetState();
}

class _BackupExportWidgetState extends State<_BackupExportWidget> {
  bool _isExporting = false;

  Future<void> _export() async {
    // Re-entrant guard: the row's Activate (A/Enter) and the trailing button
    // both call this, so ignore a second trigger while an export is running.
    if (_isExporting) return;
    // Ask which sidecar trees to include (default all). Null = the user
    // cancelled the dialog → abort the export entirely (TODO-106).
    final Set<BackupCategory>? categories = await _pickExportCategories();
    if (categories == null || !mounted) return;
    setState(() => _isExporting = true);
    try {
      final appModel = widget.settingsContext.appModel;
      final service = BackupService(
        db: appModel.database,
        dbDirectory: appModel.databaseDirectory.path,
        dictionaryResourceDirectory: appModel.dictionaryResourceDirectory.path,
        appVersion: appModel.packageInfo.version,
        // Full-data backup: pack the book + audiobook content trees too. Roots
        // are derived the same way the app lays them out under the documents
        // dir (hoshi_books / audiobooks).
        booksRootDirectory: p.join(appModel.appDirectory.path, 'hoshi_books'),
        audiobooksRootDirectory:
            p.join(appModel.appDirectory.path, 'audiobooks'),
        // BUG-183: pack the imported custom fonts so they travel with their
        // config; otherwise the restored config points at files that never
        // crossed over and the fonts silently never apply.
        fontsRootDirectory: p.join(appModel.appDirectory.path, 'custom_fonts'),
      );

      final tmpDir = await getTemporaryDirectory();
      final filename = service.defaultFilename();
      final tmpPath = p.join(tmpDir.path, filename);
      await service.exportBackup(tmpPath, categories: categories);

      if (!mounted) return;

      if (Platform.isAndroid || Platform.isIOS) {
        await Share.shareXFiles(
          [XFile(tmpPath, mimeType: 'application/zip')],
          subject: filename,
        );
      } else {
        final savePath = await FilePicker.platform.saveFile(
          dialogTitle: t.backup_export,
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: ['zip'],
        );
        if (savePath != null) {
          await File(tmpPath).copy(savePath);
        }
        await File(tmpPath).delete();
      }

      if (mounted) {
        _showSnackBar(context, t.backup_export_success);
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(context,
            t.backup_export_failed(message: friendlySyncErrorDetail(e)));
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  /// Prompts the user to choose which optional file trees travel in the backup.
  /// All categories start ticked (the user asked for "default all selected"),
  /// so confirming without touching anything reproduces the legacy all-in
  /// export. Returns the chosen set, or null if the user cancelled.
  Future<Set<BackupCategory>?> _pickExportCategories() async {
    final Set<BackupCategory> selected = defaultBackupExportCategories();
    assert(!selected.contains(BackupCategory.videos));
    String labelFor(BackupCategory c) {
      switch (c) {
        case BackupCategory.dictionary:
          return t.backup_category_dictionary;
        case BackupCategory.books:
          return t.backup_category_books;
        case BackupCategory.audiobooks:
          return t.backup_category_audiobooks;
        case BackupCategory.fonts:
          return t.backup_category_fonts;
        case BackupCategory.videos:
          return t.backup_category_videos;
      }
    }

    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) {
          final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
          return HibikiDialogFrame(
            maxWidth: 420,
            insetPadding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.card,
              vertical: tokens.spacing.card,
            ),
            scrollable: false,
            child: HibikiModalSheetFrame(
              title: t.backup_export_categories_title,
              scrollable: true,
              bodyPadding: EdgeInsets.fromLTRB(
                tokens.spacing.card,
                0,
                tokens.spacing.card,
                tokens.spacing.gap,
              ),
              footerPadding: EdgeInsets.fromLTRB(
                tokens.spacing.card,
                tokens.spacing.gap,
                tokens.spacing.card,
                tokens.spacing.card,
              ),
              body: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    t.backup_export_categories_hint,
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  for (final BackupCategory c in BackupCategory.values)
                    AdaptiveSettingsSwitchRow(
                      title: labelFor(c),
                      value: selected.contains(c),
                      onChanged: (bool v) => setLocal(() {
                        if (v) {
                          selected.add(c);
                        } else {
                          selected.remove(c);
                        }
                      }),
                    ),
                ],
              ),
              footer: Wrap(
                alignment: WrapAlignment.end,
                spacing: tokens.spacing.gap,
                children: <Widget>[
                  adaptiveDialogAction(
                    context: ctx,
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(t.dialog_cancel),
                  ),
                  adaptiveDialogAction(
                    context: ctx,
                    isDefaultAction: true,
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(t.dialog_ok),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    return confirmed == true ? selected : null;
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: t.backup_export,
      subtitle: t.backup_export_hint,
      icon: Icons.upload_file_outlined,
      controlBelow: true,
      // Row onTap registers the focus target so directional nav reaches the
      // export action (BUG-016); the trailing button is the visual affordance.
      onTap: _export,
      trailing: _isExporting
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 20,
                  height: 20,
                  child: adaptiveIndicator(context: context, strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(t.backup_exporting),
              ],
            )
          : FilledButton.tonal(
              onPressed: _export,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.upload_file_outlined, size: 18),
                  const SizedBox(width: 8),
                  Text(t.backup_export),
                ],
              ),
            ),
    );
  }
}

// ── Backup import widget ─────────────────────────────────────────────

class _BackupImportWidget extends StatefulWidget {
  const _BackupImportWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_BackupImportWidget> createState() => _BackupImportWidgetState();
}

class _BackupImportWidgetState extends State<_BackupImportWidget> {
  bool _isImporting = false;

  Future<void> _import() async {
    // Re-entrant guard: the row's Activate (A/Enter) and the trailing button
    // both call this, so ignore a second trigger while an import is running.
    if (_isImporting) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (result == null || result.files.single.path == null) return;
    if (!mounted) return;

    setState(() => _isImporting = true);
    try {
      final filePath = result.files.single.path!;
      final appModel = widget.settingsContext.appModel;
      final service = BackupService(
        db: appModel.database,
        dbDirectory: appModel.databaseDirectory.path,
        dictionaryResourceDirectory: appModel.dictionaryResourceDirectory.path,
        appVersion: appModel.packageInfo.version,
      );

      final meta = await service.validateBackup(filePath);
      if (meta == null) {
        if (mounted) _showSnackBar(context, t.backup_import_invalid);
        return;
      }

      if (meta.schemaVersion > appModel.database.schemaVersion) {
        if (mounted) {
          _showSnackBar(
            context,
            t.backup_schema_newer(version: meta.schemaVersion.toString()),
          );
        }
        return;
      }

      if (!mounted) return;

      final bool? importSettings = await _showConfirmDialog(meta);
      if (importSettings == null || !mounted) return;

      await appModel.closeDatabase();
      await BackupService.importBackupFiles(
        dbDirectory: appModel.databaseDirectory.path,
        zipPath: filePath,
        importSettings: importSettings,
        dictionaryResourceDirectory: appModel.dictionaryResourceDirectory.path,
        // Full-data restore: extract the content trees and rebase the DB's
        // absolute paths onto this device's roots.
        booksRootDirectory: p.join(appModel.appDirectory.path, 'hoshi_books'),
        audiobooksRootDirectory:
            p.join(appModel.appDirectory.path, 'audiobooks'),
        // BUG-183: restore the custom-font files and rebase the stored font
        // config paths onto this device's root.
        fontsRootDirectory: p.join(appModel.appDirectory.path, 'custom_fonts'),
        videosRootDirectory: p.join(appModel.appDirectory.path, 'videos'),
      );

      if (mounted) {
        _showSnackBar(context, t.backup_import_success);
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (Platform.isAndroid || Platform.isIOS) {
        FlutterExitApp.exitApp();
      } else {
        exit(0);
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(context,
            t.backup_import_failed(message: friendlySyncErrorDetail(e)));
      }
      // DB is already closed — must exit regardless to avoid dead state.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (Platform.isAndroid || Platform.isIOS) {
        FlutterExitApp.exitApp();
      } else {
        exit(0);
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  /// Returns the chosen import mode: `false` = keep this device's settings &
  /// profiles and restore only content (default); `true` = full restore.
  /// Returns `null` if the user cancels.
  Future<bool?> _showConfirmDialog(BackupMeta meta) async {
    final dateStr =
        '${meta.createdAt.year}-${meta.createdAt.month.toString().padLeft(2, '0')}-${meta.createdAt.day.toString().padLeft(2, '0')}';
    bool importSettings = false; // default: keep this device's settings
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) {
          final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
          return HibikiDialogFrame(
            maxWidth: 420,
            insetPadding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.card,
              vertical: tokens.spacing.card,
            ),
            scrollable: false,
            child: HibikiModalSheetFrame(
              title: t.backup_import_confirm_title,
              scrollable: true,
              bodyPadding: EdgeInsets.fromLTRB(
                tokens.spacing.card,
                0,
                tokens.spacing.card,
                tokens.spacing.gap,
              ),
              footerPadding: EdgeInsets.fromLTRB(
                tokens.spacing.card,
                tokens.spacing.gap,
                tokens.spacing.card,
                tokens.spacing.card,
              ),
              body: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    t.backup_import_confirm(
                      date: dateStr,
                      bookCount: meta.bookCount.toString(),
                      statsCount: meta.statsCount.toString(),
                    ),
                  ),
                  const SizedBox(height: 4),
                  AdaptiveSettingsSwitchRow(
                    title: t.backup_import_settings_toggle,
                    subtitle: importSettings
                        ? t.backup_import_settings_on_hint
                        : t.backup_import_settings_off_hint,
                    value: importSettings,
                    onChanged: (bool v) => setLocal(() => importSettings = v),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t.backup_import_preserve_sync_note,
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
              footer: Wrap(
                alignment: WrapAlignment.end,
                spacing: tokens.spacing.gap,
                children: <Widget>[
                  adaptiveDialogAction(
                    context: ctx,
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(t.dialog_cancel),
                  ),
                  adaptiveDialogAction(
                    context: ctx,
                    isDefaultAction: true,
                    isDestructiveAction: true,
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(t.dialog_ok),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    return confirmed == true ? importSettings : null;
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: t.backup_import,
      subtitle: t.backup_import_hint,
      icon: Icons.download_outlined,
      controlBelow: true,
      // Row onTap registers the focus target so directional nav reaches the
      // import action (BUG-016); the trailing button is the visual affordance.
      onTap: _import,
      trailing: _isImporting
          ? SizedBox(
              width: 24,
              height: 24,
              child: adaptiveIndicator(context: context, strokeWidth: 2),
            )
          : FilledButton.tonal(
              onPressed: _import,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.download_outlined, size: 18),
                  const SizedBox(width: 8),
                  Text(t.backup_import),
                ],
              ),
            ),
    );
  }
}
