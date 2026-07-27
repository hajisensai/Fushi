// GENERATED-NOTE: extracted from sync_settings_schema.dart (TODO-585).
part of '../sync_settings_schema.dart';

// Local backup export / import widgets + default category set.
// Shares the parent library's imports + private scope (_syncSettings / _showSnackBar / _SyncSettingsState); moved verbatim.

@visibleForTesting
Set<BackupCategory> defaultBackupExportCategories() => BackupCategory.values
    .where((BackupCategory c) =>
        c != BackupCategory.videos && c != BackupCategory.localAudio)
    .toSet();

/// Localised display name for a backup [category] (TODO-1358). Shared by the
/// export picker and the import "what is inside / choose what to restore" list.
String backupCategoryLabel(BackupCategory category) {
  switch (category) {
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

/// One-line "what is it" description for a backup [category] (TODO-1358), shown
/// as the subtitle in the export/import content manifests.
String backupCategoryDescription(BackupCategory category) {
  switch (category) {
    case BackupCategory.dictionary:
      return t.backup_category_dictionary_desc;
    case BackupCategory.books:
      return t.backup_category_books_desc;
    case BackupCategory.audiobooks:
      return t.backup_category_audiobooks_desc;
    case BackupCategory.fonts:
      return t.backup_category_fonts_desc;
    case BackupCategory.videos:
      return t.backup_category_videos_desc;
    case BackupCategory.localAudio:
      return t.backup_category_local_audio_desc;
    case BackupCategory.progress:
      return t.backup_category_progress_desc;
    case BackupCategory.statistics:
      return t.backup_category_statistics_desc;
    case BackupCategory.settings:
      return t.backup_category_settings_desc;
    case BackupCategory.profiles:
      return t.backup_category_profiles_desc;
  }
}

/// Every content category the user can individually skip on import (TODO-1358).
/// Both modes now honour the full set: overwrite strips the unticked category's
/// rows/files from the swapped-in DB ([BackupService.restoreBackup]); merge
/// skips its per-category engine steps + content-tree copy
/// ([BackupService.mergeRestoreBackup]). settings / profiles stay governed
/// by the separate "import settings and profiles" toggle (overwrite) / kept
/// local (merge), so they are not listed here.
const Set<BackupCategory> importSelectableCategories = <BackupCategory>{
  BackupCategory.dictionary,
  BackupCategory.books,
  BackupCategory.audiobooks,
  BackupCategory.fonts,
  BackupCategory.videos,
  BackupCategory.localAudio,
  BackupCategory.progress,
  BackupCategory.statistics,
};

/// Merge uses the same full selectable set as overwrite now.
const Set<BackupCategory> importMergeSelectableCategories =
    importSelectableCategories;

/// TODO-1151：备份导入完成后的重启。DB 已在导入期 `closeDatabase()`，必须重启才能重载
/// 新数据。既作为 [BackupImportOverlayView]「立即重启」按钮的手动出口，也在导入**成功**后由
/// [_BackupImportWidgetState._import] 延时自动调用（用户诉求「导入完自动重启，不再手动重开」）。
///
/// **优先真重启**：委托 `lifecycle.restartApp()`——与数据根迁移成功路径同一条经过验证的重启
/// 实现（桌面 detached 拉新进程 + 带 `--hibiki-restarted` 前台标志避免黑窗、macOS 经
/// `open -n <bundle>` 规避直接起可执行文件在 Dart 启动前崩、移动端 `restart_app` 插件；三端
/// `supportsRestart==true`）。消除了旧实现在本文件里 ad-hoc `Process.start(resolvedExecutable)`
/// 的劣质重复（缺前台标志、macOS 会崩）。
/// **兜底 never-break**：`restartApp` 起新进程失败或平台不支持时，退回旧的纯退出分支（移动端
/// [FlutterExitApp.exitApp]、桌面端 `exit(0)`），至少让用户手动重开，绝不制造「老进程没了、新
/// 进程也没起来」的假崩溃。抽成顶层函数供 `main.dart` 注入为 `onRestart`。
Future<void> backupImportRestart(AppModel appModel) async {
  final PlatformLifecycleService lifecycle =
      appModel.platformServices.lifecycle;
  if (lifecycle.supportsRestart) {
    try {
      await lifecycle.restartApp();
      // restartApp 成功会拉新进程并退出本进程，正常不会执行到这里。
      return;
    } catch (e) {
      // 起新进程失败 → 落到下面的纯退出兜底（用户手动重开），不把失败吞成假成功。
      debugPrint('Backup import: restartApp failed, fall back to exit: $e');
    }
  }
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

  /// Per-video export selection (books analogue). null = every video (legacy
  /// full export); a non-null set = only those `video_books.book_uid`s travel.
  /// Persists across dialog opens within this settings session; only consulted
  /// when the Videos category is selected.
  Set<String>? _selectedVideoKeys;

  Future<void> _export() async {
    // Re-entrant guard: the row's Activate (A/Enter) and the trailing button
    // both call this, so ignore a second trigger while an export is running.
    if (_isExporting) return;
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
      audiobooksRootDirectory: p.join(appModel.appDirectory.path, 'audiobooks'),
      // BUG-183: pack the imported custom fonts so they travel with their
      // config; otherwise the restored config points at files that never
      // crossed over and the fonts silently never apply.
      fontsRootDirectory: p.join(appModel.appDirectory.path, 'custom_fonts'),
    );
    // TODO-1358: summarize what is on this device so the category picker shows
    // per-category counts (the database itself is always included).
    final BackupContentSummary summary = await service.summarizeLiveContent();
    if (!mounted) return;
    // Ask which sidecar trees to include (default all). Null = the user
    // cancelled the dialog -> abort the export entirely (TODO-106).
    final Set<BackupCategory>? categories =
        await _pickExportCategories(summary);
    if (categories == null || !mounted) return;
    setState(() => _isExporting = true);
    try {
      final tmpDir = await getTemporaryDirectory();
      final filename = service.defaultFilename();
      final tmpPath = p.join(tmpDir.path, filename);
      final tmpFile = File(tmpPath);
      // Per-book selection (TODO-1195 part A) only applies when the Books
      // category is packed; excluding Books strips every book regardless.
      await service.createBackup(
        tmpPath,
        categories: categories,
        bookKeys: categories.contains(BackupCategory.books)
            ? _selectedBookKeys
            : null,
        videoKeys: categories.contains(BackupCategory.videos)
            ? _selectedVideoKeys
            : null,
      );

      if (!mounted) return;

      if (Platform.isAndroid || Platform.isIOS) {
        await HibikiShare.shareFiles(
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
  Future<Set<BackupCategory>?> _pickExportCategories(
      BackupContentSummary summary) async {
    final Set<BackupCategory> selected = defaultBackupExportCategories();
    assert(!selected.contains(BackupCategory.videos));
    assert(!selected.contains(BackupCategory.localAudio));
    // Per-book selection (TODO-1195 part A). Mutated by the nested book picker;
    // written back to [_selectedBookKeys] only when the dialog is confirmed.
    Set<String>? chosenBooks = _selectedBookKeys;
    // Per-video selection (the books analogue). Mutated by the nested video
    // picker; written back to [_selectedVideoKeys] only on confirm.
    Set<String>? chosenVideos = _selectedVideoKeys;
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
                  // Each category is a toggle; the Books/Videos toggles carry a
                  // nested per-item picker glued DIRECTLY beneath them (not
                  // floated to the list bottom) so "选择书籍/选择视频" reads as a
                  // sub-option of its category instead of a duplicate top row.
                  for (final BackupCategory c
                      in BackupCategory.values) ...<Widget>[
                    AdaptiveSettingsSwitchRow(
                      title: labelFor(c),
                      subtitle: summary.counts.containsKey(c)
                          ? '${backupCategoryDescription(c)} '
                              '(${summary.countFor(c)})'
                          : backupCategoryDescription(c),
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
                    if (c == BackupCategory.books &&
                        selected.contains(BackupCategory.books))
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
                    // Per-video selection row (books analogue): only meaningful
                    // when the Videos category itself is packed.
                    if (c == BackupCategory.videos &&
                        selected.contains(BackupCategory.videos))
                      AdaptiveSettingsRow(
                        title: t.backup_export_choose_videos,
                        subtitle: chosenVideos == null
                            ? t.backup_export_videos_all
                            : t.backup_export_videos_selected(
                                count: chosenVideos!.length.toString()),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final Set<String>? picked =
                              await _pickVideos(chosenVideos);
                          setLocal(() => chosenVideos = picked);
                        },
                      ),
                  ],
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
    // Commit the per-book / per-video selection only on confirm (cancel leaves
    // them as-was).
    _selectedBookKeys = chosenBooks;
    _selectedVideoKeys = chosenVideos;
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
                  // BUG-1177：计数 + 全选/全不选原先是 Row + Spacer，在窄屏对话框里
                  // （文案更长的语言、四位数计数）三者相加超过可用宽 → RenderFlex
                  // overflow。改 Wrap：放得下仍是「计数左、按钮右」，放不下就换行。
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: <Widget>[
                      Text('${sel.length} / ${keys.length}',
                          style: Theme.of(ctx).textTheme.bodySmall),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: <Widget>[
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

  /// Nested picker for per-video export (books analogue). Loads the video
  /// library and lets the user tick which videos travel; [current] seeds the
  /// initial state (null = every video). Returns the chosen set, collapsing
  /// "all ticked" back to null (the legacy full-export path), or [current]
  /// unchanged on cancel.
  Future<Set<String>?> _pickVideos(Set<String>? current) async {
    final List<VideoBookRow> videos =
        await widget.settingsContext.appModel.database.allVideoBooks();
    // State.context guarded by State.mounted (coherent for the lint): the
    // settings page may have unmounted while the library loaded.
    if (!mounted) return current;
    if (videos.isEmpty) {
      _showSnackBar(context, t.backup_export_no_videos);
      return current;
    }
    final List<String> keys =
        videos.map((VideoBookRow v) => v.bookUid).toList(growable: false);
    // Seed: null (all) → every video ticked; otherwise the given subset.
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
              title: t.backup_export_choose_videos,
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
                  // BUG-1177：计数 + 全选/全不选原先是 Row + Spacer，在窄屏对话框里
                  // （文案更长的语言、四位数计数）三者相加超过可用宽 → RenderFlex
                  // overflow。改 Wrap：放得下仍是「计数左、按钮右」，放不下就换行。
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: <Widget>[
                      Text('${sel.length} / ${keys.length}',
                          style: Theme.of(ctx).textTheme.bodySmall),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: <Widget>[
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
                    ],
                  ),
                  for (final VideoBookRow v in videos)
                    AdaptiveSettingsSwitchRow(
                      title: v.title,
                      value: sel.contains(v.bookUid),
                      onChanged: (bool tick) => setLocal(() {
                        if (tick) {
                          sel.add(v.bookUid);
                        } else {
                          sel.remove(v.bookUid);
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
    // full-video path (and stays correct if a video is added/removed later).
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
  const _BackupImportChoice({
    required this.mode,
    required this.importSettings,
    required this.categories,
  });
  final _BackupImportMode mode;
  final bool importSettings;

  /// Categories to RESTORE on an overwrite import (TODO-1358): every
  /// always-restored category plus the selectable ones the user kept ticked.
  /// Forwarded to [BackupService.restoreBackup]; ignored for merge.
  final Set<BackupCategory> categories;
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
    // appModel 在遮罩流程外声明：validating/running 遮罩都会切走本设置页（tree swap），
    // 此后不再依赖已卸载的本页 `mounted`/context，全程经 appModel 驱动遮罩；确认对话框也
    // 改由全局 [AppModel.navigatorKey] 宿主弹出（退出遮罩、切回正常 app 树后再弹）。
    final AppModel appModel = widget.settingsContext.appModel;
    final String filePath = result.files.single.path!;

    // TODO-1151: 先上屏「正在读取备份…」全屏遮罩（validating 相位），再跑 validate + 合并
    // 预览——大 zip 这段要数十秒，旧版只有设置行 24px 小圈无明显反馈。beginBackupValidating
    // 返回本轮 token；用户点「取消」或新一轮校验会作废它，in-flight 后台 isolate 结果回来
    // 时用 isBackupValidatingCurrent 判断是否仍是最新，陈旧结果直接丢弃（干净 token 判定）。
    final int validatingToken = appModel.beginBackupValidating();
    BackupMeta? meta;
    BackupMergePreview? mergePreview;
    BackupContentSummary? summary;
    try {
      final service = BackupService(
        db: appModel.database,
        dbDirectory: appModel.databaseDirectory.path,
        dictionaryResourceDirectory: appModel.dictionaryResourceDirectory.path,
        appVersion: appModel.packageInfo.version,
      );

      final BackupMeta? validated = await service.validateBackup(filePath);
      // 已取消/被新一轮校验取代 → 丢弃陈旧结果（遮罩已由 cancel 退出，无需再动）。
      if (!appModel.isBackupValidatingCurrent(validatingToken)) return;
      if (validated == null) {
        await _endValidatingThenSnack(appModel, t.backup_import_invalid);
        if (mounted) setState(() => _isImporting = false);
        return;
      }
      if (validated.schemaVersion > appModel.database.schemaVersion) {
        await _endValidatingThenSnack(
          appModel,
          t.backup_schema_newer(version: validated.schemaVersion.toString()),
        );
        if (mounted) setState(() => _isImporting = false);
        return;
      }

      // TODO-1195 part B: best-effort merge preview for the confirm dialog.
      // Runs against the still-open live DB; null on any failure → generic UI.
      final BackupMergePreview? preview =
          await BackupService.previewMergeRestore(
        liveDb: appModel.database,
        dbDirectory: appModel.databaseDirectory.path,
        zipPath: filePath,
      );
      if (!appModel.isBackupValidatingCurrent(validatingToken)) return;
      // TODO-1358: read the archive "what is inside" manifest for the confirm
      // dialog (per-category counts + the restore toggles). Cheap central-dir
      // read; an empty summary just hides the manifest.
      final BackupContentSummary contentSummary =
          await service.summarizeBackupFile(filePath);
      if (!appModel.isBackupValidatingCurrent(validatingToken)) return;
      meta = validated;
      mergePreview = preview;
      summary = contentSummary;
    } catch (e) {
      // validate/preview 阶段异常：DB 仍打开，无需重启进程。作废本轮、退出遮罩回设置页并
      // 提示（与 running 阶段的 failBackupImport「必须重启」出口区分）。
      if (appModel.isBackupValidatingCurrent(validatingToken)) {
        await _endValidatingThenSnack(
          appModel,
          t.backup_import_failed(message: friendlySyncErrorDetail(e)),
        );
      }
      if (mounted) setState(() => _isImporting = false);
      return;
    }

    // 校验成功、合并预览就绪：退出 validating 遮罩，等根 widget 切回正常 app 树、全局
    // navigator 重新挂载后，在其 context 上弹确认对话框（本设置页此刻已卸载，不能用本页
    // context——遮罩是根 build 替换模型，宿主是 appModel.navigatorKey 的正常 MaterialApp）。
    appModel.endBackupValidating();
    final BuildContext? rootCtx = await _rootContextAfterOverlay(appModel);
    if (rootCtx == null || !rootCtx.mounted) {
      if (mounted) setState(() => _isImporting = false);
      return;
    }

    final _BackupImportChoice? choice =
        await _showConfirmDialog(rootCtx, meta, mergePreview, summary);
    if (choice == null) {
      // 用户取消确认 → 彻底退出遮罩态，回到设置页（validating 遮罩已退出）。
      if (mounted) setState(() => _isImporting = false);
      return;
    }

    final String booksRoot = p.join(appModel.appDirectory.path, 'hoshi_books');
    final String audiobooksRoot =
        p.join(appModel.appDirectory.path, 'audiobooks');
    final String fontsRoot = p.join(appModel.appDirectory.path, 'custom_fonts');
    final String videosRoot = p.join(appModel.appDirectory.path, 'videos');

    try {
      // TODO-1151: 用户已确认 → 上屏全屏「正在导入备份，请勿关闭」遮罩（running 相位），
      // 再关库解压。beginBackupImport notifyListeners → 根 widget 切到 running 遮罩（本
      // 设置页随之卸载，故此后不再依赖 `mounted`/本页 context，改由 appModel 驱动遮罩）。
      appModel.beginBackupImport();
      // BUG-810: beginBackupImport 只 SCHEDULE 根切换到 running 遮罩（notifyListeners →
      // markNeedsBuild）。上面注释承诺「遮罩已上屏 → 关库 → 解压」，但不等这帧渲染就直接
      // closeDatabase + restoreBackup 的部分同步 decode/DB 工作，会在遮罩首帧 raster
      // 前占住 UI isolate（await 微任务不 pump 帧）——于是整个复制期屏幕停在旧设置页，没有
      // 「请勿关闭」遮罩、没有进度条，直到进程重启。await endOfFrame 等这帧真正把遮罩画出来
      // 再继续（复用 validating→app 切换 [_rootContextAfterOverlay] 已依赖的同一原语）。
      await WidgetsBinding.instance.endOfFrame;
      await appModel.closeDatabase();
      if (choice.mode == _BackupImportMode.merge) {
        // TODO-888 merge: keep this device's library + settings, only ADD what
        // the backup carries (row-level upsert + copy-if-absent content trees).
        // Never overwrites/deletes existing data, so importSettings is moot.
        await BackupService.mergeRestoreBackup(
          dbDirectory: appModel.databaseDirectory.path,
          zipPath: filePath,
          // Per-category merge selection (merge mode now honours the dialog's
          // toggles): an unticked category adds neither rows nor files.
          categories: choice.categories,
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
        await BackupService.restoreBackup(
          dbDirectory: appModel.databaseDirectory.path,
          zipPath: filePath,
          importSettings: choice.importSettings,
          categories: choice.categories,
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
      // 切到确认视图（导入完成 → 立即重启），并在其可见 ~1s 后自动重启（用户诉求「导入完
      // 自动重启，不再手动重开」）。与旧「500ms 后突然 exit」的关键区别：backupImportRestart
      // 走 restartApp 真拉新进程重启（app 会自己回来），不是纯退出「凭空消失」；延时让「导入
      // 成功」先可见一瞬，避免误判失败。「立即重启」按钮保留为手动兜底（可提前点，走同一函数）。
      appModel.completeBackupImport(t.backup_import_success);
      await Future<void>.delayed(const Duration(seconds: 1));
      // restartApp 成功会拉新进程并退出本进程；backupImportRestart 内部已吞掉重启失败并退回
      // 纯退出兜底，故此处不会把「重启失败」冒泡成 catch 里的 failBackupImport（避免把成功的
      // 导入错报为失败）。
      await backupImportRestart(appModel);
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

  /// 退出 validating 遮罩后，等根 widget 切回正常 app 树、全局 navigator 重新挂载，返回
  /// 可用于弹对话框 / snackbar 的 root context（挂载失败返回 null）。endBackupValidating 的
  /// notifyListeners 触发的根重建在下一帧完成，故须等帧后 navigatorKey.currentContext 才有效。
  Future<BuildContext?> _rootContextAfterOverlay(AppModel appModel) async {
    for (int i = 0; i < 2; i++) {
      await WidgetsBinding.instance.endOfFrame;
      final BuildContext? ctx = appModel.navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) return ctx;
    }
    return null;
  }

  /// validate/preview 阶段的失败/无效出口：退出 validating 遮罩、切回设置页后用 root
  /// context 弹 snackbar（本设置页此刻已卸载，用本页 context 无效）。
  Future<void> _endValidatingThenSnack(
      AppModel appModel, String message) async {
    appModel.endBackupValidating();
    final BuildContext? rootCtx = await _rootContextAfterOverlay(appModel);
    if (rootCtx != null && rootCtx.mounted) _showSnackBar(rootCtx, message);
  }

  /// Asks how to apply the backup (TODO-888): OVERWRITE the whole library
  /// (legacy default) or MERGE into the current one. For overwrite, a secondary
  /// switch chooses whether to also pull the backup's settings layer. Returns
  /// the choice, or `null` if the user cancels.
  Future<_BackupImportChoice?> _showConfirmDialog(
    BuildContext dialogContext,
    BackupMeta meta,
    BackupMergePreview? preview,
    BackupContentSummary summary,
  ) async {
    final String dateStr = HibikiTimeFormat.dayKey(meta.createdAt);
    // Default: OVERWRITE (Never break userspace — the existing behavior), and
    // within overwrite, keep this device's settings (importSettings=false).
    _BackupImportMode mode = _BackupImportMode.overwrite;
    bool importSettings = false;
    // TODO-1358: the selectable content categories this backup actually carries,
    // all ticked by default; unticking one skips restoring it. The set differs
    // by mode — merge can additionally gate books/statistics (row-level), which
    // the overwrite whole-DB-blob path cannot. Iterated in enum order for a
    // stable layout. [selectedRestore] seeds from the UNION so a tick survives a
    // mode switch.
    List<BackupCategory> presentFor(Set<BackupCategory> selectable) =>
        BackupCategory.values
            .where(
                (BackupCategory c) => selectable.contains(c) && summary.has(c))
            .toList();
    final List<BackupCategory> overwriteSelectablePresent =
        presentFor(importSelectableCategories);
    final List<BackupCategory> mergeSelectablePresent =
        presentFor(importMergeSelectableCategories);
    final Set<BackupCategory> selectedRestore = <BackupCategory>{
      ...overwriteSelectablePresent,
      ...mergeSelectablePresent,
    };
    final bool? confirmed = await showAppDialog<bool>(
      context: dialogContext,
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
                  // TODO-1358: "what is inside" manifest + per-category toggles.
                  // Both modes are now live: untick a category to skip
                  // restoring/merging it. The selectable set is mode-dependent —
                  // merge can additionally gate books/statistics (row-level).
                  ...<Widget>[
                    if (mode == _BackupImportMode.overwrite
                        ? overwriteSelectablePresent.isNotEmpty
                        : mergeSelectablePresent.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        t.backup_import_contents_title,
                        style: Theme.of(ctx).textTheme.labelLarge,
                      ),
                      Text(
                        t.backup_import_contents_hint,
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                      for (final BackupCategory c
                          in mode == _BackupImportMode.overwrite
                              ? overwriteSelectablePresent
                              : mergeSelectablePresent)
                        AdaptiveSettingsSwitchRow(
                          title: '${backupCategoryLabel(c)} '
                              '(${summary.countFor(c)})',
                          subtitle: backupCategoryDescription(c),
                          value: selectedRestore.contains(c),
                          onChanged: (bool v) => setLocal(() {
                            if (v) {
                              selectedRestore.add(c);
                            } else {
                              selectedRestore.remove(c);
                            }
                          }),
                        ),
                    ],
                  ],
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
    // Everything not offered as a selectable toggle for THIS mode always
    // applies; add the selectable ones the user kept ticked (TODO-1358). The
    // selectable set is mode-dependent (merge can gate books/statistics too), so
    // an unticked merge-only category (books/statistics) is correctly dropped
    // from the set, while for overwrite those stay always-on.
    final Set<BackupCategory> modeSelectable =
        mode == _BackupImportMode.overwrite
            ? importSelectableCategories
            : importMergeSelectableCategories;
    final Set<BackupCategory> categories = BackupCategory.values
        .where((BackupCategory c) =>
            !modeSelectable.contains(c) || selectedRestore.contains(c))
        .toSet();
    return _BackupImportChoice(
      mode: mode,
      importSettings: importSettings,
      categories: categories,
    );
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
