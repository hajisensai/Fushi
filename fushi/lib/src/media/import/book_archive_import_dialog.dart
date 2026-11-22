import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/media/book_archive/book_archive_import.dart';
import 'package:fushi_engine/utils/archive/archive_unpacker.dart'
    show ArchiveUnpackFailure;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart'
    show ImportProgressCard;
import 'package:fushi/src/media/discovery/import/discovery_import_production.dart'
    show buildProductionBookArchiveImporter;
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 打开「从压缩包导入书」：把 [paths]（压缩包 + 可能同批拖入的单本书）解包后整批导入，
/// 结束时给一份汇总。返回是否至少新导入了一本书或一卷漫画（调用方据此刷新书架）。
///
/// 解开后是一卷漫画（只有页图）的包，解出的目录直接交给既有的 [MangaImportDialog]
/// （页图目录导入，书名取包名），不按扩展名猜、也不解第二次；漫画框关掉后删掉暂存。
/// [mangaEnabled] = 漫画模块开着：关着时不开漫画框，汇总里如实说明（与拖漫画包进书架
/// 时的「模块已关闭」同一句）。
Future<bool> showBookArchiveImportDialog({
  required BuildContext context,
  required FushiDatabase db,
  required List<String> paths,
  required bool mangaEnabled,
}) async {
  final BookArchiveImportSummary? summary =
      await showAppDialog<BookArchiveImportSummary>(
        context: context,
        barrierDismissible: false,
        builder: (_) => BookArchiveImportDialog(
          importer: buildProductionBookArchiveImporter(db),
          paths: paths,
          mangaEnabled: mangaEnabled,
        ),
      );
  if (summary == null) return false;
  final List<BookArchiveMangaHandoff> handoffs = summary.mangaHandoffs;
  bool mangaImported = false;
  try {
    if (handoffs.isNotEmpty && mangaEnabled && context.mounted) {
      final bool? imported = await showAppDialog<bool>(
        context: context,
        builder: (_) => MangaImportDialog(
          db: db,
          initialPaths: <String>[
            for (final BookArchiveMangaHandoff h in handoffs) h.directory,
          ],
        ),
      );
      mangaImported = imported == true;
    }
  } finally {
    // 漫画导入把页图拷进了书库，暂存解包目录（书库根下的 `.tmp-*`）此刻就没用了。
    for (final BookArchiveMangaHandoff handoff in handoffs) {
      try {
        await handoff.discard();
      } on Object catch (e) {
        debugPrint('[book-archive-import] staging cleanup failed: $e');
      }
    }
  }
  return summary.importedCount > 0 || mangaImported;
}

/// 一包多本的批量导入框（拍板 83Fe7zQbhv）：进行中显示进度，结束后只给**一份**汇总
/// （导入 / 已在书架 / 失败各几本，外加没解开或没有书的包），不再一本一个对话框。
///
/// 加密包的口令经进程级 `ArchivePasswords.provider`（app 装的是口令对话框）要，分卷包
/// 由 [ArchiveUnpacker] 自动拼。
///
/// 关闭时回传 [BookArchiveImportSummary]（出错为 null）：解开后是漫画的包由调用方交给
/// 漫画导入（[showBookArchiveImportDialog]）。结果只有漫画要交接时不停在空汇总上，直接关。
class BookArchiveImportDialog extends StatefulWidget {
  const BookArchiveImportDialog({
    required this.importer,
    required this.paths,
    this.mangaEnabled = true,
    super.key,
  });

  final BookArchiveImporter importer;
  final List<String> paths;

  /// 漫画模块开着（解开是页图的包会交给漫画导入）。
  final bool mangaEnabled;

  @override
  State<BookArchiveImportDialog> createState() =>
      _BookArchiveImportDialogState();
}

class _BookArchiveImportDialogState extends State<BookArchiveImportDialog> {
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  final ValueNotifier<String> _message = ValueNotifier<String>('');
  BookArchiveImportSummary? _summary;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _progress.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    try {
      final BookArchiveImportSummary summary = await widget.importer.importAll(
        widget.paths,
        onProgress: _onProgress,
      );
      if (!mounted) return;
      if (widget.mangaEnabled && summary.onlyMangaHandoffs) {
        // 全是漫画：没有书的结果要看，直接交给漫画导入。
        Navigator.pop(context, summary);
        return;
      }
      setState(() => _summary = summary);
    } on Object catch (e, stackTrace) {
      // 本框不可点外关闭、进行中禁返回：任何失败都必须落到结果态给出原因和「确定」，
      // 否则用户被一个永远转圈的模态框锁死。
      debugPrint('[book-archive-import] failed: $e\n$stackTrace');
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  void _onProgress(BookArchiveImportProgress progress) {
    if (!mounted) return;
    _progress.value = progress.total == 0 ? 0 : progress.done / progress.total;
    _message.value = switch (progress.stage) {
      BookArchiveImportStage.unpacking => t.book_archive_import_unpacking(
        name: progress.name,
      ),
      BookArchiveImportStage.importing => t.book_archive_import_importing(
        name: progress.name,
      ),
    };
  }

  bool get _running => _summary == null && _error == null;

  @override
  Widget build(BuildContext context) {
    final BookArchiveImportSummary? summary = _summary;
    return PopScope(
      canPop: !_running,
      child: FushiAlertDialog(
        icon: FushiDialogHeroIcon(
          icon: FushiIcons.books,
          tone: summary != null && !summary.hasProblems
              ? FushiHeroTone.primary
              : FushiHeroTone.neutral,
        ),
        title: Text(t.book_archive_import_title),
        content: SizedBox(
          width: 420,
          child: AnimatedSwitcher(
            duration: context.fushiMotion.spatialDefault.duration,
            child: _running
                ? ImportProgressCard(
                    key: const ValueKey<String>('progress'),
                    progress: _progress,
                    message: _message,
                  )
                : _BookArchiveImportResult(
                    key: const ValueKey<String>('result'),
                    summary: summary,
                    error: _error,
                    mangaEnabled: widget.mangaEnabled,
                  ),
          ),
        ),
        actions: <Widget>[
          if (!_running)
            FushiFilledButton(
              onPressed: () => Navigator.pop(context, summary),
              child: Text(t.dialog_ok),
            ),
        ],
      ),
    );
  }
}

/// 汇总：一行计数 + 逐条问题（没解开的包、没有书的包、导入失败的书）。
class _BookArchiveImportResult extends StatelessWidget {
  const _BookArchiveImportResult({
    required this.summary,
    required this.error,
    required this.mangaEnabled,
    super.key,
  });

  final BookArchiveImportSummary? summary;
  final Object? error;
  final bool mangaEnabled;

  @override
  Widget build(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final BookArchiveImportSummary? s = summary;
    if (s == null) {
      return Text('$error', style: type.bodyMedium);
    }
    final List<String> problems = <String>[
      for (final BookArchiveUnpackFailure f in s.unpackFailures)
        t.book_archive_import_problem_item(
          name: f.archiveName,
          reason: unpackFailureMessage(f.failure),
        ),
      for (final String name in s.archivesWithoutBooks)
        t.book_archive_import_problem_item(
          name: name,
          reason: t.book_archive_import_no_books,
        ),
      for (final BookArchiveItemResult item in s.failedItems)
        t.book_archive_import_problem_item(
          name: item.name,
          reason: item.error ?? '',
        ),
      for (final BookArchiveMangaHandoff handoff in s.mangaHandoffs)
        t.book_archive_import_problem_item(
          name: handoff.archiveName,
          reason: mangaEnabled
              ? t.book_archive_import_manga_handoff
              : t.module_disabled_hint,
        ),
    ];
    return FushiEntranceScope(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            FushiStaggeredEntrance(
              index: 0,
              child: Text(
                t.book_archive_import_result(
                  imported: s.importedCount,
                  skipped: s.skippedCount,
                  failed: s.failedCount,
                ),
                style: type.bodyLarge,
              ),
            ),
            for (int i = 0; i < problems.length; i++)
              FushiStaggeredEntrance(
                index: i + 1,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(problems[i], style: type.bodyMedium),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 整包没解开的原因文案（与发现页下载的解包失败同一套文案）。
String unpackFailureMessage(ArchiveUnpackFailure failure) => switch (failure) {
  ArchiveUnpackFailure.passwordRequired ||
  ArchiveUnpackFailure.passwordCancelled =>
    t.download_task_import_blocked_archive_password,
  ArchiveUnpackFailure.toolMissing =>
    t.download_task_import_blocked_archive_tool_missing,
  ArchiveUnpackFailure.missingVolume =>
    t.download_task_import_blocked_archive_volumes,
  ArchiveUnpackFailure.unsafeEntry ||
  ArchiveUnpackFailure.tooLarge ||
  ArchiveUnpackFailure.unsupported ||
  ArchiveUnpackFailure.corrupt => t.download_task_import_blocked_archive_failed,
};
