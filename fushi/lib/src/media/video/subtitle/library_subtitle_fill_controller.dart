/// 整库补字幕的 app 侧任务：一次只跑一个，进度给面板（[ChangeNotifier]）与
/// `video job`（[VideoRemoteJob] 镜像）两边看；每次跑完把报告落盘
/// （`<support>/subtitle_fill/<id>.json`），撤销按报告来——app 重启后照样能撤。
/// 与设计系统无关（无 UI）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/library_subtitle_fill.dart';
import 'package:material_ui/material_ui.dart' show ChangeNotifier;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service_entry.dart'
    show appVideoSubtitleService;
import 'package:fushi/src/media/video/subtitle/library_subtitle_fill_host.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// 一次整库补字幕任务的状态。
class LibrarySubtitleFillJob extends ChangeNotifier {
  LibrarySubtitleFillJob._({
    required this.id,
    required this.options,
    required this.total,
  });

  final String id;
  final LibrarySubtitleFillOptions options;
  final int total;
  final List<SubtitleFillOutcome> outcomes = <SubtitleFillOutcome>[];
  final SubtitleCancelSource _cancel = SubtitleCancelSource();
  final Completer<void> _done = Completer<void>();
  late final VideoRemoteJob mirror;

  bool _running = true;
  String? reportPath;

  bool get isRunning => _running;
  bool get cancelRequested => _cancel.isCancelled;
  Future<void> get done => _done.future;

  void cancel() {
    if (!_running) return;
    _cancel.cancel();
    notifyListeners();
  }

  /// 各结局的集数。
  Map<SubtitleFillAction, int> get counts {
    final Map<SubtitleFillAction, int> out = <SubtitleFillAction, int>{};
    for (final SubtitleFillOutcome o in outcomes) {
      out[o.action] = (out[o.action] ?? 0) + 1;
    }
    return out;
  }

  Map<String, Object?> summaryJson() => <String, Object?>{
    'jobId': id,
    'language': options.language,
    'dryRun': options.dryRun,
    'total': total,
    'done': outcomes.length,
    'counts': <String, int>{
      for (final MapEntry<SubtitleFillAction, int> e in counts.entries)
        e.key.name: e.value,
    },
    if (reportPath != null) 'report': reportPath,
  };

  Map<String, Object?> reportJson() => <String, Object?>{
    ...summaryJson(),
    'outcomes': <Map<String, Object?>>[
      for (final SubtitleFillOutcome o in outcomes) o.toJson(),
    ],
  };
}

/// 已有任务在跑时再起。
class LibrarySubtitleFillBusy implements Exception {
  const LibrarySubtitleFillBusy(this.active);

  final LibrarySubtitleFillJob active;
}

/// 整库补字幕的唯一入口（面板与控制通道共用）。
class LibrarySubtitleFillController extends ChangeNotifier {
  LibrarySubtitleFillController(this.appModel);

  final AppModel appModel;
  LibrarySubtitleFillJob? _active;
  LibrarySubtitleFillJob? _last;

  LibrarySubtitleFillJob? get active => _active;

  /// 最近一次（跑着的或刚结束的）。
  LibrarySubtitleFillJob? get latest => _active ?? _last;

  /// 起一个任务并立即返回。[bookUids] 为 null = 全库。
  Future<LibrarySubtitleFillJob> start(
    LibrarySubtitleFillOptions options, {
    Iterable<String>? bookUids,
  }) async {
    final LibrarySubtitleFillJob? running = _active;
    if (running != null && running.isRunning) {
      throw LibrarySubtitleFillBusy(running);
    }
    final List<SubtitleFillItem> items = await librarySubtitleFillItems(
      appModel.database,
      bookUids: bookUids,
    );
    // 精确到毫秒：「预览」紧接「开始」常在同一秒内，秒级 id 会让后一次的报告盖掉
    // 前一次、videoJob 镜像撞 id。
    final String id =
        'fill-${DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '').substring(0, 17)}';
    final LibrarySubtitleFillJob job = LibrarySubtitleFillJob._(
      id: id,
      options: options,
      total: items.length,
    );
    job.mirror = videoRemoteJobs.register(
      VideoRemoteJob(kind: VideoRemoteJobKind.subtitleFill, bookUid: id),
    )..onCancel = job.cancel;
    _active = job;
    notifyListeners();
    unawaited(_run(job, items));
    return job;
  }

  Future<void> _run(
    LibrarySubtitleFillJob job,
    List<SubtitleFillItem> items,
  ) async {
    final LibrarySubtitleFill fill = LibrarySubtitleFill(
      database: appModel.database,
      host: AppLibrarySubtitleFillHost(
        appModel: appModel,
        subtitles: appVideoSubtitleService(appModel),
        context: () => appModel.navigatorKey.currentContext,
      ),
      backfill: appModel.videoSubtitleBackfillService,
      seriesLanguage: appModel.seriesSubtitleLanguage,
    );
    try {
      await fill.run(
        items,
        job.options,
        cancel: job._cancel,
        onProgress: (int done, int total, SubtitleFillOutcome current) {
          job.outcomes.add(current);
          job.mirror.update(
            phase: current.action.name,
            fraction: total == 0 ? 1 : done / total,
            detail: '$done/$total ${current.title}: ${current.action.name}',
          );
          job.notifyListeners();
          // 每集落一次盘：任务跑几个小时，app 中途被关也留得下能撤销的报告。
          unawaited(_writeReport(job));
        },
      );
      await _writeReport(job);
      if (job.cancelRequested) {
        job.mirror.fail('cancelled', 'cancelled');
      } else {
        job.mirror.succeed(job.summaryJson());
      }
    } on Object catch (error) {
      job.mirror.fail('failed', '$error');
    } finally {
      job._running = false;
      if (!job._done.isCompleted) job._done.complete();
      _last = job;
      if (identical(_active, job)) _active = null;
      job.notifyListeners();
      notifyListeners();
    }
  }

  Future<void> _pendingWrite = Future<void>.value();

  /// 报告串行写（每集一次的写盘不能交错成半截 JSON）。
  Future<void> _writeReport(LibrarySubtitleFillJob job) {
    final Future<void> next = _pendingWrite.then((_) async {
      final Directory dir = await reportDirectory();
      await dir.create(recursive: true);
      final File file = File(p.join(dir.path, '${job.id}.json'));
      final File temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(job.reportJson()), flush: true);
      await temp.rename(file.path);
      job.reportPath = file.path;
    });
    _pendingWrite = next.catchError((Object _) {});
    return next;
  }

  /// 报告目录 `<support>/subtitle_fill`。
  static Future<Directory> reportDirectory() async => Directory(
    p.join((await AppPaths.supportRootDirectory()).path, 'subtitle_fill'),
  );

  /// 撤销 [jobId] 那次补字幕（读落盘的报告）。返回还原的集数；报告不存在抛
  /// [FileSystemException]；[jobId] 不是本控制器发的任务 id 抛 [FormatException]
  /// （它拼进报告路径，又经控制通道外来：`../` 能让撤销按任意 JSON 删文件）。
  Future<int> undo(String jobId) async {
    if (!isLibrarySubtitleFillJobId(jobId)) {
      throw FormatException('not a subtitle fill job id', jobId);
    }
    final LibrarySubtitleFillJob? running = _active;
    if (running != null && running.isRunning && running.id == jobId) {
      throw LibrarySubtitleFillBusy(running);
    }
    final File file = File(
      p.join((await reportDirectory()).path, '$jobId.json'),
    );
    final Map<String, Object?> report =
        jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final List<SubtitleFillOutcome> outcomes = <SubtitleFillOutcome>[
      for (final Object? raw
          in report['outcomes'] as List<Object?>? ?? const <Object?>[])
        if (raw is Map<String, Object?>) subtitleFillOutcomeFromJson(raw),
    ];
    return undoLibrarySubtitleFill(appModel.database, outcomes);
  }
}

/// [LibrarySubtitleFillController.start] 发的任务 id 形状（`fill-` + UTC 时间戳数字，
/// 早期秒级的 14 位也认，旧报告照样能撤）。撤销前必须过这道：id 拼进报告路径。
bool isLibrarySubtitleFillJobId(String id) =>
    RegExp(r'^fill-[0-9]{14,17}$').hasMatch(id);

/// [SubtitleFillOutcome.toJson] 的逆（撤销只用得到路径 / 选择相关字段）。
SubtitleFillOutcome subtitleFillOutcomeFromJson(Map<String, Object?> json) =>
    SubtitleFillOutcome(
      bookUid: json['bookUid'] as String? ?? '',
      title: json['title'] as String? ?? '',
      videoPath: json['videoPath'] as String? ?? '',
      action: SubtitleFillAction.values.firstWhere(
        (SubtitleFillAction a) => a.name == json['action'],
        orElse: () => SubtitleFillAction.failed,
      ),
      path: json['path'] as String?,
      previousSubtitleSource: json['previousSubtitleSource'] as String?,
      selectionChanged: json['selectionChanged'] == true,
      extraFiles: <String>[
        for (final Object? f
            in json['extraFiles'] as List<Object?>? ?? const <Object?>[])
          if (f is String) f,
      ],
    );

/// 面板与控制通道共用的单例（挂在 [AppModel] 生命周期上）。
final Expando<LibrarySubtitleFillController> _controllers =
    Expando<LibrarySubtitleFillController>('librarySubtitleFill');

LibrarySubtitleFillController librarySubtitleFillController(
  AppModel appModel,
) => _controllers[appModel] ??= LibrarySubtitleFillController(appModel);
