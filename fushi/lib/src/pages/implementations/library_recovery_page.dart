import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, RestorePoint, RestorePointDatabase, RestorePointKind;
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart';
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart' show XFile;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pdf/pdf_importer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/storage/orphan_book_recovery.dart';
import 'package:fushi/src/storage/storage_usage_service.dart'
    show formatStorageBytes;
import 'package:fushi/src/sync/auto_backup/auto_backup_controller.dart'
    show
        kRestorePointReasonReplace,
        kRestorePointReasonSrsMigration,
        kRestorePointReasonSyncDownload;
import 'package:fushi/src/sync/auto_backup/restore_point_actions.dart';
import 'package:fushi/src/sync/auto_backup/restore_point_catalog.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_error_messages.dart'
    show friendlySyncErrorDetail;
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show backupCategoryLabel, restorePointUiFlowsFor;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
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
import 'package:fushi/src/utils/misc/fushi_share.dart';
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

/// 设置 › 存储 →「恢复书库」入口（BUG-4701）：同一个还原点页（孤儿书目录在页底）。
Future<void> openLibraryRecoveryPage(final SettingsContext c) =>
    openRestorePointsPage(c.context, c.appModel);

/// 设置 › 同步与备份 › 自动备份 →「还原点」入口。
Future<void> openRestorePointsPage(BuildContext context, AppModel appModel) =>
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) =>
            RestorePointsPage(appModel: appModel),
      ),
    );

/// 还原点页对宿主的全部依赖；生产实现是 [AppRestorePointsHost]，测试注入假宿主。
abstract interface class RestorePointsHost {
  /// 全部副本，新的在前（[listRestorePointEntries]）。同步：只列目录、读元数据。
  List<RestorePointEntry> listEntries();

  /// 删掉一行（[deleteRestorePointEntry]）。
  void deleteEntry(RestorePointEntry entry);

  /// 「补回缺少的内容」会补回什么（[previewRestorePointFillIn]）。
  Future<OverwriteSnapshotPreview?> previewFillIn(RestorePointEntry entry);

  /// 「补回缺少的内容」（全屏遮罩、关库、重启都在里面）。
  Future<void> fillIn(RestorePointEntry entry);

  /// 「替换」：拍不成操作前还原点 / 有备份在跑时抛出，什么都没动。
  Future<void> replace(RestorePointEntry entry);

  /// 导出到用户选的位置（桌面另存 / 移动端分享面板）；用户取消返回 false。
  Future<bool> export(RestorePointEntry entry);

  /// 孤儿书目录恢复；null = 不显示这一节。
  Future<OrphanBookRecovery?> orphanRecovery();
}

/// [RestorePointsHost] 的生产实现。
class AppRestorePointsHost implements RestorePointsHost {
  AppRestorePointsHost(this.app);

  final AppModel app;
  OrphanBookRecovery? _recovery;

  @override
  List<RestorePointEntry> listEntries() {
    final String? folder = app.autoBackupSettings.effectiveFolder(
      supportsCustomFolder:
          Platform.isWindows || Platform.isMacOS || Platform.isLinux,
    );
    return listRestorePointEntries(
      dbDirectory: app.databaseDirectory.path,
      extraRoots: <String>[?folder],
    );
  }

  @override
  void deleteEntry(RestorePointEntry entry) {
    deleteRestorePointEntry(entry);
    // 删的可能正是上次成功的那份：状态行的「保留 N 份」随之刷新。
    app.autoBackup.reloadStatus();
  }

  @override
  Future<OverwriteSnapshotPreview?> previewFillIn(RestorePointEntry entry) =>
      previewRestorePointFillIn(app, entry);

  @override
  Future<void> fillIn(RestorePointEntry entry) =>
      fillInFromRestorePoint(app, entry, restorePointUiFlowsFor(app));

  @override
  Future<void> replace(RestorePointEntry entry) =>
      replaceFromRestorePoint(app, entry, restorePointUiFlowsFor(app));

  @override
  Future<bool> export(RestorePointEntry entry) async {
    final String? source = restorePointExportSource(entry);
    if (source == null) {
      throw StateError('restore point ${entry.id} has nothing to export');
    }
    final String name = restorePointExportFileName(entry);
    final bool zip = name.endsWith('.zip');
    if (Platform.isAndroid || Platform.isIOS) {
      final bool shown = await FushiShare.shareFiles(<XFile>[
        XFile(
          source,
          name: name,
          mimeType: zip ? 'application/zip' : 'application/octet-stream',
        ),
      ], subject: name);
      if (!shown) throw StateError('the share sheet did not open');
      return true;
    }
    final String? savePath = await FilePicker.platform.saveFile(
      dialogTitle: t.restore_points_action_export,
      fileName: name,
      type: FileType.custom,
      allowedExtensions: <String>[if (zip) 'zip' else 'db'],
    );
    if (savePath == null) return false;
    await File(source).copy(savePath);
    return true;
  }

  @override
  Future<OrphanBookRecovery?> orphanRecovery() async =>
      _recovery ??= await OrphanBookRecovery.forApp(
        app.database,
        registrars: libraryRecoveryRegistrars(),
      );
}

/// 一行还原点的种类文案（纯函数，测试用）。
String restorePointKindLabel(RestorePointEntry entry) {
  switch (entry.source) {
    case RestorePointEntrySource.preOverwrite:
      return t.restore_points_kind_pre_overwrite;
    case RestorePointEntrySource.databaseCheck:
      return t.restore_points_kind_db_check;
    case RestorePointEntrySource.store:
      break;
  }
  return switch (entry.point!.kind) {
    RestorePointKind.preUpdate => t.restore_points_kind_pre_update,
    RestorePointKind.preRollback => t.restore_points_kind_pre_rollback,
    RestorePointKind.scheduled => t.restore_points_kind_scheduled,
    RestorePointKind.preOperation => switch (entry.point!.reason) {
      kRestorePointReasonReplace => t.restore_points_kind_before_replace,
      kRestorePointReasonSyncDownload =>
        t.restore_points_kind_before_sync_download,
      kRestorePointReasonSrsMigration =>
        t.restore_points_kind_before_srs_migration,
      _ => t.restore_points_kind_before_operation,
    },
  };
}

IconData _kindIcon(RestorePointEntry entry) => switch (entry.source) {
  RestorePointEntrySource.preOverwrite => FushiIcons.history,
  RestorePointEntrySource.databaseCheck => FushiIcons.storage,
  RestorePointEntrySource.store => switch (entry.point!.kind) {
    RestorePointKind.preUpdate => FushiIcons.download,
    RestorePointKind.preRollback => FushiIcons.undo,
    RestorePointKind.scheduled => FushiIcons.schedule,
    RestorePointKind.preOperation => FushiIcons.restoreBackup,
  },
};

BackupCategory? _categoryNamed(String name) {
  for (final BackupCategory c in BackupCategory.values) {
    if (c.name == name) return c;
  }
  return null;
}

/// 一行还原点的内容说明（纯函数，测试用）：整库定时备份写「整库 · 文件：…· 复习媒体」；老的按类别
/// 定时备份列类别与复习媒体；整库副本说明带了哪些库。
String restorePointContentsLabel(RestorePointEntry entry) {
  final List<String>? categories = entry.point?.categories;
  if (entry.point?.kind == RestorePointKind.scheduled &&
      entry.point!.fullDatabase == true) {
    final List<String> files = <String>[
      for (final BackupCategory c in BackupCategory.values)
        if (kBackupFileCategories.contains(c) &&
            (categories?.contains(c.name) ?? false))
          backupCategoryLabel(c),
    ];
    return <String>[
      t.restore_points_contents_full_db,
      if (files.isNotEmpty)
        t.restore_points_contents_files(categories: files.join('、')),
      entry.point!.includesSrsMedia == true
          ? t.restore_points_contents_with_media
          : t.restore_points_contents_without_media,
    ].join(' · ');
  }
  if (entry.point?.kind == RestorePointKind.scheduled && categories != null) {
    final List<String> labels = <String>[
      for (final String name in categories)
        if (_categoryNamed(name) case final BackupCategory c)
          backupCategoryLabel(c),
    ];
    final bool hasSrs = categories.contains(BackupCategory.srs.name);
    return <String>[
      labels.join('、'),
      if (hasSrs)
        entry.point!.includesSrsMedia == true
            ? t.restore_points_contents_with_media
            : t.restore_points_contents_without_media,
    ].join(' · ');
  }
  final bool hasMain = entry.rawMainDatabasePath != null;
  final bool hasSrs =
      entry.point?.rawDatabasePath(RestorePointDatabase.srs) != null;
  return <String>[
    if (hasMain) t.restore_points_contents_full_db,
    if (hasSrs) t.restore_points_contents_review_db,
  ].join(' · ');
}

/// 老的按类别定时备份里没带、「替换」后会从当前数据里移除的类别。整库定时备份（不移除任何
/// 数据，见 [restorePointFilesLeftAlone]）与其它种类为空。
List<BackupCategory> restorePointMissingCategories(RestorePointEntry entry) {
  final List<String>? categories = entry.point?.categories;
  if (entry.point?.kind != RestorePointKind.scheduled ||
      entry.point!.fullDatabase == true ||
      categories == null) {
    return const <BackupCategory>[];
  }
  final List<String>? excluded = entry.point!.excludedCategories;
  return <BackupCategory>[
    for (final BackupCategory c in BackupCategory.values)
      if (excluded != null
          ? excluded.contains(c.name)
          : !categories.contains(c.name))
        c,
  ];
}

/// 整库定时备份没带文件的文件类别：「替换」时这些文件在本机原样不动、对应的书库行照样留着。
/// 其它种类为空。
List<BackupCategory> restorePointFilesLeftAlone(RestorePointEntry entry) {
  final RestorePoint? point = entry.point;
  if (point == null ||
      point.kind != RestorePointKind.scheduled ||
      point.fullDatabase != true) {
    return const <BackupCategory>[];
  }
  final List<String> carried = point.categories ?? const <String>[];
  return <BackupCategory>[
    for (final BackupCategory c in BackupCategory.values)
      if (kBackupFileCategories.contains(c) && !carried.contains(c.name)) c,
  ];
}

/// 行内展开的确认面板种类。
enum _PanelKind { fill, replace, delete }

/// 「还原点」页（由「恢复书库」长成，docs/specs/2026-11-25-auto-backup-restore-points.md 第三层）。
///
/// 1. **还原点**：更新前、回滚前、定时、操作前还原点，加上存量的覆盖导入前快照与检查数据库备份
///    （[listRestorePointEntries]），每行可「补回缺少的内容」/「替换」/ 导出 / 删除。确认就地
///    展开在那一行下面（不弹框）：先说清楚会发生什么，再确认。
/// 2. **孤儿书目录**：书库根下有书文件、书库里却没有行的目录（[OrphanBookRecovery]），
///    按目录名重新登记，卡片来源重新连上；识别不了的列出原因并可删除（BUG-4701）。
class RestorePointsPage extends StatefulWidget {
  RestorePointsPage({required AppModel appModel, super.key})
    : host = AppRestorePointsHost(appModel);

  /// 注入宿主（测试）。
  const RestorePointsPage.withHost({required this.host, super.key});

  final RestorePointsHost host;

  @override
  State<RestorePointsPage> createState() => _RestorePointsPageState();
}

class _RestorePointsPageState extends State<RestorePointsPage> {
  bool _loading = true;
  bool _busy = false;
  Object? _loadError;
  List<RestorePointEntry> _entries = const <RestorePointEntry>[];
  OrphanBookScan? _scan;
  OrphanBookRecovery? _recovery;

  /// 展开着确认面板的那一行与面板种类（一次只开一个）。
  String? _openId;
  _PanelKind? _openKind;

  /// 「补回」面板的预览：加载中 / 失败 / 结果。
  bool _previewLoading = false;
  Object? _previewError;
  OverwriteSnapshotPreview? _preview;

  /// 面板的主按钮（确认，或只能关闭时的关闭）：面板一出现就把焦点给它（键盘 / 手柄可直接确认）。
  final FocusNode _panelFocus = FocusNode(debugLabel: 'restore-point-panel');

  RestorePointsHost get _host => widget.host;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _panelFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final List<RestorePointEntry> entries = _host.listEntries();
      final OrphanBookRecovery? recovery = _recovery ??= await _host
          .orphanRecovery();
      final OrphanBookScan? scan = await recovery?.scan();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _scan = scan;
        _loading = false;
        if (_openId != null &&
            !entries.any((RestorePointEntry e) => e.id == _openId)) {
          _closePanelState();
        }
      });
    } catch (e, st) {
      ErrorLogService.instance.log('RestorePointsPage.load', e, st);
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  // ── 还原点：行内确认面板 ─────────────────────────────────────────

  void _closePanelState() {
    _openId = null;
    _openKind = null;
    _previewLoading = false;
    _previewError = null;
    _preview = null;
  }

  void _closePanel() => setState(_closePanelState);

  void _focusPanelSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _panelFocus.context != null) _panelFocus.requestFocus();
    });
  }

  void _openPanel(RestorePointEntry entry, _PanelKind kind) {
    setState(() {
      _closePanelState();
      _openId = entry.id;
      _openKind = kind;
      _previewLoading = kind == _PanelKind.fill;
    });
    if (kind == _PanelKind.fill) {
      unawaited(_loadPreview(entry));
    } else {
      _focusPanelSoon();
    }
  }

  Future<void> _loadPreview(RestorePointEntry entry) async {
    OverwriteSnapshotPreview? preview;
    Object? error;
    try {
      preview = await _host.previewFillIn(entry);
    } catch (e, st) {
      ErrorLogService.instance.log('RestorePointsPage.preview', e, st);
      error = e;
    }
    if (!mounted || _openId != entry.id || _openKind != _PanelKind.fill) {
      return;
    }
    setState(() {
      _previewLoading = false;
      _preview = preview;
      _previewError = error;
    });
    _focusPanelSoon();
  }

  Future<void> _confirm(RestorePointEntry entry) async {
    final _PanelKind? kind = _openKind;
    if (kind == null || _busy) return;
    switch (kind) {
      case _PanelKind.delete:
        try {
          _host.deleteEntry(entry);
        } on FileSystemException catch (e) {
          FushiToast.show(
            msg: t.storage_entry_delete_failed(
              reason: e.osError?.message ?? e.message,
            ),
            severity: ToastSeverity.error,
          );
        }
        _closePanel();
        await _load();
      case _PanelKind.fill:
        setState(() => _busy = true);
        try {
          // 遮罩、关库、关库后的成败提示与重启都在里面；关库之前的失败（有备份在导出、从
          // zip 解主库失败）抛到这里，app 照常可用。
          await _host.fillIn(entry);
        } catch (e, st) {
          ErrorLogService.instance.log('RestorePointsPage.fillIn', e, st);
          FushiToast.show(
            msg: t.restore_points_fill_failed(
              reason: friendlySyncErrorDetail(e),
            ),
            severity: ToastSeverity.error,
          );
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      case _PanelKind.replace:
        setState(() => _busy = true);
        try {
          await _host.replace(entry);
        } catch (e, st) {
          // 操作前还原点没拍成 / 有备份在跑：什么都没替换。
          ErrorLogService.instance.log('RestorePointsPage.replace', e, st);
          FushiToast.show(
            msg: t.restore_points_replace_not_started(
              reason: friendlySyncErrorDetail(e),
            ),
            severity: ToastSeverity.error,
          );
        } finally {
          if (mounted) setState(() => _busy = false);
        }
    }
  }

  Future<void> _export(RestorePointEntry entry) async {
    setState(() => _busy = true);
    try {
      final bool done = await _host.export(entry);
      if (done) {
        FushiToast.show(
          msg: t.restore_points_export_done,
          severity: ToastSeverity.success,
        );
      }
    } catch (e, st) {
      ErrorLogService.instance.log('RestorePointsPage.export', e, st);
      FushiToast.show(
        msg: t.restore_points_export_failed(reason: friendlySyncErrorDetail(e)),
        severity: ToastSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
          'RestorePointsPage.restoreOrphan',
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

  static String _orphanKindLabel(OrphanBookKind kind) => switch (kind) {
    OrphanBookKind.epub => t.storage_recovery_kind_epub,
    OrphanBookKind.manga => t.storage_recovery_kind_manga,
    OrphanBookKind.pdf => t.storage_recovery_kind_pdf,
  };

  static IconData _orphanKindIcon(OrphanBookKind kind) => switch (kind) {
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

  static String _entryDetails(RestorePointEntry entry) {
    final String? version = entry.point?.appVersion;
    final int? schema = entry.schema;
    final String contents = restorePointContentsLabel(entry);
    return <String>[
      '${FushiTimeFormat.dateHourMinute(entry.createdAt)} · '
          '${formatStorageBytes(entry.sizeBytes)}',
      <String>[
        if (version != null && version.isNotEmpty)
          t.restore_points_app_version(version: version),
        if (schema != null && schema > 0) t.restore_points_schema(n: schema),
      ].join(' · '),
      contents,
      if (!entry.schemaSupported) t.restore_points_too_new,
    ].where((String line) => line.isNotEmpty).join('\n');
  }

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

  Widget _panelButtons(
    RestorePointEntry entry, {
    required bool canConfirm,
    bool destructive = false,
  }) {
    final String id = entry.id;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        if (canConfirm)
          _pressable(
            child: FushiFilledButton.icon(
              key: ValueKey<String>('restore-point-confirm-$id'),
              focusNode: _panelFocus,
              onPressed: _busy ? null : () => unawaited(_confirm(entry)),
              icon: FushiIcon(
                destructive ? FushiIcons.delete : FushiIcons.restoreBackup,
              ),
              label: Text(t.restore_points_confirm),
            ),
          ),
        _pressable(
          child: FushiTextButton(
            key: ValueKey<String>('restore-point-cancel-$id'),
            focusNode: canConfirm ? null : _panelFocus,
            onPressed: _busy ? null : _closePanel,
            child: Text(t.cancel),
          ),
        ),
      ],
    );
  }

  Widget _panel(RestorePointEntry entry) {
    switch (_openKind!) {
      case _PanelKind.delete:
        return FushiInlineNotice(
          key: ValueKey<String>('restore-point-panel-${entry.id}'),
          severity: FushiNoticeSeverity.warning,
          title: t.restore_points_action_delete,
          message: t.restore_points_delete_body,
          actionsInline: false,
          actions: <Widget>[
            _panelButtons(entry, canConfirm: true, destructive: true),
          ],
        );
      case _PanelKind.replace:
        final List<BackupCategory> missing = restorePointMissingCategories(
          entry,
        );
        final bool fullDatabase = entry.point?.fullDatabase == true;
        final List<BackupCategory> leftAlone = restorePointFilesLeftAlone(
          entry,
        );
        return FushiInlineNotice(
          key: ValueKey<String>('restore-point-panel-${entry.id}'),
          severity: FushiNoticeSeverity.warning,
          title: t.restore_points_action_replace,
          message: <String>[
            t.restore_points_replace_body(
              date: FushiTimeFormat.dateHourMinute(entry.createdAt),
            ),
            if (fullDatabase) t.restore_points_replace_full_db,
            if (leftAlone.isNotEmpty)
              t.restore_points_replace_files_kept(
                categories: leftAlone.map(backupCategoryLabel).join('、'),
              ),
            if (missing.isNotEmpty)
              t.restore_points_replace_removed(
                categories: missing.map(backupCategoryLabel).join('、'),
              ),
          ].join('\n\n'),
          actionsInline: false,
          actions: <Widget>[_panelButtons(entry, canConfirm: true)],
        );
      case _PanelKind.fill:
        if (_previewLoading) {
          return FushiInlineNotice(
            key: ValueKey<String>('restore-point-panel-${entry.id}'),
            title: t.restore_points_action_fill,
            message: t.restore_points_fill_loading,
            trailing: const SizedBox.square(
              dimension: 20,
              child: FushiCircularProgressIndicator(strokeWidth: 2),
            ),
            actionsInline: false,
            actions: <Widget>[_panelButtons(entry, canConfirm: false)],
          );
        }
        final Object? error = _previewError;
        if (error != null) {
          return FushiInlineNotice(
            key: ValueKey<String>('restore-point-panel-${entry.id}'),
            severity: FushiNoticeSeverity.error,
            title: t.restore_points_action_fill,
            message: t.restore_points_fill_preview_failed(
              reason: friendlySyncErrorDetail(error),
            ),
            actionsInline: false,
            actions: <Widget>[_panelButtons(entry, canConfirm: false)],
          );
        }
        final OverwriteSnapshotPreview? preview = _preview;
        if (preview == null || !preview.hasRestorableContent) {
          return FushiInlineNotice(
            key: ValueKey<String>('restore-point-panel-${entry.id}'),
            title: t.restore_points_action_fill,
            message: t.restore_points_fill_nothing,
            actionsInline: false,
            actions: <Widget>[_panelButtons(entry, canConfirm: false)],
          );
        }
        final List<OverwriteSnapshotBook> noFiles = preview.booksWithoutFiles;
        return FushiInlineNotice(
          key: ValueKey<String>('restore-point-panel-${entry.id}'),
          title: t.restore_points_action_fill,
          message: <String>[
            t.restore_points_fill_missing(
              books: preview.restorableBooks.length,
              videos: preview.missingVideoCount,
            ),
            if (noFiles.isNotEmpty)
              t.restore_points_fill_files_missing(
                titles: noFiles
                    .map((OverwriteSnapshotBook b) => b.title)
                    .join('、'),
              ),
            t.restore_points_fill_confirm_body,
          ].join('\n\n'),
          actionsInline: false,
          actions: <Widget>[_panelButtons(entry, canConfirm: true)],
        );
    }
  }

  Widget _entryActions(RestorePointEntry entry) {
    final String id = entry.id;
    final bool exportable = restorePointExportSource(entry) != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          if (entry.canFillIn)
            _pressable(
              child: FushiFilledButton.tonalIcon(
                key: ValueKey<String>('restore-point-fill-$id'),
                onPressed: _busy
                    ? null
                    : () => _openPanel(entry, _PanelKind.fill),
                icon: const FushiIcon(FushiIcons.merge),
                label: Text(t.restore_points_action_fill),
              ),
            ),
          if (entry.canReplace)
            _pressable(
              child: FushiOutlinedButton.icon(
                key: ValueKey<String>('restore-point-replace-$id'),
                onPressed: _busy
                    ? null
                    : () => _openPanel(entry, _PanelKind.replace),
                icon: const FushiIcon(FushiIcons.restoreBackup),
                label: Text(t.restore_points_action_replace),
              ),
            ),
          if (exportable)
            _pressable(
              child: FushiOutlinedButton.icon(
                key: ValueKey<String>('restore-point-export-$id'),
                onPressed: _busy ? null : () => unawaited(_export(entry)),
                icon: const FushiIcon(FushiIcons.share),
                label: Text(t.restore_points_action_export),
              ),
            ),
          _pressable(
            child: FushiTextButton.icon(
              key: ValueKey<String>('restore-point-delete-$id'),
              onPressed: _busy
                  ? null
                  : () => _openPanel(entry, _PanelKind.delete),
              icon: const FushiIcon(FushiIcons.delete),
              label: Text(t.restore_points_action_delete),
            ),
          ),
        ],
      ),
    );
  }

  Widget _entryCard(RestorePointEntry entry) {
    final bool open = _openId == entry.id && _openKind != null;
    return FushiGroupedList(
      key: ValueKey<String>('restore-point-${entry.id}'),
      children: <Widget>[
        FushiListItem(
          leading: FushiIcon(_kindIcon(entry)),
          title: Text(restorePointKindLabel(entry)),
          subtitle: Text(_entryDetails(entry)),
          subtitleMaxLines: 6,
        ),
        AnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.medium),
          curve: Curves.easeOutCubic,
          alignment: AlignmentDirectional.topStart,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _entryActions(entry),
              if (open)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: _panel(entry),
                ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _restorePointSection(BuildContext context) {
    return <Widget>[
      _sectionTitle(context, t.restore_points_title),
      _hint(_entries.isEmpty ? t.restore_points_empty : t.restore_points_hint),
      for (final RestorePointEntry entry in _entries) _entryCard(entry),
    ];
  }

  List<Widget> _orphanSection(BuildContext context) {
    final OrphanBookScan? scan = _scan;
    if (scan == null) return const <Widget>[];
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
                  leading: FushiIcon(_orphanKindIcon(books[i].kind)),
                  title: Text(books[i].title),
                  subtitle: Text(
                    <String>[
                      _orphanKindLabel(books[i].kind),
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
    if (_loading && _entries.isEmpty && _scan == null) {
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
    final List<Widget> orphans = _orphanSection(context);
    final List<Widget> sections = <Widget>[
      ..._restorePointSection(context),
      if (orphans.isNotEmpty) ...<Widget>[
        const SizedBox(height: 8),
        ...orphans,
      ],
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
      title: t.restore_points_title,
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
