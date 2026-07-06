// GENERATED-NOTE: extracted from sync_settings_schema.dart (TODO-585).
part of '../sync_settings_schema.dart';

// Local backup export / import widgets + default category set.
// Shares the parent library's imports + private scope (_syncSettings / _showSnackBar / _SyncSettingsState); moved verbatim.

@visibleForTesting
Set<BackupCategory> defaultBackupExportCategories() => BackupCategory.values
    .where((BackupCategory c) =>
        c != BackupCategory.videos && c != BackupCategory.localAudio)
    .toSet();

/// TODO-1151：备份导入完成后由 [BackupImportOverlayView] 的「立即重启」按钮触发的退出。
/// 沿用旧导入实现的平台分支（移动端 [FlutterExitApp.exitApp]，桌面端 `exit(0)`），只把
/// 触发时机从「延迟 500ms 自动退出」改为「用户点确认后退出」，退出行为本身不变
/// （never-break）。抽成顶层函数供 `main.dart` 注入为 `onRestart`。
void backupImportRestart() {
  if (Platform.isAndroid || Platform.isIOS) {
    FlutterExitApp.exitApp();
  } else {
    exit(0);
  }
}

class _BackupExportWidget extends StatefulWidget {
  const _BackupExportWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_BackupExportWidget> createState() => _BackupExportWidgetState();
}

class _BackupExportWidgetState extends State<_BackupExportWidget> {
  bool _isExporting = false;

  /// Per-book export selection (TODO-1195 part A). null = every book (the legacy
  /// full export); a non-null set = only those `book_key`s travel. Persists
  /// across dialog opens within this settings session (the picker re-seeds from
  /// it); only consulted when the Books category is selected.
  Set<String>? _selectedBookKeys;

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
      final tmpFile = File(tmpPath);
      // Per-book selection (TODO-1195 part A) only applies when the Books
      // category is packed; excluding Books strips every book regardless.
      await service.exportBackup(
        tmpPath,
        categories: categories,
        bookKeys: categories.contains(BackupCategory.books)
            ? _selectedBookKeys
            : null,
      );

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
        try {
          if (savePath == null) return;
          await tmpFile.copy(savePath);
        } finally {
          if (await tmpFile.exists()) {
            await tmpFile.delete();
          }
        }
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
    assert(!selected.contains(BackupCategory.localAudio));
    // Per-book selection (TODO-1195 part A). Mutated by the nested book picker;
    // written back to [_selectedBookKeys] only when the dialog is confirmed.
    Set<String>? chosenBooks = _selectedBookKeys;
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
        case BackupCategory.localAudio:
          return t.backup_category_local_audio;
        case BackupCategory.progress:
          return t.backup_category_progress;
        case BackupCategory.statistics:
          return t.backup_category_statistics;
        case BackupCategory.settings:
          return t.backup_category_settings;
        case BackupCategory.profiles:
          return t.backup_category_profiles;
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
                  // Per-book selection row (TODO-1195 part A): only meaningful
                  // when the Books category itself is packed.
                  if (selected.contains(BackupCategory.books))
                    AdaptiveSettingsRow(
                      title: t.backup_export_choose_books,
                      subtitle: chosenBooks == null
                          ? t.backup_export_books_all
                          : t.backup_export_books_selected(
                              count: chosenBooks!.length.toString()),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        final Set<String>? picked =
                            await _pickBooks(chosenBooks);
                        setLocal(() => chosenBooks = picked);
                      },
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
    if (confirmed != true) return null;
    // Commit the per-book selection only on confirm (cancel leaves it as-was).
    _selectedBookKeys = chosenBooks;
    return selected;
  }

  /// Nested picker for per-book export (TODO-1195 part A). Loads the library and
  /// lets the user tick which books travel; [current] seeds the initial state
  /// (null = every book). Returns the chosen set, collapsing "all ticked" back
  /// to null (the legacy full-export path), or [current] unchanged on cancel.
  Future<Set<String>?> _pickBooks(Set<String>? current) async {
    final List<EpubBookRow> books =
        await widget.settingsContext.appModel.database.getAllEpubBooks();
    // State.context guarded by State.mounted (coherent for the lint): the
    // settings page may have unmounted while the library loaded.
    if (!mounted) return current;
    if (books.isEmpty) {
      _showSnackBar(context, t.backup_export_no_books);
      return current;
    }
    final List<String> keys =
        books.map((EpubBookRow b) => b.bookKey).toList(growable: false);
    // Seed: null (all) → every book ticked; otherwise the given subset.
    final Set<String> sel = current == null
        ? keys.toSet()
        : keys.where((String k) => current.contains(k)).toSet();

    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) {
          final HibikiDesignTokens tokens = HibikiDesignTokens.of(ctx);
          return HibikiDialogFrame(
            maxWidth: 460,
            insetPadding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.card,
              vertical: tokens.spacing.card,
            ),
            scrollable: false,
            child: HibikiModalSheetFrame(
              title: t.backup_export_choose_books,
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
                  Row(
                    children: <Widget>[
                      Text('${sel.length} / ${keys.length}',
                          style: Theme.of(ctx).textTheme.bodySmall),
                      const Spacer(),
                      adaptiveDialogAction(
                        context: ctx,
                        onPressed: () => setLocal(() => sel
                          ..clear()
                          ..addAll(keys)),
                        child: Text(t.backup_export_select_all),
                      ),
                      adaptiveDialogAction(
                        context: ctx,
                        onPressed: () => setLocal(sel.clear),
                        child: Text(t.backup_export_select_none),
                      ),
                    ],
                  ),
                  for (final EpubBookRow b in books)
                    AdaptiveSettingsSwitchRow(
                      title: b.title,
                      value: sel.contains(b.bookKey),
                      onChanged: (bool v) => setLocal(() {
                        if (v) {
                          sel.add(b.bookKey);
                        } else {
                          sel.remove(b.bookKey);
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
    if (confirmed != true) return current;
    // "All ticked" collapses back to null so the export takes the legacy
    // full-book path (and stays correct if a book is added/removed later).
    if (sel.length == keys.length) return null;
    return sel;
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

/// How a backup is applied (TODO-888). [overwrite] is the legacy behavior
/// (replace the whole DB + content trees); [merge] keeps everything on this
/// device and only ADDS what's missing from the backup (no overwrite/delete).
enum _BackupImportMode { overwrite, merge }

/// The user's choices from the import confirm dialog: which [mode] to apply and
/// (overwrite-only) whether to also pull the backup's settings layer.
class _BackupImportChoice {
  const _BackupImportChoice({required this.mode, required this.importSettings});
  final _BackupImportMode mode;
  final bool importSettings;
}

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
    // appModel 在 try 外声明：导入执行期 beginBackupImport 会切走本设置页（tree swap），
    // 此后 catch/finally 仍需经 appModel 驱动遮罩（不再依赖已卸载的本页 context）。
    final appModel = widget.settingsContext.appModel;
    try {
      final filePath = result.files.single.path!;
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

      // TODO-1195 part B: best-effort merge preview for the confirm dialog.
      // Runs against the still-open live DB; null on any failure → generic UI.
      final BackupMergePreview? mergePreview =
          await BackupService.previewMergeImport(
        liveDb: appModel.database,
        dbDirectory: appModel.databaseDirectory.path,
        zipPath: filePath,
      );
      if (!mounted) return;

      final _BackupImportChoice? choice =
          await _showConfirmDialog(meta, mergePreview);
      if (choice == null || !mounted) return;

      final String booksRoot =
          p.join(appModel.appDirectory.path, 'hoshi_books');
      final String audiobooksRoot =
          p.join(appModel.appDirectory.path, 'audiobooks');
      final String fontsRoot =
          p.join(appModel.appDirectory.path, 'custom_fonts');
      final String videosRoot = p.join(appModel.appDirectory.path, 'videos');

      // TODO-1151: 先上屏全屏「正在导入备份，请勿关闭」遮罩，再关库解压。beginBackupImport
      // notifyListeners → 根 widget 切到 BackupImportOverlayView（本设置页随之卸载，故此后
      // 不再依赖 `mounted`/本页 context，改由 appModel 驱动遮罩）。
      appModel.beginBackupImport();
      await appModel.closeDatabase();
      if (choice.mode == _BackupImportMode.merge) {
        // TODO-888 merge: keep this device's library + settings, only ADD what
        // the backup carries (row-level upsert + copy-if-absent content trees).
        // Never overwrites/deletes existing data, so importSettings is moot.
        await BackupService.mergeImportBackupFiles(
          dbDirectory: appModel.databaseDirectory.path,
          zipPath: filePath,
          dictionaryResourceDirectory:
              appModel.dictionaryResourceDirectory.path,
          booksRootDirectory: booksRoot,
          audiobooksRootDirectory: audiobooksRoot,
          fontsRootDirectory: fontsRoot,
          videosRootDirectory: videosRoot,
          // TODO-1183: 后台解压 isolate 经 SendPort 回报字节 → 确定进度条。
          onProgress: appModel.reportBackupImportProgress,
        );
      } else {
        await BackupService.importBackupFiles(
          dbDirectory: appModel.databaseDirectory.path,
          zipPath: filePath,
          importSettings: choice.importSettings,
          dictionaryResourceDirectory:
              appModel.dictionaryResourceDirectory.path,
          // Full-data restore: extract the content trees and rebase the DB's
          // absolute paths onto this device's roots.
          booksRootDirectory: booksRoot,
          audiobooksRootDirectory: audiobooksRoot,
          // BUG-183: restore the custom-font files and rebase the stored font
          // config paths onto this device's root.
          fontsRootDirectory: fontsRoot,
          videosRootDirectory: videosRoot,
          // TODO-1183: 后台解压 isolate 经 SendPort 回报字节 → 确定进度条。
          onProgress: appModel.reportBackupImportProgress,
        );
      }

      // TODO-1151: 导入成功。不再「延迟 500ms 后突然 exit」——那会让用户以为崩溃/失败。
      // 切到确认视图（导入完成 → 立即重启），由用户点按后经 backupImportRestart 退出。
      appModel.completeBackupImport(t.backup_import_success);
    } catch (e) {
      // TODO-1183: DB 已关闭，无论成败都必须重启；失败走 failBackupImport → 遮罩画红色
      // 错误图标 + 失败原因（根治 OOM/异常「失败却显绿✓成功」的误导）。
      appModel.failBackupImport(
        t.backup_import_failed(message: friendlySyncErrorDetail(e)),
      );
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  /// Asks how to apply the backup (TODO-888): OVERWRITE the whole library
  /// (legacy default) or MERGE into the current one. For overwrite, a secondary
  /// switch chooses whether to also pull the backup's settings layer. Returns
  /// the choice, or `null` if the user cancels.
  Future<_BackupImportChoice?> _showConfirmDialog(
    BackupMeta meta,
    BackupMergePreview? preview,
  ) async {
    final dateStr =
        '${meta.createdAt.year}-${meta.createdAt.month.toString().padLeft(2, '0')}-${meta.createdAt.day.toString().padLeft(2, '0')}';
    // Default: OVERWRITE (Never break userspace — the existing behavior), and
    // within overwrite, keep this device's settings (importSettings=false).
    _BackupImportMode mode = _BackupImportMode.overwrite;
    bool importSettings = false;
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
                  const SizedBox(height: 8),
                  Text(
                    t.backup_import_mode_label,
                    style: Theme.of(ctx).textTheme.labelLarge,
                  ),
                  RadioListTile<_BackupImportMode>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(t.backup_import_mode_overwrite),
                    value: _BackupImportMode.overwrite,
                    groupValue: mode,
                    onChanged: (_BackupImportMode? v) =>
                        setLocal(() => mode = v ?? _BackupImportMode.overwrite),
                  ),
                  RadioListTile<_BackupImportMode>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(t.backup_import_mode_merge),
                    subtitle: preview == null
                        ? null
                        : Text(
                            t.backup_import_merge_preview(
                              bookCount: preview.newBooks.toString(),
                              progressCount:
                                  preview.updatedReaderPositions.toString(),
                            ),
                            style: Theme.of(ctx).textTheme.bodySmall,
                          ),
                    value: _BackupImportMode.merge,
                    groupValue: mode,
                    onChanged: (_BackupImportMode? v) =>
                        setLocal(() => mode = v ?? _BackupImportMode.overwrite),
                  ),
                  // The settings-layer toggle only applies to overwrite; merge
                  // always keeps this device's settings.
                  if (mode == _BackupImportMode.overwrite) ...<Widget>[
                    const SizedBox(height: 4),
                    AdaptiveSettingsSwitchRow(
                      title: t.backup_import_settings_toggle,
                      subtitle: importSettings
                          ? t.backup_import_settings_on_hint
                          : t.backup_import_settings_off_hint,
                      value: importSettings,
                      onChanged: (bool v) => setLocal(() => importSettings = v),
                    ),
                  ],
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
                    isDestructiveAction: mode == _BackupImportMode.overwrite,
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
    if (confirmed != true) return null;
    return _BackupImportChoice(mode: mode, importSettings: importSettings);
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
