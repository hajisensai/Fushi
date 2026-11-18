import 'dart:async';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart';
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pdf/pdf_importer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/storage/orphan_book_recovery.dart';
import 'package:fushi/src/storage/storage_usage_service.dart'
    show formatStorageBytes;
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_error_messages.dart'
    show friendlySyncErrorDetail;
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show backupImportRestart;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 孤儿书目录按类型重新登记的生产装配：各导入器的 `register*`。放在页面层
/// 而非 storage 层——`PdfImporter` 的依赖闭包连到 AppModel，storage 层不得碰。
Map<OrphanBookKind, OrphanBookRegistrar> libraryRecoveryRegistrars() =>
    <OrphanBookKind, OrphanBookRegistrar>{
      OrphanBookKind.epub:
          ({
            required FushiDatabase db,
            required String bookKey,
            required String title,
            required String bookDir,
          }) => EpubImporter.registerExtractedBook(
            db: db,
            bookKey: bookKey,
            title: title,
            extractDir: bookDir,
          ),
      OrphanBookKind.manga: MangaImporter.registerExistingBookDir,
      OrphanBookKind.pdf: PdfImporter.registerExistingBookDir,
    };

/// 设置 › 存储 →「恢复书库」入口（BUG-4701）。
Future<void> openLibraryRecoveryPage(final SettingsContext c) =>
    Navigator.of(c.context).push<void>(
      adaptivePageRoute<void>(
        context: c.context,
        builder: (BuildContext context) =>
            LibraryRecoveryPage(appModel: c.appModel),
      ),
    );

/// 「恢复书库」页（BUG-4701）：覆盖导入把书库换掉之后的两条找回路径。
///
/// 1. **覆盖导入前的快照**：覆盖导入成功后保留的最近一份整库快照
///    （`BackupRestoreService.overwriteSnapshotPath`），可只补缺地把书库行、阅读进度、
///    统计并回当前库，或删掉它释放空间。
/// 2. **孤儿书目录**：书库根下有书文件、书库里却没有行的目录（[OrphanBookRecovery]），
///    按目录名重新登记，卡片来源重新连上；识别不了的列出原因并可删除。
class LibraryRecoveryPage extends StatefulWidget {
  const LibraryRecoveryPage({required this.appModel, super.key});

  final AppModel appModel;

  @override
  State<LibraryRecoveryPage> createState() => _LibraryRecoveryPageState();
}

class _LibraryRecoveryPageState extends State<LibraryRecoveryPage> {
  bool _loading = true;
  bool _busy = false;
  Object? _loadError;
  OverwriteSnapshotPreview? _snapshot;
  OrphanBookScan? _scan;
  OrphanBookRecovery? _recovery;

  AppModel get _app => widget.appModel;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final OrphanBookRecovery recovery = _recovery ??=
          await OrphanBookRecovery.forApp(
            _app.database,
            registrars: libraryRecoveryRegistrars(),
          );
      final OverwriteSnapshotPreview? snapshot =
          await BackupRestoreService.previewOverwriteSnapshot(
            dbDirectory: _app.databaseDirectory.path,
            liveDb: _app.database,
          );
      final OrphanBookScan scan = await recovery.scan();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _scan = scan;
        _loading = false;
      });
    } catch (e, st) {
      ErrorLogService.instance.log('LibraryRecoveryPage.load', e, st);
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  // ── 快照 ────────────────────────────────────────────────────────

  Future<void> _restoreSnapshot(OverwriteSnapshotPreview snapshot) async {
    // 书文件已不在盘上的书恢复时跳过（页面上单独列出），确认框只讲会发生什么。
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.storage_recovery_snapshot_restore,
      icon: FushiIcons.restoreBackup,
      confirmLabel: t.storage_recovery_snapshot_restore,
      message: t.storage_recovery_snapshot_confirm_body,
    );
    if (!confirmed || !mounted) return;
    // 与备份导入同一遮罩协议：上遮罩 → 等首帧 → 关库 → 合并 → 重启。
    final AppModel app = _app;
    try {
      app.beginBackupImport();
      await WidgetsBinding.instance.endOfFrame;
      await app.closeDatabase();
      await BackupRestoreService.mergeFromOverwriteSnapshot(
        dbDirectory: app.databaseDirectory.path,
      );
      app.completeBackupImport(t.storage_recovery_snapshot_success);
      await Future<void>.delayed(const Duration(seconds: 1));
      await backupImportRestart(app);
    } catch (e, st) {
      ErrorLogService.instance.log(
        'LibraryRecoveryPage.restoreSnapshot',
        e,
        st,
      );
      await ErrorLogService.instance.flush();
      app.failBackupImport(
        t.storage_recovery_snapshot_failed(reason: friendlySyncErrorDetail(e)),
      );
    }
  }

  Future<void> _deleteSnapshot(OverwriteSnapshotPreview snapshot) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.storage_recovery_snapshot_delete,
      message: t.storage_recovery_snapshot_delete_confirm,
      confirmLabel: t.storage_recovery_snapshot_delete,
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await File(snapshot.path).delete();
    } on FileSystemException catch (e) {
      FushiToast.show(
        msg: t.storage_entry_delete_failed(
          reason: e.osError?.message ?? e.message,
        ),
        severity: ToastSeverity.error,
      );
    }
    await _load();
  }

  // ── 孤儿目录 ─────────────────────────────────────────────────────

  Future<void> _restoreOrphans(List<RecoverableOrphanBook> books) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.storage_recovery_orphans_section,
      message: t.storage_recovery_orphans_confirm_body(n: books.length),
      confirmLabel: t.storage_recovery_orphans_restore_one,
      icon: FushiIcons.restoreBackup,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final OrphanBookRestoreResult result = await _recovery!.restore(books);
      for (final MapEntry<String, String> f in result.failures.entries) {
        ErrorLogService.instance.logDiagnostic(
          'LibraryRecoveryPage.restoreOrphan',
          '${f.key}: ${f.value}',
        );
      }
      FushiToast.show(
        msg: t.storage_recovery_orphans_result(
          ok: result.restored.length,
          failed: result.failures.length,
        ),
        severity: result.failures.isEmpty
            ? ToastSeverity.success
            : ToastSeverity.warning,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  Future<void> _deleteOrphan(UnrecoverableOrphanDirectory dir) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.storage_recovery_delete_folder,
      message: t.storage_recovery_delete_folder_confirm(
        name: dir.name,
        size: formatStorageBytes(dir.sizeBytes),
      ),
      confirmLabel: t.storage_recovery_delete_folder,
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await _recovery!.deleteDirectory(dir.directory);
    } catch (e) {
      FushiToast.show(
        msg: t.storage_entry_delete_failed(reason: '$e'),
        severity: ToastSeverity.error,
      );
    }
    await _load();
  }

  // ── 文案 ────────────────────────────────────────────────────────

  static String _kindLabel(OrphanBookKind kind) => switch (kind) {
    OrphanBookKind.epub => t.storage_recovery_kind_epub,
    OrphanBookKind.manga => t.storage_recovery_kind_manga,
    OrphanBookKind.pdf => t.storage_recovery_kind_pdf,
  };

  static IconData _kindIcon(OrphanBookKind kind) => switch (kind) {
    OrphanBookKind.manga => FushiIcons.manga,
    OrphanBookKind.epub || OrphanBookKind.pdf => FushiIcons.books,
  };

  /// 不可恢复原因的界面文案（纯函数，测试用）。
  @visibleForTesting
  static String issueLabel(UnrecoverableOrphanDirectory dir) =>
      switch (dir.issue) {
        OrphanBookIssue.emptyDirectory => t.storage_recovery_issue_empty,
        OrphanBookIssue.unrecognizedContent =>
          t.storage_recovery_issue_unrecognized,
        OrphanBookIssue.invalidBookKey => t.storage_recovery_issue_invalid_key,
        OrphanBookIssue.legacyNumericDirectory =>
          t.storage_recovery_issue_legacy_numeric,
        OrphanBookIssue.duplicateSuffixDirectory =>
          t.storage_recovery_issue_duplicate_suffix,
        OrphanBookIssue.onlineManga => t.storage_recovery_issue_online_manga,
        OrphanBookIssue.unreadable => t.storage_recovery_issue_unreadable(
          detail: dir.detail ?? '',
        ),
      };

  // ── 视图 ────────────────────────────────────────────────────────

  Widget _sectionTitle(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(left: 4, top: 4),
    child: Text(text, style: context.fushiType.titleSmallEmphasized),
  );

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Text(text),
  );

  Widget _pressable({required Widget child}) => FushiPressScale(child: child);

  List<Widget> _snapshotSection(BuildContext context) {
    final OverwriteSnapshotPreview? snapshot = _snapshot;
    if (snapshot == null) {
      return <Widget>[
        _sectionTitle(context, t.storage_recovery_snapshot_section),
        _hint(t.storage_recovery_snapshot_none),
      ];
    }
    final bool hasWork = snapshot.hasRestorableContent;
    final List<OverwriteSnapshotBook> noFiles = snapshot.booksWithoutFiles;
    return <Widget>[
      _sectionTitle(context, t.storage_recovery_snapshot_section),
      FushiGroupedList(
        children: <Widget>[
          FushiListItem(
            leading: const FushiIcon(FushiIcons.history),
            title: Text(
              t.storage_recovery_snapshot_info(
                time: FushiTimeFormat.dateHourMinute(snapshot.createdAt),
                size: formatStorageBytes(snapshot.sizeBytes),
              ),
            ),
            subtitle: Text(
              hasWork
                  ? t.storage_recovery_snapshot_missing(
                      books: snapshot.restorableBooks.length,
                      videos: snapshot.missingVideoCount,
                    )
                  : t.storage_recovery_snapshot_nothing,
            ),
          ),
        ],
      ),
      _hint(
        t.storage_recovery_snapshot_expires(
          date: FushiTimeFormat.dayKey(snapshot.expiresAt),
        ),
      ),
      if (noFiles.isNotEmpty)
        _hint(
          t.storage_recovery_snapshot_files_missing(
            titles: noFiles.map((OverwriteSnapshotBook b) => b.title).join('、'),
          ),
        ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          _pressable(
            child: FushiFilledButton.icon(
              key: const ValueKey<String>('library-recovery-snapshot-restore'),
              onPressed: hasWork && !_busy
                  ? () => unawaited(_restoreSnapshot(snapshot))
                  : null,
              icon: const FushiIcon(FushiIcons.restoreBackup),
              label: Text(t.storage_recovery_snapshot_restore),
            ),
          ),
          _pressable(
            child: FushiOutlinedButton.icon(
              key: const ValueKey<String>('library-recovery-snapshot-delete'),
              onPressed: _busy
                  ? null
                  : () => unawaited(_deleteSnapshot(snapshot)),
              icon: const FushiIcon(FushiIcons.delete),
              label: Text(t.storage_recovery_snapshot_delete),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _orphanSection(BuildContext context) {
    final OrphanBookScan scan = _scan!;
    final List<RecoverableOrphanBook> books = scan.recoverable;
    return <Widget>[
      _sectionTitle(context, t.storage_recovery_orphans_section),
      _hint(
        books.isEmpty
            ? t.storage_recovery_orphans_empty
            : t.storage_recovery_orphans_hint,
      ),
      if (books.isNotEmpty) ...<Widget>[
        FushiGroupedList(
          children: <Widget>[
            for (int i = 0; i < books.length; i++)
              FushiStaggeredEntrance(
                key: ValueKey<String>('orphan-${books[i].bookKey}'),
                index: i,
                child: FushiListItem(
                  leading: FushiIcon(_kindIcon(books[i].kind)),
                  title: Text(books[i].title),
                  subtitle: Text(
                    <String>[
                      _kindLabel(books[i].kind),
                      if (books[i].previouslyDeleted)
                        t.storage_recovery_orphans_previously_deleted,
                    ].join(' · '),
                  ),
                  trailing: _pressable(
                    child: FushiTextButton(
                      onPressed: _busy
                          ? null
                          : () => unawaited(
                              _restoreOrphans(<RecoverableOrphanBook>[
                                books[i],
                              ]),
                            ),
                      child: Text(t.storage_recovery_orphans_restore_one),
                    ),
                  ),
                ),
              ),
          ],
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: _pressable(
            child: FushiFilledButton.icon(
              key: const ValueKey<String>('library-recovery-orphans-all'),
              onPressed: _busy ? null : () => unawaited(_restoreOrphans(books)),
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: FushiCircularProgressIndicator(strokeWidth: 2),
                    )
                  : const FushiIcon(FushiIcons.restoreBackup),
              label: Text(
                t.storage_recovery_orphans_restore_all(n: books.length),
              ),
            ),
          ),
        ),
      ],
      if (scan.unrecoverable.isNotEmpty) ...<Widget>[
        _sectionTitle(context, t.storage_recovery_unrecoverable_section),
        FushiGroupedList(
          children: <Widget>[
            for (int i = 0; i < scan.unrecoverable.length; i++)
              FushiStaggeredEntrance(
                key: ValueKey<String>(
                  'unrecoverable-${scan.unrecoverable[i].name}',
                ),
                index: books.length + i,
                child: FushiListItem(
                  leading: const FushiIcon(FushiIcons.warning),
                  title: Text(scan.unrecoverable[i].name),
                  subtitle: Text(
                    '${issueLabel(scan.unrecoverable[i])} · '
                    '${formatStorageBytes(scan.unrecoverable[i].sizeBytes)}',
                  ),
                  subtitleMaxLines: 3,
                  trailing: FushiIconButtonControl(
                    tooltip: t.storage_recovery_delete_folder,
                    icon: const FushiIcon(FushiIcons.delete),
                    onPressed: _busy
                        ? null
                        : () => unawaited(_deleteOrphan(scan.unrecoverable[i])),
                  ),
                ),
              ),
          ],
        ),
      ],
    ];
  }

  Widget _buildBody(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gutter = tokens.spacing.page;
    if (_loading && _scan == null) {
      return const Center(child: FushiCircularProgressIndicator());
    }
    final Object? error = _loadError;
    if (error != null) {
      return SafeArea(
        bottom: false,
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.error,
            tone: FushiPlaceholderTone.error,
            message: t.error_load_failed,
            detail: '$error',
            action: FushiFilledButton.tonalIcon(
              onPressed: () => unawaited(_load()),
              icon: const FushiIcon(FushiIcons.refresh),
              label: Text(t.retry),
            ),
          ),
        ),
      );
    }
    final List<Widget> sections = <Widget>[
      ..._snapshotSection(context),
      const SizedBox(height: 8),
      ..._orphanSection(context),
    ];
    return FushiEntranceScope(
      child: ListView.separated(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            gutter,
            8 + MediaQuery.paddingOf(context).top,
            gutter,
            tokens.spacing.section,
          ),
        ),
        itemCount: sections.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(height: 12),
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => sections[index],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: t.storage_recovery_title,
      actions: <Widget>[
        FushiIconButton(
          icon: FushiIcons.refresh,
          tooltip: t.retry,
          enabled: !_busy && !_loading,
          onTap: () => unawaited(_load()),
        ),
      ],
      body: Builder(builder: _buildBody),
    );
  }
}
