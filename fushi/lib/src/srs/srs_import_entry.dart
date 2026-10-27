/// 复习牌组列表的「导入」/「导出（.apkg）」/「从制卡历史导入」三个入口。
///
/// - 导入：选 .apkg / .colpkg → 选项（对齐 Anki 导入页，见
///   srs_import_options_dialog.dart；记住上次的选择）→ 排进后台导入队列
///   （srs_import_task.dart；牌组列表顶上的任务条显示进度）→ 任务条「查看报告」看
///   导入报告（[srsImportReportLines] 把 `SrsImportReport` 的各项翻成人话）。媒体经
///   [SrsMediaStore] 按内容哈希落盘。新格式包而排程内核不可用时报「需要排程内核」。
/// - 导出：选项（学习进度 / 牌组预设 / 兼容 Anki，见 srs_export_options_dialog.dart；
///   记住上次的选择；范围里有 FSRS-7 牌组时对话框内提示「Anki 里会改用 FSRS-6」）→
///   `exportAnkiPackageFile`（流式写暂存文件）→ 桌面「另存为」/ 移动端系统分享。
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
import 'package:fushi_engine/srs/apkg/srs_export_options.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/srs/srs_export_options_dialog.dart';
import 'package:fushi/src/srs/srs_import_options_dialog.dart';
import 'package:fushi/src/srs/srs_import_task.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_mined_history_import.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_sync_progress.dart';
import 'package:fushi/src/srs/srs_sync_progress_ui.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi/src/sync/sync_error_messages.dart';
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
  if (r.notesRestored > 0) t.srs_import_report_restored(n: r.notesRestored),
  if (r.lapisNotesMigrated > 0)
    t.srs_import_report_lapis_migrated(n: r.lapisNotesMigrated),
  if (r.lapisDecksRenamed > 0)
    t.srs_import_report_lapis_decks_renamed(n: r.lapisDecksRenamed),
  if (r.lapisMigrationFailed) t.srs_import_report_lapis_failed,
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
  for (final MapEntry<String, SrsAlgorithm> e in r.fsrsPresets.entries)
    t.srs_import_report_fsrs(
      preset: e.key,
      alg: e.value == SrsAlgorithm.fsrs6 ? 'FSRS-6' : 'FSRS-7',
    ),
  for (final String preset in r.defaultAlgorithmPresets)
    t.srs_import_report_default_algorithm(preset: preset),
  for (final String preset in r.rwkvPresets)
    t.srs_import_report_rwkv(preset: preset),
  for (final String preset in r.rwkvPresetsOnFsrs)
    t.srs_import_report_rwkv_on_fsrs(preset: preset),
  for (final String preset in r.defaultFsrsPresets)
    t.srs_import_report_default_fsrs(preset: preset),
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
  const SrsAnkiExport({required this.file, required this.usesFsrs7});

  /// 写好的 .apkg（调用方给的路径）。
  final File file;

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
    // RWKV 牌组的参数组也是 FSRS-7 的（影子记忆状态），Anki 里同样改用 FSRS-6。
    if (tree.paramsOwner(id).localAlgorithm.memoryAlgorithm ==
        SrsAlgorithm.fsrs7) {
      return true;
    }
  }
  return false;
}

/// 导出 [deckId] 子树（null = 全部）为 .apkg，流式写到 [file]（整包不进内存）；媒体从
/// [media] 读。
Future<SrsAnkiExport> buildSrsAnkiExport({
  required SrsDbStore store,
  required SrsMediaStore? media,
  required File file,
  String? deckId,
  SrsAnkiExportOptions options = const SrsAnkiExportOptions(),
}) async {
  await exportAnkiPackageFile(
    store: store,
    file: file,
    deckId: deckId,
    loadMedia: media == null ? null : (String name) => media.load(name),
    options: options,
  );
  return SrsAnkiExport(
    file: file,
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

  // 后台导入（BUG-3549）：排进 app 级队列立即返回，不再用模态进度框挡住页面；进度在牌组
  // 列表顶上的任务条里，完成 / 失败由控制器弹全局提示，牌组列表随之重读。
  final SrsImportTask? task = await startSrsBackgroundImport(
    ref,
    file: File(path),
    options: options,
  );
  if (task == null) {
    FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    return;
  }
  FushiToast.show(msg: t.srs_import_background_started);
}

/// 导入失败原因 → 给人看的一句话。
String srsImportFailureMessage(Object failure) =>
    failure is SrsImportException &&
        failure.code == SrsImportException.needsKernel
    ? t.srs_import_needs_kernel
    : t.srs_import_failed(
        error: failure is SrsImportException ? failure.message : '$failure',
      );

/// 用户不要 RWKV：把导入时由 FSRS 预设改用 RWKV 的牌组（[SrsImportReport.fsrsDecks]）切回各自
/// 原来的 FSRS 算法，返回切了几个。导入时参数已经按原算法存下，切回即用。
///
/// 只改仍然自己管参数、仍是 RWKV 的牌组：导入后被删、改成继承、或用户已经自己换过算法的跳过。
Future<int> srsKeepImportedDecksOnFsrs(
  SrsDbStore store,
  Map<String, SrsAlgorithm> decks,
) async {
  final SrsDeckTree tree = await store.deckTree();
  int switched = 0;
  for (final MapEntry<String, SrsAlgorithm> e in decks.entries) {
    final SrsDeckView? deck = tree[e.key];
    if (deck == null || tree.paramsOwner(e.key).id != e.key) continue;
    if (!deck.localAlgorithm.usesRwkv) continue;
    await store.editFields(SrsEntityKind.deck, e.key, <String, Object?>{
      SrsFieldKeys.deckAlgorithm: <String, Object?>{
        'alg': e.value.wire,
        'auto': false,
      },
    });
    switched++;
  }
  return switched;
}

/// 导入报告对话框（任务条「查看报告」）。
///
/// 有由 FSRS 预设改用 RWKV 的牌组且给了 [onKeepFsrs] 时多一个「继续用 FSRS」按钮。
Future<void> showSrsImportReportDialog(
  BuildContext context,
  SrsImportReport report, {
  VoidCallback? onKeepFsrs,
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext dialogContext) => FushiAlertDialog(
    icon: const FushiDialogHeroIcon(icon: FushiIcons.importFile),
    title: Text(t.srs_import_report_title),
    content: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final String line in srsImportReportLines(report))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(line),
            ),
        ],
      ),
    ),
    actions: <Widget>[
      if (onKeepFsrs != null && report.fsrsDecks.isNotEmpty)
        FushiDialogAction(
          label: t.srs_import_report_keep_fsrs,
          kind: FushiDialogActionKind.secondary,
          onPressed: () {
            Navigator.of(dialogContext).pop();
            onKeepFsrs();
          },
        ),
      FushiDialogAction(
        label: t.dialog_ok,
        kind: FushiDialogActionKind.primary,
        autofocus: true,
        onPressed: () => Navigator.of(dialogContext).pop(),
      ),
    ],
  ),
);

/// 导入报告「继续用 FSRS」：切完提示切了几个，并让牌组列表重读。
Future<void> srsKeepImportedDecksOnFsrsFromReport(
  WidgetRef ref,
  SrsImportReport report,
) async {
  final SrsDbStore? store = await readSrsStore(ref);
  if (store == null) {
    FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    return;
  }
  final int n = await srsKeepImportedDecksOnFsrs(store, report.fsrsDecks);
  bumpSrsRevision(ref);
  FushiToast.show(msg: t.srs_import_kept_fsrs(n: n));
}

/// 导入失败对话框（任务条上点失败的任务）。
Future<void> showSrsImportFailureDialog(BuildContext context, Object failure) =>
    showFushiConfirmDialog(
      context: context,
      title: t.srs_import_pick_title,
      message: srsImportFailureMessage(failure),
      icon: FushiIcons.error,
      confirmLabel: t.dialog_ok,
      cancelLabel: t.cancel,
    );

/// 牌组列表 ⋯「导出（.apkg）」：导出全部牌组（Anki 与 Fushi 自己的「导入」都能吃）。
Future<void> openSrsExport(BuildContext context, WidgetRef ref) async {
  final SrsDbStore? store = await readSrsStore(ref);
  if (store == null) {
    FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    return;
  }
  final SrsMediaStore? media = await _readMedia(ref);
  final bool usesFsrs7 = await srsExportScopeUsesFsrs7(store);
  if (!context.mounted) return;
  final PrefStore prefs = ref.read(appProvider).prefsRepo;
  final SrsAnkiExportOptions? options = await showSrsExportOptionsDialog(
    context: context,
    initial: readSrsExportOptions(prefs),
    usesFsrs7: usesFsrs7,
  );
  if (options == null || !context.mounted) return;
  await writeSrsExportOptions(prefs, options);
  try {
    const String fileName = 'fushi-review.apkg';
    final Directory staging = await (await getTemporaryDirectory()).createTemp(
      'fushi_srs_export_',
    );
    final SrsAnkiExport export = await buildSrsAnkiExport(
      store: store,
      media: media,
      file: File('${staging.path}${Platform.pathSeparator}$fileName'),
      options: options,
    );
    if (!context.mounted) return;
    final bool saved = await _saveOrShareFile(
      file: export.file,
      fileName: fileName,
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
/// share_plus 注册，桌面绝不触分享）。[file] 在一个专用暂存目录里（桌面存完即删整个目录）。
/// 返回是否真的存 / 分享了。
Future<bool> _saveOrShareFile({
  required File file,
  required String fileName,
}) async {
  final Directory staging = file.parent;
  final File tmp = file;
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

/// 牌组列表 ⋯「立即同步」的结果提示：没配置、失败（带原因）、成功三种分开说。
/// 配置了但这轮失败不能说成「没配置」——用户会去找一个其实已经配好的设置。
({String msg, ToastSeverity severity}) srsSyncNowToast(
  SrsSyncNowResult result,
) {
  if (result.errors.isNotEmpty) {
    return (
      msg: t.srs_sync_failed(reason: srsSyncErrorReason(result.errors.first)),
      severity: ToastSeverity.error,
    );
  }
  if (result.unconfigured) {
    return (msg: t.srs_sync_no_backend, severity: ToastSeverity.info);
  }
  return (msg: t.srs_sync_done, severity: ToastSeverity.success);
}

/// 一个目录没同步成的原因（给用户看的一句话）。
String srsSyncErrorReason(Object error) => switch (error) {
  SrsSyncReportError(message: kSrsSyncServerTimeUnavailable) =>
    t.srs_sync_backend_unsupported,
  SrsSyncReportError(message: kSrsSyncDirectoryIdentityUnavailable) =>
    t.srs_sync_directory_unidentified,
  SrsSyncReportError(message: kSrsSyncStoreUnavailable) =>
    t.srs_sync_store_unavailable,
  SrsSyncReportError(message: kSrsSyncAwaitingConfirm) =>
    t.srs_sync_awaiting_confirm,
  SrsSyncReportError(message: kSrsSync2NeedsKey) =>
    t.srs_timeline_location_needs_key,
  SrsSyncReportError(message: kSrsSync2WrongKey) =>
    t.srs_timeline_location_wrong_key,
  SrsSyncReportError(message: kSrsSync2EncryptionMissing) =>
    t.srs_timeline_location_encryption_missing,
  SrsSyncReportError(message: kSrsSync2BadKdf) =>
    t.srs_timeline_location_bad_kdf,
  SrsSyncReportError(message: kSrsSync2MetaUnavailable) =>
    t.srs_sync_location_meta_unavailable,
  _ => friendlySyncErrorDetail(error),
};

/// 牌组列表 ⋯「立即同步」。
///
/// [onNoChannel]：没配置任何同步通道时调用（页面借它直达同步设置）；不给就只弹提示。
/// 配置了但失败时照常报失败原因，不跳设置。
///
/// 点下就有反馈（同步一轮可能跑十几分钟，以前要等到跑完才弹结果，看上去像没反应）：
/// - 已有一轮在跑（[srsSyncProgress] 非 null）：立刻提示「正在同步：<进度>」，这次请求排在
///   那一轮后面（补跑一次增量，保证点下之后的改动也传上去），跑完照常报结果；
/// - 本入口发起的请求还没回来时再点：只提示进度，不再叠一轮；
/// - 否则立刻提示「开始同步」。
Future<void> openSrsSyncNow(
  Future<SrsSyncNowResult> Function()? syncNow, {
  Future<void> Function()? onNoChannel,
}) async {
  if (syncNow == null) return;
  final SrsSyncProgress? running = srsSyncProgress.value;
  if (_srsSyncNowInFlight) {
    FushiToast.show(
      msg: srsSyncNowStartToast(running ?? const SrsSyncProgress()),
    );
    return;
  }
  _srsSyncNowInFlight = true;
  FushiToast.show(msg: srsSyncNowStartToast(running));
  try {
    final SrsSyncNowResult result = await syncNow();
    if (result.unconfigured && onNoChannel != null) {
      await onNoChannel();
      return;
    }
    final ({String msg, ToastSeverity severity}) toast = srsSyncNowToast(
      result,
    );
    FushiToast.show(msg: toast.msg, severity: toast.severity);
  } catch (e, stack) {
    ErrorLogService.instance.log('openSrsSyncNow', e, stack);
    FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
  } finally {
    _srsSyncNowInFlight = false;
  }
}

/// 本入口发起的「立即同步」还没回来。
bool _srsSyncNowInFlight = false;

/// 「立即同步」点下那一刻的提示：已有一轮在跑 → 「正在同步：<进度>」，否则 → 「开始同步」。
String srsSyncNowStartToast(SrsSyncProgress? running) => running == null
    ? t.srs_sync_now_started
    : t.srs_sync_now_busy(progress: srsSyncProgressLine(running));
