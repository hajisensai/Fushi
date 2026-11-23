/// 有声漫画导出包的界面（设计稿 §4 / §5）：工作台「导出有声漫画包」（单卷，或系列下
/// 多选卷）与「导入有声漫画包」（工作台入口、漫画库导入框认出 `.fushi-manga-audio`
/// 时转到这里）。
///
/// 页面只观察进程级任务表 [MangaAudioPackageTasks]：导出 / 导入在后台跑，离开页面
/// 不停，回来接上进度；业务在 `manga_audio_package_export.dart` /
/// `manga_audio_package_import.dart`（控制通道 `tts export` / `tts import-package`
/// 同一对函数）。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_package.dart'
    show
        MangaAudioPackagePart,
        MangaAudioPackageSeries,
        MangaPackageMatchKind,
        kMangaAudioPackageExtension;
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart' show XFile;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/cast/series_cast_resolver.dart';
import 'package:fushi/src/media/audiobook/tts/irodori_voice_packs.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_audiobook_export.dart'
    show prepareTtsAudiobookShareStagingDir;
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart'
    show ttsRenderQueueFor;
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_tasks.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart'
    show MangaAudioRegistration, loadMangaAudio;
import 'package:fushi/src/media/manga/audio/manga_audio_package_export.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_package_import.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_package_io.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_package_tasks.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart'
    show isLocalMangaVolume;
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show showFushiConfirmDialog;
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 这一卷现在不能导出 / 被导入替换的原因（标注 / 生成任务在跑）。
MangaPackageBusyCheck mangaAudioPackageBusyCheck(AppModel appModel) {
  final MangaAnnotateTasks annotate = mangaAnnotateTasksFor(appModel);
  final TtsRenderQueue queue = ttsRenderQueueFor(appModel);
  return (String bookKey) {
    final TtsRenderJob? job = queue.latestFor(bookKey);
    if (annotate.isRunning(bookKey) || (job != null && !job.isTerminal)) {
      return t.manga_audio_package_error_busy;
    }
    return null;
  };
}

/// 失败原因码 → 本地化文案。
String mangaAudioPackageErrorText(String? code) => switch (code) {
  'package_invalid' || 'not_package' => t.manga_audio_package_error_invalid,
  'package_too_new' => t.manga_audio_package_error_too_new,
  'no_audio' || 'no_script' => t.manga_audio_package_error_no_audio,
  'missing_pages' ||
  'missing_audio' => t.manga_audio_package_error_missing_files,
  'audio_mismatch' ||
  'audio_invalid' ||
  'content_mismatch' => t.manga_audio_package_error_mismatch,
  'package_corrupt' => t.manga_audio_package_error_corrupt,
  'busy' => t.manga_audio_package_error_busy,
  'conflict' => t.manga_audio_package_result_skipped,
  _ => t.manga_audio_package_error_generic(code: code ?? 'internal'),
};

String _appLabel(AppModel appModel) {
  try {
    return 'fushi ${appModel.packageInfo.version}';
  } on Object {
    return 'fushi';
  }
}

/// 打开导出页：[bookKey] 这一卷，属于某个系列时列出系列里的卷供多选。
Future<void> openMangaAudioPackageExportPage(
  BuildContext context, {
  required AppModel appModel,
  required String bookKey,
}) => Navigator.of(context).push<void>(
  adaptivePageRoute<void>(
    context: context,
    builder: (BuildContext context) =>
        MangaAudioPackageExportPage(appModel: appModel, bookKey: bookKey),
  ),
);

/// 打开导入页（[path] 是选好的包文件）。
Future<void> openMangaAudioPackageImportPage(
  BuildContext context, {
  required AppModel appModel,
  required String path,
}) => Navigator.of(context).push<void>(
  adaptivePageRoute<void>(
    context: context,
    builder: (BuildContext context) =>
        MangaAudioPackageImportPage(appModel: appModel, path: path),
  ),
);

/// 选一个 `.fushi-manga-audio` 再打开导入页。
Future<void> pickAndOpenMangaAudioPackageImport(
  BuildContext context, {
  required AppModel appModel,
}) async {
  final FilePickerResult? picked = await pickFilesByExtensions(
    context: context,
    allowedExtensions: <String>[kMangaAudioPackageExtension.substring(1)],
  );
  final String? path = picked?.files.single.path;
  if (path == null || !context.mounted) return;
  await openMangaAudioPackageImportPage(
    context,
    appModel: appModel,
    path: path,
  );
}

// ─────────────────────────────────────────────────────────────────────────
// 导出
// ─────────────────────────────────────────────────────────────────────────

/// 导出页里的一卷。
class _ExportCandidate {
  const _ExportCandidate({
    required this.bookKey,
    required this.title,
    required this.audioLines,
    required this.hasScript,
    required this.busy,
  });

  final String bookKey;
  final String title;

  /// 登记好的成品句数；null = 没有成品。
  final int? audioLines;
  final bool hasScript;
  final bool busy;

  bool get exportable => !busy && (audioLines != null || hasScript);
}

class MangaAudioPackageExportPage extends StatefulWidget {
  const MangaAudioPackageExportPage({
    required this.appModel,
    required this.bookKey,
    this.tasks,
    super.key,
  });

  final AppModel appModel;
  final String bookKey;

  /// 任务表（默认进程级那张）。
  final MangaAudioPackageTasks? tasks;

  static const String keyPrefix = 'manga-audio-package-export';

  @override
  State<MangaAudioPackageExportPage> createState() =>
      _MangaAudioPackageExportPageState();
}

class _MangaAudioPackageExportPageState
    extends State<MangaAudioPackageExportPage> {
  late final MangaAudioPackageTasks _tasks =
      widget.tasks ?? MangaAudioPackageTasks.instance;
  List<_ExportCandidate>? _candidates;
  String? _seriesTitle;
  final Set<String> _selected = <String>{};
  MangaAudioPackageTask? _task;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final AppModel app = widget.appModel;
    final FushiDatabase db = app.database;
    final String? seriesKey = await resolveSeriesKey(app, widget.bookKey);
    final List<String> keys = seriesKey == null
        ? <String>[widget.bookKey]
        : await seriesMemberBooks(app, seriesKey);
    if (!keys.contains(widget.bookKey)) keys.insert(0, widget.bookKey);
    String? seriesTitle;
    if (seriesKey != null) {
      seriesTitle = (await seriesCastStoreFor(app).load(seriesKey)).title;
      final int? collection = seriesCollectionId(seriesKey);
      if (seriesTitle.isEmpty && collection != null) {
        seriesTitle = (await db.getMediaCollectionById(collection))?.name;
      }
    }
    final MangaPackageBusyCheck busy = mangaAudioPackageBusyCheck(app);
    final MangaAudioScriptStore scripts = mangaAudioScriptStoreFor(app);
    final List<_ExportCandidate> candidates = <_ExportCandidate>[];
    for (final String key in keys) {
      final EpubBookRow? row = await db.getEpubBook(key);
      if (row == null || !isLocalMangaVolume(row)) continue;
      final MangaAudioRegistration? audio = await loadMangaAudio(db, key);
      final bool hasScript =
          await scripts.fileFor(key).exists() &&
          (await scripts.load(key)).audibleLines.isNotEmpty;
      candidates.add(
        _ExportCandidate(
          bookKey: key,
          title: row.title,
          audioLines: audio?.manifest.lines.length,
          hasScript: hasScript,
          busy: busy(key) != null,
        ),
      );
    }
    if (!mounted) return;
    setState(() {
      _candidates = candidates;
      _seriesTitle = seriesTitle == null || seriesTitle.isEmpty
          ? null
          : seriesTitle;
      for (final _ExportCandidate c in candidates) {
        if (c.bookKey == widget.bookKey && c.exportable) {
          _selected.add(c.bookKey);
        }
      }
    });
  }

  @override
  void dispose() {
    _task?.removeListener(_onTask);
    super.dispose();
  }

  void _onTask() {
    if (mounted) setState(() {});
  }

  List<_ExportCandidate> get _picked => <_ExportCandidate>[
    for (final _ExportCandidate c in _candidates ?? const <_ExportCandidate>[])
      if (_selected.contains(c.bookKey) && c.exportable) c,
  ];

  Future<void> _export() async {
    final List<_ExportCandidate> picked = _picked;
    if (picked.isEmpty) {
      FushiToast.show(
        msg: t.manga_audio_package_export_none,
        severity: ToastSeverity.warning,
      );
      return;
    }
    final String fileName = mangaAudioPackageFileName(
      picked.length > 1 && _seriesTitle != null
          ? _seriesTitle!
          : picked.first.title,
    );
    final bool desktop = isDesktopPlatform;
    String? outPath;
    if (desktop) {
      outPath = await FilePicker.platform.saveFile(
        dialogTitle: t.manga_audio_package_export,
        fileName: fileName,
      );
      if (outPath == null || outPath.trim().isEmpty) return;
      if (!outPath.toLowerCase().endsWith(kMangaAudioPackageExtension)) {
        outPath = '$outPath$kMangaAudioPackageExtension';
      }
    } else {
      final Directory staging = await prepareTtsAudiobookShareStagingDir(
        Directory(p.join(Directory.systemTemp.path, 'fushi_manga_audio_share')),
      );
      outPath = p.join(staging.path, fileName);
    }
    setState(() => _starting = true);
    final MangaPackageExportPlan plan;
    try {
      plan = await planMangaAudioPackageExport(
        widget.appModel,
        <MangaPackageExportItem>[
          for (final _ExportCandidate c in picked)
            MangaPackageExportItem(c.bookKey, scriptOnly: c.audioLines == null),
        ],
        busy: mangaAudioPackageBusyCheck(widget.appModel),
      );
    } on MangaAudioPackageException catch (e) {
      if (mounted) setState(() => _starting = false);
      FushiToast.show(
        msg: mangaAudioPackageErrorText(e.code),
        severity: ToastSeverity.error,
      );
      return;
    }
    final String out = outPath;
    final MangaAudioPackageTask task = _tasks.start(
      kind: MangaAudioPackageTaskKind.export,
      path: out,
      run: (MangaAudioPackageTask task) => runMangaAudioPackageExport(
        plan,
        outputPath: out,
        appLabel: _appLabel(widget.appModel),
        onProgress: task.report,
        cancel: task.cancelToken,
      ),
    );
    if (!mounted) return;
    setState(() {
      _starting = false;
      _task = task..addListener(_onTask);
    });
    await task.whenDone;
    if (task.status == MangaAudioPackageTaskStatus.done) {
      if (desktop) {
        FushiToast.show(
          msg: t.manga_audio_package_export_done(path: out),
          severity: ToastSeverity.success,
        );
      } else {
        await FushiShare.shareFiles(<XFile>[
          XFile(out, name: p.basename(out)),
        ], subject: p.basename(out));
      }
    } else if (task.status == MangaAudioPackageTaskStatus.failed) {
      FushiToast.show(
        msg: mangaAudioPackageErrorText(task.errorCode),
        severity: ToastSeverity.error,
      );
    }
  }

  String _subtitle(_ExportCandidate c) {
    if (c.busy) return t.manga_audio_package_volume_busy;
    if (c.audioLines case final int lines) {
      return t.manga_audio_package_volume_audio(n: lines);
    }
    if (c.hasScript) return t.manga_audio_package_volume_script_only;
    return t.manga_audio_package_volume_unavailable;
  }

  @override
  Widget build(BuildContext context) {
    final List<_ExportCandidate>? candidates = _candidates;
    const String k = MangaAudioPackageExportPage.keyPrefix;
    final MangaAudioPackageTask? task = _task;
    final bool running = _starting || (task != null && !task.isTerminal);
    return FushiPageScaffold(
      masthead: true,
      title: t.manga_audio_package_export,
      body: candidates == null
          ? const Center(child: FushiCircularProgressIndicator())
          : Builder(
              builder: (BuildContext context) => _PackagePageBody(
                sections: <Widget>[
                  FushiInlineNotice(
                    key: const ValueKey<String>('$k-hint'),
                    severity: FushiNoticeSeverity.info,
                    message: t.manga_audio_package_export_hint,
                  ),
                  AdaptiveSettingsSection(
                    key: const ValueKey<String>('$k-volumes'),
                    title: _seriesTitle == null
                        ? null
                        : t.manga_audio_package_series(title: _seriesTitle!),
                    children: <Widget>[
                      for (final _ExportCandidate c in candidates)
                        AdaptiveSettingsSwitchRow(
                          key: ValueKey<String>('$k-volume-${c.bookKey}'),
                          title: c.title,
                          subtitle: _subtitle(c),
                          value: _selected.contains(c.bookKey) && c.exportable,
                          onChanged: c.exportable && !running
                              ? (bool on) => setState(
                                  () => on
                                      ? _selected.add(c.bookKey)
                                      : _selected.remove(c.bookKey),
                                )
                              : null,
                        ),
                    ],
                  ),
                  _TaskFooter(
                    keyPrefix: k,
                    task: task,
                    tasks: _tasks,
                    runningLabel: t.manga_audio_package_exporting,
                    actionLabel: t.manga_audio_package_export_action,
                    actionIcon: FushiIcons.save,
                    onAction: running || _picked.isEmpty
                        ? null
                        : () => unawaited(_export()),
                  ),
                ],
              ),
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 导入
// ─────────────────────────────────────────────────────────────────────────

class MangaAudioPackageImportPage extends StatefulWidget {
  const MangaAudioPackageImportPage({
    required this.appModel,
    required this.path,
    this.tasks,
    super.key,
  });

  final AppModel appModel;
  final String path;
  final MangaAudioPackageTasks? tasks;

  static const String keyPrefix = 'manga-audio-package-import';

  @override
  State<MangaAudioPackageImportPage> createState() =>
      _MangaAudioPackageImportPageState();
}

class _MangaAudioPackageImportPageState
    extends State<MangaAudioPackageImportPage> {
  late final MangaAudioPackageTasks _tasks =
      widget.tasks ?? MangaAudioPackageTasks.instance;
  MangaPackageImportPlan? _plan;
  String? _planError;
  bool _asNew = false;
  MangaAudioPackageTask? _task;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPlan());
  }

  @override
  void dispose() {
    _task?.removeListener(_onTask);
    super.dispose();
  }

  void _onTask() {
    if (mounted) setState(() {});
  }

  Set<String> _availableVoices() {
    if (!widget.appModel.isPreferencesReady) return const <String>{};
    return <String>{
      for (final TtsVoicePreset v in ttsProductionPresets(
        TtsServices.of(widget.appModel.prefsRepo),
        widget.appModel,
      ))
        v.id,
    };
  }

  Future<void> _loadPlan() async {
    try {
      final MangaPackageImportPlan plan = await planMangaAudioPackageImport(
        widget.appModel,
        widget.path,
        asNew: _asNew,
        availableVoices: _availableVoices(),
        busy: mangaAudioPackageBusyCheck(widget.appModel),
      );
      if (mounted) setState(() => _plan = plan);
    } on MangaAudioPackageException catch (e) {
      if (mounted) {
        setState(() => _planError = mangaAudioPackageErrorText(e.code));
      }
    }
  }

  Future<void> _import() async {
    final MangaPackageImportPlan? plan = _plan;
    if (plan == null) return;
    if (plan.busyVolumes.isNotEmpty) {
      FushiToast.show(
        msg: t.manga_audio_package_error_busy,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (!plan.volumes.any(
      (MangaPackageImportVolumePlan v) =>
          v.action != MangaPackageImportAction.skip,
    )) {
      FushiToast.show(
        msg: t.manga_audio_package_import_nothing,
        severity: ToastSeverity.warning,
      );
      return;
    }
    if (plan.needsConfirm) {
      final int n = plan.volumes
          .where(
            (MangaPackageImportVolumePlan v) =>
                v.action == MangaPackageImportAction.useExisting && v.replaces,
          )
          .length;
      final bool ok = await showFushiConfirmDialog(
        context: context,
        title: t.manga_audio_package_replace_title,
        message: t.manga_audio_package_replace_body(n: n),
        confirmLabel: t.manga_audio_package_import_action,
        icon: FushiIcons.warning,
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    setState(() => _starting = true);
    final MangaPackageBusyCheck busy = mangaAudioPackageBusyCheck(
      widget.appModel,
    );
    final MangaAudioPackageTask task = _tasks.start(
      kind: MangaAudioPackageTaskKind.import,
      path: widget.path,
      run: (MangaAudioPackageTask task) => runMangaAudioPackageImport(
        widget.appModel,
        plan,
        runId: task.id,
        busy: busy,
        onProgress: task.report,
        onCommit: task.markCommitting,
        cancel: task.cancelToken,
      ),
    );
    setState(() {
      _starting = false;
      _task = task..addListener(_onTask);
    });
    await task.whenDone;
    if (task.status == MangaAudioPackageTaskStatus.done) {
      final Object? imported = task.result?['imported'];
      FushiToast.show(
        msg: t.manga_audio_package_import_done(
          n: imported is int ? imported : 0,
        ),
        severity: ToastSeverity.success,
      );
    } else if (task.status == MangaAudioPackageTaskStatus.failed) {
      FushiToast.show(
        msg: mangaAudioPackageErrorText(task.errorCode),
        severity: ToastSeverity.error,
      );
    }
  }

  String _planLine(MangaPackageImportVolumePlan v) {
    final String action = switch (v.action) {
      MangaPackageImportAction.useExisting =>
        t.manga_audio_package_plan_existing(title: v.localTitle ?? ''),
      MangaPackageImportAction.create => t.manga_audio_package_plan_create,
      MangaPackageImportAction.skip => t.manga_audio_package_plan_conflict(
        title: v.localTitle ?? '',
      ),
    };
    return <String>[
      action,
      if (v.volume.activePart case final MangaAudioPackagePart part)
        t.manga_audio_package_volume_audio(n: part.lines)
      else
        t.manga_audio_package_volume_script_only,
      if (v.busy != null) t.manga_audio_package_volume_busy,
      if (v.action == MangaPackageImportAction.useExisting && v.replaces)
        t.manga_audio_package_replaces,
      if (v.volume.scriptStale) t.manga_audio_package_script_stale,
    ].join(' · ');
  }

  /// 导入结束后的逐卷结局。
  String _resultLine(Map<String, Object?> v) {
    final String base = switch (v['status']) {
      'imported' => t.manga_audio_package_result_imported,
      'skipped' => t.manga_audio_package_result_skipped,
      _ => t.manga_audio_package_result_failed(
        reason: mangaAudioPackageErrorText(v['code'] as String?),
      ),
    };
    return <String>[
      base,
      if (v['scriptStale'] == true) t.manga_audio_package_script_stale,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    const String k = MangaAudioPackageImportPage.keyPrefix;
    final MangaPackageImportPlan? plan = _plan;
    final MangaAudioPackageTask? task = _task;
    final bool running = _starting || (task != null && !task.isTerminal);
    final Object? results = task?.result?['volumes'];
    final Set<String> missingVoices = <String>{
      for (final MangaPackageImportVolumePlan v
          in plan?.volumes ?? const <MangaPackageImportVolumePlan>[])
        ...v.missingVoices,
    };
    final Widget body;
    if (_planError != null) {
      body = _PackagePageBody(
        sections: <Widget>[
          FushiInlineNotice(
            key: const ValueKey<String>('$k-error'),
            severity: FushiNoticeSeverity.error,
            message: _planError!,
          ),
        ],
      );
    } else if (plan == null) {
      body = const Center(child: FushiCircularProgressIndicator());
    } else {
      body = _PackagePageBody(
        sections: <Widget>[
          AdaptiveSettingsSection(
            key: const ValueKey<String>('$k-volumes'),
            title: p.basename(widget.path),
            children: <Widget>[
              for (final MangaPackageImportVolumePlan v in plan.volumes)
                AdaptiveSettingsRow(
                  key: ValueKey<String>('$k-volume-${v.volume.id}'),
                  title: v.volume.title,
                  subtitle: results is List
                      ? _resultLine(<String, Object?>{
                          for (final Object? r in results)
                            if (r is Map && r['id'] == v.volume.id)
                              ...Map<String, Object?>.from(r),
                        })
                      : _planLine(v),
                  subtitleMaxLines: 3,
                ),
            ],
          ),
          for (final MangaAudioPackageSeries s in plan.manifest.series)
            if (s.title.isNotEmpty)
              AdaptiveSettingsSection(
                key: ValueKey<String>('$k-series-${s.id}'),
                children: <Widget>[
                  AdaptiveSettingsRow(
                    icon: FushiIcons.collection,
                    showIcon: true,
                    title: t.manga_audio_package_series(title: s.title),
                  ),
                ],
              ),
          if (plan.volumes.any(
            (MangaPackageImportVolumePlan v) =>
                v.match.kind == MangaPackageMatchKind.conflict,
          ))
            AdaptiveSettingsSection(
              key: const ValueKey<String>('$k-options'),
              children: <Widget>[
                AdaptiveSettingsSwitchRow(
                  key: const ValueKey<String>('$k-as-new'),
                  title: t.manga_audio_package_as_new,
                  value: _asNew,
                  onChanged: running || task != null
                      ? null
                      : (bool on) {
                          setState(() {
                            _asNew = on;
                            _plan = null;
                          });
                          unawaited(_loadPlan());
                        },
                ),
              ],
            ),
          if (missingVoices.isNotEmpty)
            FushiInlineNotice(
              key: const ValueKey<String>('$k-missing-voices'),
              severity: FushiNoticeSeverity.warning,
              message: t.manga_audio_package_missing_voices(
                voices: missingVoices.join('、'),
              ),
            ),
          _TaskFooter(
            keyPrefix: k,
            task: task,
            tasks: _tasks,
            runningLabel: t.manga_audio_package_importing,
            actionLabel: t.manga_audio_package_import_action,
            actionIcon: FushiIcons.importFile,
            onAction:
                running || task?.status == MangaAudioPackageTaskStatus.done
                ? null
                : () => unawaited(_import()),
          ),
        ],
      );
    }
    return FushiPageScaffold(
      masthead: true,
      title: t.manga_audio_package_import,
      body: body,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 共用版面
// ─────────────────────────────────────────────────────────────────────────

/// 页面正文：各块错峰进场。
class _PackagePageBody extends StatelessWidget {
  const _PackagePageBody({required this.sections});

  final List<Widget> sections;

  @override
  Widget build(BuildContext context) => FushiEntranceScope(
    child: ListView.separated(
      padding: EdgeInsets.only(
        top: 8 + MediaQuery.paddingOf(context).top,
        bottom: 24 + bottomSafeInsetOf(context),
        left: 16,
        right: 16,
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

/// 主按钮 + 任务进度 / 取消。
class _TaskFooter extends StatelessWidget {
  const _TaskFooter({
    required this.keyPrefix,
    required this.task,
    required this.tasks,
    required this.runningLabel,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAction,
  });

  final String keyPrefix;
  final MangaAudioPackageTask? task;
  final MangaAudioPackageTasks tasks;
  final String runningLabel;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final MangaAudioPackageTask? task = this.task;
    final bool running = task != null && !task.isTerminal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (running) ...<Widget>[
          Text(runningLabel, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          FushiLinearProgressIndicator(
            key: ValueKey<String>('$keyPrefix-progress'),
            value: task.progress,
          ),
          const SizedBox(height: 12),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            if (running && task.cancelToken.isCancelled == false)
              FushiPressScale(
                enabled: !task.committing,
                child: FushiTextButton(
                  key: ValueKey<String>('$keyPrefix-cancel'),
                  onPressed: task.committing ? null : () => tasks.cancel(task),
                  child: Text(t.cancel),
                ),
              ),
            const SizedBox(width: 8),
            FushiPressScale(
              enabled: onAction != null,
              child: FushiFilledButton.icon(
                key: ValueKey<String>('$keyPrefix-action'),
                onPressed: onAction,
                icon: FushiIcon(actionIcon),
                label: Text(actionLabel),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
