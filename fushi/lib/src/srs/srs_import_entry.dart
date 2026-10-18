/// 复习牌组列表的「导入」/「导出（.apkg）」/「从制卡历史导入」三个入口。
///
/// - 导入：选 .apkg / .colpkg → 选项（对齐 Anki 导入页，见
///   srs_import_options_dialog.dart；记住上次的选择）→ 进度 →
///   导入报告（[srsImportReportLines] 把 `SrsImportReport` 的各项翻成人话）。媒体经
///   [SrsMediaStore] 按内容哈希落盘。新格式包而排程内核不可用时报「需要排程内核」。
/// - 导出：`exportAnkiPackage` → 桌面「另存为」/ 移动端系统分享；范围里有 FSRS-7
///   牌组时先提示「Anki 里会改用 FSRS-6」。
/// - 从制卡历史导入：`mined_sentences` → 当前 profile 的默认牌组（见
///   srs_mined_history_import.dart），确认框写明导入到哪个 profile。
///
/// 可单测的部分（[runSrsAnkiImport] / [srsImportReportLines] / [buildSrsAnkiExport]）
/// 不碰 UI；`openSrs*` 只负责选文件、对话框与提示。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_export.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/srs/srs_import_options_dialog.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_mined_history_import.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/utils.dart';

// ---------------------------------------------------------------- 导入（逻辑）

/// 导入一个 Anki 包：媒体存进 [media]。抛 [SrsImportException]（如新格式缺内核）。
Future<SrsImportReport> runSrsAnkiImport({
  required SrsDbStore store,
  required SrsMediaStore media,
  required File file,
  SrsAnkiImportOptions options = const SrsAnkiImportOptions(),
  void Function(double progress)? onProgress,
  SrsZstdDecoder? zstdDecompress,
}) => importAnkiPackageFile(
  store: store,
  file: file,
  storeMedia: (String name, Uint8List bytes) => media.store(name, bytes),
  options: options,
  onProgress: onProgress,
  zstdDecompress: zstdDecompress,
);

String _formatSteps(List<double> steps) => steps
    .map((double s) {
      // 步长单位是分钟；≥ 1 天的项按天写（被截掉的正是这类）。
      if (s >= 1440 && s % 1440 == 0) return '${(s / 1440).round()}d';
      if (s >= 60 && s % 60 == 0) return '${(s / 60).round()}h';
      return s == s.roundToDouble() ? '${s.round()}m' : '${s}m';
    })
    .join(' ');

/// 导入报告 → 给人看的行（只列非零 / 非空的项）。
List<String> srsImportReportLines(SrsImportReport r) => <String>[
  t.srs_import_report_notes(
    added: r.notesAdded,
    updated: r.notesUpdated,
    skipped: r.notesSkipped,
  ),
  if (r.cardsAdded > 0) t.srs_import_report_cards(n: r.cardsAdded),
  if (r.cardsResetToNew > 0)
    t.srs_import_report_reset_new(n: r.cardsResetToNew),
  if (r.reviewLogsSkipped > 0)
    t.srs_import_report_reviews_skipped(n: r.reviewLogsSkipped),
  if (r.deckPresetsSkipped > 0)
    t.srs_import_report_presets_skipped(n: r.deckPresetsSkipped),
  if (r.noteTypesUpdated > 0)
    t.srs_import_report_notetypes_updated(n: r.noteTypesUpdated),
  for (final String name in r.noteTypesDuplicated)
    t.srs_import_report_notetypes_duplicated(name: name),
  if (r.reviewLogsImported > 0)
    t.srs_import_report_reviews(n: r.reviewLogsImported),
  if (r.fushiLogsRestored > 0)
    t.srs_import_report_fushi_restored(n: r.fushiLogsRestored),
  if (r.mediaStored > 0) t.srs_import_report_media(n: r.mediaStored),
  if (r.mediaMissing.isNotEmpty)
    t.srs_import_report_media_missing(n: r.mediaMissing.length),
  for (final SrsImportTruncatedSteps s in r.truncatedSteps)
    t.srs_import_report_steps_removed(
      preset: s.preset,
      removed: _formatSteps(s.removed),
    ),
  for (final String preset in r.rwkvPresetsFellBack)
    t.srs_import_report_rwkv(preset: preset),
  for (final String preset in r.invalidParams.keys)
    t.srs_import_report_invalid_params(preset: preset),
  if (r.conflictNotes.isNotEmpty)
    t.srs_import_report_conflicts(n: r.conflictNotes.length),
  if (r.removedInSource.isNotEmpty)
    t.srs_import_report_removed(n: r.removedInSource.length),
  if (r.futureCards.isNotEmpty)
    t.srs_import_report_future(n: r.futureCards.length),
];

// ---------------------------------------------------------------- 导出（逻辑）

/// 一次导出的产物。
class SrsAnkiExport {
  const SrsAnkiExport({required this.bytes, required this.usesFsrs7});

  final Uint8List bytes;

  /// 范围里有用 FSRS-7 的参数组（Anki 里会改用 FSRS-6，需要提示）。
  final bool usesFsrs7;
}

/// 范围（[deckId] 子树，null = 全部）里有没有 FSRS-7 牌组。
Future<bool> srsExportScopeUsesFsrs7(SrsDbStore store, {String? deckId}) async {
  final SrsDeckTree tree = await store.deckTree();
  final Iterable<String> ids = deckId == null
      ? tree.decks.map((SrsDeckView d) => d.id)
      : tree.subtree(deckId);
  for (final String id in ids) {
    if (tree.paramsOwner(id).localAlgorithm == SrsAlgorithm.fsrs7) return true;
  }
  return false;
}

/// 导出 [deckId] 子树（null = 全部）为 .apkg 字节；媒体从 [media] 读。
Future<SrsAnkiExport> buildSrsAnkiExport({
  required SrsDbStore store,
  required SrsMediaStore? media,
  String? deckId,
}) async {
  final Uint8List bytes = await exportAnkiPackage(
    store: store,
    deckId: deckId,
    loadMedia: media == null ? null : (String name) => media.load(name),
  );
  return SrsAnkiExport(
    bytes: bytes,
    usesFsrs7: await srsExportScopeUsesFsrs7(store, deckId: deckId),
  );
}

// ---------------------------------------------------------------- UI 入口

Future<SrsMediaStore?> _readMedia(WidgetRef ref) async {
  try {
    return await ref.read(srsMediaStoreProvider.future);
  } catch (e, stack) {
    ErrorLogService.instance.log('srsImportEntry.media', e, stack);
    return null;
  }
}

/// 打开导入流程（牌组列表顶栏「导入」）。
Future<void> openSrsImport(BuildContext context, WidgetRef ref) async {
  final SrsDbStore? store = await readSrsStore(ref);
  final SrsMediaStore? media = await _readMedia(ref);
  if (store == null || media == null) {
    FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    return;
  }
  if (!context.mounted) return;
  final String? path = await pickSystemFilePath(
    context: context,
    allowedExtensions: const <String>{'apkg', 'colpkg'},
  );
  if (path == null || !context.mounted) return;
  final PrefStore prefs = ref.read(appProvider).prefsRepo;
  final SrsAnkiImportOptions? options = await showSrsImportOptionsDialog(
    context: context,
    fileName: File(path).uri.pathSegments.last,
    initial: readSrsImportOptions(prefs),
    wholeCollection: path.toLowerCase().endsWith('.colpkg'),
  );
  if (options == null || !context.mounted) return;
  await writeSrsImportOptions(prefs, options);
  if (!context.mounted) return;

  final ValueNotifier<double> progress = ValueNotifier<double>(0);
  final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
  unawaited(
    showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) => PopScope(
        canPop: false,
        child: FushiAlertDialog(
          title: Text(t.srs_import_running),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (BuildContext context, double value, Widget? _) =>
                FushiLinearProgressIndicator(value: value <= 0 ? null : value),
          ),
        ),
      ),
    ),
  );
  SrsImportReport? report;
  Object? failure;
  try {
    report = await runSrsAnkiImport(
      store: store,
      media: media,
      file: File(path),
      options: options,
      onProgress: (double p) => progress.value = p.clamp(0.0, 1.0),
    );
  } catch (e, stack) {
    ErrorLogService.instance.log('openSrsImport', e, stack);
    failure = e;
  } finally {
    if (navigator.mounted) navigator.pop();
    progress.dispose();
  }
  bumpSrsRevision(ref);
  if (!context.mounted) return;
  if (failure != null) {
    final String message =
        failure is SrsImportException &&
            failure.code == SrsImportException.needsKernel
        ? t.srs_import_needs_kernel
        : t.srs_import_failed(
            error: failure is SrsImportException ? failure.message : '$failure',
          );
    await showFushiConfirmDialog(
      context: context,
      title: t.srs_import_pick_title,
      message: message,
      icon: FushiIcons.error,
      confirmLabel: t.dialog_ok,
      cancelLabel: t.cancel,
    );
    return;
  }
  final SrsImportReport done = report!;
  await showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      icon: const FushiDialogHeroIcon(icon: FushiIcons.importFile),
      title: Text(t.srs_import_report_title),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final String line in srsImportReportLines(done))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(line),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_ok,
          kind: FushiDialogActionKind.primary,
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(),
        ),
      ],
    ),
  );
}

/// 牌组列表 ⋯「导出（.apkg）」：导出全部牌组（Anki 与 Fushi 自己的「导入」都能吃）。
Future<void> openSrsExport(BuildContext context, WidgetRef ref) async {
  final SrsDbStore? store = await readSrsStore(ref);
  if (store == null) {
    FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    return;
  }
  final SrsMediaStore? media = await _readMedia(ref);
  if (await srsExportScopeUsesFsrs7(store)) {
    if (!context.mounted) return;
    final bool go = await showFushiConfirmDialog(
      context: context,
      title: t.srs_export_apkg,
      message: t.srs_export_fsrs7_note,
      icon: FushiIcons.info,
      confirmLabel: t.srs_export_apkg,
      cancelLabel: t.cancel,
    );
    if (!go) return;
  }
  try {
    final SrsAnkiExport export = await buildSrsAnkiExport(
      store: store,
      media: media,
    );
    if (!context.mounted) return;
    final bool saved = await _saveOrShareBytes(
      bytes: export.bytes,
      fileName: 'fushi-review.apkg',
    );
    if (saved) {
      FushiToast.show(msg: t.srs_export_done, severity: ToastSeverity.success);
    }
  } catch (e, stack) {
    ErrorLogService.instance.log('openSrsExport', e, stack);
    FushiToast.show(msg: t.srs_export_failed, severity: ToastSeverity.error);
  }
}

bool get _isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 桌面「另存为」/ 移动端系统分享（与收藏导出、日志导出同一套平台分流：Linux 没有
/// share_plus 注册，桌面绝不触分享）。返回是否真的存 / 分享了。
Future<bool> _saveOrShareBytes({
  required Uint8List bytes,
  required String fileName,
}) async {
  final Directory staging = await (await getTemporaryDirectory()).createTemp(
    'fushi_srs_export_',
  );
  final File tmp = File('${staging.path}${Platform.pathSeparator}$fileName');
  await tmp.writeAsBytes(bytes, flush: true);
  try {
    if (_isDesktop) {
      final String? savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.srs_export_apkg,
        fileName: fileName,
      );
      if (savePath == null) return false;
      await tmp.copy(savePath);
      return true;
    }
    return await FushiShare.shareFiles(<XFile>[
      XFile(tmp.path, mimeType: 'application/octet-stream'),
    ], subject: fileName);
  } finally {
    // 移动端分享面板异步读文件，不在此删（临时目录由系统回收）。
    if (_isDesktop) {
      try {
        await staging.delete(recursive: true);
      } catch (_) {}
    }
  }
}

/// 牌组列表 ⋯「从制卡历史导入」。
Future<void> openSrsMinedHistoryImport(
  BuildContext context,
  WidgetRef ref,
) async {
  final SrsDbStore? store = await readSrsStore(ref);
  if (store == null) {
    FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    return;
  }
  if (!context.mounted) return;
  final String profile =
      ref.read(profileViewModelProvider).activeProfile?.name ?? '';
  final bool go = await showFushiConfirmDialog(
    context: context,
    title: t.srs_history_import,
    message: t.srs_history_import_confirm(profile: profile),
    icon: FushiIcons.history,
    confirmLabel: t.srs_import,
    cancelLabel: t.cancel,
  );
  if (!go) return;
  try {
    final SrsMinedHistoryImportResult result =
        await importMinedSentencesIntoSrs(
          db: ref.read(appProvider).database,
          store: store,
        );
    bumpSrsRevision(ref);
    FushiToast.show(
      msg: t.srs_history_import_done(
        n: result.imported,
        skipped: result.skipped,
      ),
      severity: ToastSeverity.success,
    );
  } catch (e, stack) {
    ErrorLogService.instance.log('openSrsMinedHistoryImport', e, stack);
    FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
  }
}

/// 牌组列表 ⋯「立即同步」：没配置同步后端时提示一句。
Future<void> openSrsSyncNow(Future<int> Function()? syncNow) async {
  if (syncNow == null) return;
  try {
    final int channels = await syncNow();
    FushiToast.show(
      msg: channels == 0 ? t.srs_sync_no_backend : t.srs_sync_done,
      severity: channels == 0 ? ToastSeverity.info : ToastSeverity.success,
    );
  } catch (e, stack) {
    ErrorLogService.instance.log('openSrsSyncNow', e, stack);
    FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
  }
}
