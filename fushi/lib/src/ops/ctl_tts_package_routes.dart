/// 有声漫画导出包的控制通道路由（CLI：`fushi_cli tts export` / `tts import-package` /
/// `tts package-task` / `tts package-cancel`；AI 助手的描述与撤销见
/// `op_descriptions_tts.dart`）。业务在 `manga_audio_package_export.dart` /
/// `manga_audio_package_import.dart`，任务表与工作台同一张（[MangaAudioPackageTasks]）。
///
/// - 导出：先同步做完逐卷校验（缺页图 / 缺音频 / 没成品 / 正在标注或生成，当场 4xx），
///   再起后台任务写包；`wait=true` 等任务结束再返回；
/// - 导入：先同步读包清单定计划（`dryRun=true` 到此为止）；会替换本机已有演出稿 /
///   成品时要 `confirm=true`（否则 409），本机卷在标注 / 生成时 409；再起后台任务。
library;

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_package.dart'
    show kMangaAudioPackageExtension;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/cast/series_cast_resolver.dart'
    show kSeriesKeyCollectionPrefix, resolveSeriesKey, seriesMemberBooks;
import 'package:fushi/src/media/manga/audio/manga_audio_package_export.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_package_import.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_package_io.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_package_tasks.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart'
    show isLocalMangaVolume;
import 'package:fushi/src/media/manga/audio/manga_audio_volume_busy.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_workbench_entry.dart'
    show mangaHasAudio;
import 'package:fushi/src/ops/ctl_tts_support.dart';

/// 路由根：`/api/admin/tts/manga-packages/...`。
const String kTtsMangaPackageCtlRoot = '/api/admin/tts/manga-packages';

/// 这一卷现在不能导出 / 被导入替换 / 撤销导入的原因（标注 / 生成在跑，或别的导入占着
/// 它，判据见 [mangaVolumeBusy]）；null = 可以。[except] = 导入任务落库时复查用，不把
/// 它自己算进去。
String? ttsMangaBusyReason(
  TtsCtlDeps deps,
  String bookKey, {
  MangaAudioPackageTask? except,
}) => switch (mangaVolumeBusy(
  bookKey,
  annotate: deps.annotateTasks(),
  renderQueue: deps.renderQueue(),
  packages: deps.packageTasks(),
  except: except,
)) {
  null => null,
  MangaVolumeBusy.annotating => '正在标注，等它结束或先取消（tts annotate-cancel）',
  MangaVolumeBusy.rendering => '正在生成，等它结束或先取消（tts render-cancel）',
  MangaVolumeBusy.importing => '正在导入有声漫画包，等它结束（tts package-task）',
};

/// 导出 / 导入的业务错误 → 控制通道错误（码 `manga_package_<code>`）。
CtlFailure ttsMangaPackageFailure(MangaAudioPackageException e) {
  final int status = switch (e.code) {
    'not_found' => 404,
    'busy' || 'export_running' || 'import_running' || 'plan_stale' => 409,
    _ => 422,
  };
  final String details = e.details.isEmpty
      ? ''
      : '：${e.details.take(5).join('、')}${e.details.length > 5 ? ' …' : ''}';
  return CtlFailure(status, 'manga_package_${e.code}', '${e.message}$details');
}

List<CtlRoute> buildTtsPackageCtlRoutes(TtsCtlDeps deps) {
  final _PackageHandlers h = _PackageHandlers(deps);
  return <CtlRoute>[
    CtlRoute.post('$kTtsMangaPackageCtlRoot/export', h.export),
    CtlRoute.post('$kTtsMangaPackageCtlRoot/import', h.importPackage),
    CtlRoute.get('$kTtsMangaPackageCtlRoot/tasks/:id', h.task),
    CtlRoute.post('$kTtsMangaPackageCtlRoot/tasks/:id/cancel', h.cancel),
  ];
}

class _PackageHandlers {
  _PackageHandlers(this._deps);

  final TtsCtlDeps _deps;

  MangaAudioPackageTasks get _tasks => _deps.packageTasks();

  String? _busy(String bookKey) => ttsMangaBusyReason(_deps, bookKey);

  /// 包文件路径参数：绝对路径（CLI 侧已转）。
  String _absolutePath(CtlCall call, String name) {
    final String raw = (call.optString(name) ?? '').trim();
    if (raw.isEmpty || !p.isAbsolute(raw)) {
      throw CtlFailure.badRequest('$name 应为绝对路径，收到「$raw」');
    }
    return p.normalize(raw);
  }

  /// 导出：`keys`（book:<key> 数组）或 `series`（book:<系列里任一卷> / 系列身份
  /// `collection:<id>` / 合集名）+ 可选 `volumes`（只导这几卷）；`out` 目标文件（没带
  /// 扩展名自动补 `.fushi-manga-audio`）；`scriptOnly` 只带演出稿；`wait` 等写完。
  Future<Object?> export(CtlCall call) async {
    requireTtsMangaModule(_deps);
    String out = _absolutePath(call, 'out');
    if (!out.toLowerCase().endsWith(kMangaAudioPackageExtension)) {
      out = '$out$kMangaAudioPackageExtension';
    }
    final List<String> bookKeys = await _exportKeys(call);
    final bool scriptOnly = call.optBool('scriptOnly') ?? false;
    if (_tasks.activeExportTo(out) != null) {
      throw CtlFailure(409, 'manga_package_export_running', '已经在往 $out 导出');
    }
    final MangaPackageExportPlan plan;
    try {
      plan = await planMangaAudioPackageExport(
        _deps.appModel,
        <MangaPackageExportItem>[
          for (final String key in bookKeys)
            MangaPackageExportItem(key, scriptOnly: scriptOnly),
        ],
        busy: _busy,
      );
    } on MangaAudioPackageException catch (e) {
      throw ttsMangaPackageFailure(e);
    }
    final MangaAudioPackageTask task;
    try {
      // 计划期间可能已有别的导出起了同一个目标：任务表在起任务时再判一次。
      task = _tasks.start(
        kind: MangaAudioPackageTaskKind.export,
        path: out,
        run: (MangaAudioPackageTask task) async => _wireExportResult(
          await runMangaAudioPackageExport(
            plan,
            outputPath: out,
            appLabel: _deps.appLabel(),
            onProgress: task.report,
            cancel: task.cancelToken,
          ),
        ),
      );
    } on MangaAudioPackageException catch (e) {
      throw ttsMangaPackageFailure(e);
    }
    if (call.optBool('wait') == true) await task.whenDone;
    return task.toJson();
  }

  Future<List<String>> _exportKeys(CtlCall call) async {
    final List<String> rawKeys = call.stringList('keys');
    final String? series = call.optString('series')?.trim();
    if (rawKeys.isNotEmpty == (series != null && series.isNotEmpty)) {
      throw const CtlFailure.badRequest('给 keys（要导出的卷）或 series（一个系列），二选一');
    }
    if (rawKeys.isNotEmpty) {
      return <String>[
        for (final String raw in rawKeys) await ttsMangaBookKey(_deps, raw),
      ];
    }
    final String seriesKey = await _seriesKey(series!);
    final List<String> members = await seriesMemberBooks(
      _deps.appModel,
      seriesKey,
    );
    if (members.isEmpty) {
      throw CtlFailure.notFound('系列「$series」里没有本机的卷');
    }
    final List<String> only = <String>[
      for (final String raw in call.stringList('volumes'))
        await ttsMangaBookKey(_deps, raw),
    ];
    if (only.isEmpty) {
      // 整个系列：只取能导出的卷——要成品的话是有登记成品的卷（没有成品的卷要
      // 明确点名或用 scriptOnly），只要演出稿的话是本地漫画卷全部。
      final FushiDatabase db = _deps.appModel.database;
      final bool scriptOnly = call.optBool('scriptOnly') ?? false;
      final List<String> picked = <String>[];
      for (final String key in members) {
        final EpubBookRow? row = await db.getEpubBook(key);
        if (row == null || !isLocalMangaVolume(row)) continue;
        if (!scriptOnly && !await mangaHasAudio(db, key)) continue;
        picked.add(key);
      }
      if (picked.isEmpty) {
        throw CtlFailure(
          422,
          'manga_package_no_audio',
          '系列「$series」里没有登记好有声成品的卷（只导出演出稿用 scriptOnly）',
        );
      }
      return picked;
    }
    for (final String key in only) {
      if (!members.contains(key)) {
        throw CtlFailure.rejected('${ttsMangaWireKey(key)} 不在系列「$series」里');
      }
    }
    return <String>[
      for (final String key in members)
        if (only.contains(key)) key,
    ];
  }

  /// `--series` 的值 → 系列身份：`book:<key>`（那一卷所属的系列）、系列身份本身
  /// （`collection:<id>` 等）、或合集名。
  Future<String> _seriesKey(String raw) async {
    if (raw.startsWith('book:')) {
      final String bookKey = await ttsMangaBookKey(_deps, raw);
      final String? key = await resolveSeriesKey(_deps.appModel, bookKey);
      if (key == null) {
        throw CtlFailure.rejected('$raw 不属于任何系列');
      }
      return key;
    }
    final FushiDatabase db = _deps.appModel.database;
    if (raw.startsWith(kSeriesKeyCollectionPrefix) || raw.contains(':')) {
      return raw;
    }
    final MediaCollectionRow? collection = await db
        .getMediaCollectionByNaturalKey(raw, 'collection');
    if (collection == null) {
      throw CtlFailure.notFound('没有叫「$raw」的合集 / 系列');
    }
    return '$kSeriesKeyCollectionPrefix${collection.id}';
  }

  Map<String, Object?> _wireExportResult(Map<String, Object?> result) =>
      <String, Object?>{
        ...result,
        'volumes': <Map<String, Object?>>[
          for (final Object? v
              in (result['volumes'] as List<Object?>?) ?? const <Object?>[])
            if (v is Map) _wireVolume(Map<String, Object?>.from(v)),
        ],
      };

  /// 结果里的 bookKey 换成条目键（`key`）。
  Map<String, Object?> _wireVolume(Map<String, Object?> v) {
    final Object? bookKey = v.remove('bookKey');
    return <String, Object?>{
      if (bookKey is String) 'key': ttsMangaWireKey(bookKey),
      ...v,
    };
  }

  /// 导入：`file` 包的绝对路径；`dryRun` 只出计划；`asNew` 冲突卷作为新卷导入；
  /// `confirm` 同意替换本机已有的演出稿 / 成品；`wait` 等导入结束。
  Future<Object?> importPackage(CtlCall call) async {
    requireTtsMangaModule(_deps);
    final String file = _absolutePath(call, 'file');
    final bool dryRun = call.optBool('dryRun') ?? false;
    if (!dryRun) requireTtsWritable(_deps);
    final MangaPackageImportPlan plan;
    try {
      plan = await planMangaAudioPackageImport(
        _deps.appModel,
        file,
        asNew: call.optBool('asNew') ?? false,
        availableVoices: _deps.voiceIds().toSet(),
        busy: _busy,
      );
    } on MangaAudioPackageException catch (e) {
      throw ttsMangaPackageFailure(e);
    }
    final Map<String, Object?> planJson = _wirePlan(plan);
    if (dryRun) return <String, Object?>{'dryRun': true, ...planJson};
    final List<MangaPackageImportVolumePlan> busy = plan.busyVolumes;
    if (busy.isNotEmpty) {
      throw CtlFailure(
        409,
        'manga_package_busy',
        '本机这些卷正在标注 / 生成 / 导入：'
            '${busy.map((MangaPackageImportVolumePlan v) => v.localTitle ?? v.volume.title).join('、')}',
      );
    }
    if (plan.needsConfirm && call.optBool('confirm') != true) {
      final List<String> titles = <String>[
        for (final MangaPackageImportVolumePlan v in plan.volumes)
          if (v.action == MangaPackageImportAction.useExisting && v.replaces)
            v.localTitle ?? v.volume.title,
      ];
      throw CtlFailure(
        409,
        'manga_package_replaces',
        '导入会替换本机这些卷已有的演出稿 / 有声成品：${titles.join('、')}；'
            '确认后带 confirm=true 再导入',
      );
    }
    if (!plan.volumes.any(
      (MangaPackageImportVolumePlan v) =>
          v.action != MangaPackageImportAction.skip,
    )) {
      throw const CtlFailure.rejected(
        '包里的卷都与本机同名卷冲突（页数 / OCR 不一致）：要作为新卷导入带 asNew=true',
      );
    }
    final MangaAudioPackageTask task;
    try {
      task = _tasks.start(
        kind: MangaAudioPackageTaskKind.import,
        path: file,
        claims: mangaPackageImportClaims(plan),
        run: (MangaAudioPackageTask task) async {
          final Map<String, Object?> result = await runMangaAudioPackageImport(
            _deps.appModel,
            plan,
            runId: task.id,
            busy: (String bookKey) =>
                ttsMangaBusyReason(_deps, bookKey, except: task),
            onProgress: task.report,
            onCommit: task.markCommitting,
            onCreated: task.claimVolume,
            cancel: task.cancelToken,
          );
          return _wireExportResult(result);
        },
      );
    } on MangaAudioPackageException catch (e) {
      throw ttsMangaPackageFailure(e);
    }
    if (call.optBool('wait') == true) await task.whenDone;
    return task.toJson();
  }

  Map<String, Object?> _wirePlan(MangaPackageImportPlan plan) {
    final Map<String, Object?> json = plan.toJson();
    return <String, Object?>{
      ...json,
      'volumes': <Map<String, Object?>>[
        for (final Object? v in json['volumes']! as List<Object?>)
          if (v is Map) _wireVolume(Map<String, Object?>.from(v)),
      ],
    };
  }

  MangaAudioPackageTask _requireTask(CtlCall call) {
    final String id = call.params['id'] ?? '';
    final MangaAudioPackageTask? task = _tasks.byId(id);
    if (task == null) throw CtlFailure.notFound('没有导出 / 导入任务 $id');
    return task;
  }

  /// 一个导出 / 导入任务（`wait=true` 等它结束）。
  Future<Object?> task(CtlCall call) async {
    final MangaAudioPackageTask task = _requireTask(call);
    if (call.optBool('wait') == true) await task.whenDone;
    return task.toJson();
  }

  Future<Object?> cancel(CtlCall call) async {
    final MangaAudioPackageTask task = _requireTask(call);
    return switch (_tasks.cancel(task)) {
      MangaAudioPackageCancelOutcome.requested => task.toJson(),
      MangaAudioPackageCancelOutcome.committing =>
        throw const CtlFailure.conflict('导入已经开始落库，不能取消（结束后可撤销）'),
      MangaAudioPackageCancelOutcome.finished =>
        throw const CtlFailure.conflict('任务已经结束'),
    };
  }
}
