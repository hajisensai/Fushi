/// 互联远端视频的「生成日语字幕」：整条管线在**放视频的那台 host** 上跑（host 任务
/// `kind=video_subtitle`，`VideoSubtitleHostJobRunner`），本机只提交、轮询、取回 SRT。
///
/// - 识别、专名表、AI 校对都用 host 自己的模型与 AI 指派；host 没指派「字幕校对」
///   时它直接拒绝（400），报错原样给用户，不在本机悄悄改成不校对。
/// - 老 host 的 capability 里没有 `video_subtitle`：[RemoteVideoSubtitleJobStatus.unsupported]，
///   面板给「host 版本不支持」，不发任务。
/// - 整季（远端合集）：wire 上的远端视频只带合集**名**、不带 host 的合集 id，所以按
///   成员逐集提交 `videoId` 任务。host 侧 `SubtitleWorkContextLoader.forBook` 会把合集
///   成员解析到同一个作品键（`collection:<host 合集 id>`），各集共用 host 上的同一张
///   专名表（第一集生成，后面的复用）。已有 `.ja.srt` 的成员跳过。
/// - 产物：host 库视频会在 host 那边视频旁导出（`<视频名>.ja.srt`，视频有别的 ASS 时
///   另有套了它样式的 `.ja.ass`）；本机把取回的字幕（有 ASS 取 ASS）复制进
///   `video_subtitles/`，由视频页按「远端视频加外挂字幕」同一条路加载。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_host_job_runner.dart'
    show kVideoSubtitleJobKind, kVideoSubtitleSummaryOutput;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart'
    show VideoSubtitleStage;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart' show t;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/interconnect_job_client.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// 和 host 打交道的接缝（生产实现 [InterconnectVideoSubtitleHostPort]，测试注入 fake）。
abstract interface class RemoteVideoSubtitleHostPort {
  /// 放视频的那台 host 的任务能力；null = 连不上 / 没配对。
  Future<HostJobTarget?> probe();

  /// 提交一个 `video_subtitle` 任务并跟到终态（取消订阅 = 远端取消）。
  Stream<HostJobEvent> run({
    required HostJobTarget target,
    required Map<String, Object?> params,
    required Directory outputDir,
  });
}

/// 生产实现：[InterconnectJobClient]（与有声书「在互联 host 上转录」同一个客户端）。
class InterconnectVideoSubtitleHostPort implements RemoteVideoSubtitleHostPort {
  InterconnectVideoSubtitleHostPort({
    required this.client,
    required this.activeBaseUrl,
  });

  final InterconnectJobClient client;

  /// 互联当前连着的 host 地址（远端视频就来自它）；null = 还没连上。
  final String? Function() activeBaseUrl;

  @override
  Future<HostJobTarget?> probe() async {
    final String? baseUrl = activeBaseUrl();
    if (baseUrl == null || baseUrl.isEmpty) return null;
    return client.probeHost(baseUrl);
  }

  @override
  Stream<HostJobEvent> run({
    required HostJobTarget target,
    required Map<String, Object?> params,
    required Directory outputDir,
  }) => client.run(
    target: target,
    kind: kVideoSubtitleJobKind,
    params: params,
    inputs: const <File>[],
    outputDir: outputDir,
  );
}

/// 远端的一集（`RemoteVideoInfo.id` = host 的 `video_books.book_uid`）。
@immutable
class RemoteVideoSubtitleEpisode {
  const RemoteVideoSubtitleEpisode({
    required this.videoId,
    required this.title,
  });

  final String videoId;
  final String title;
}

/// 一次远端生成的目标。
@immutable
class RemoteVideoSubtitleTarget {
  const RemoteVideoSubtitleTarget({
    required this.title,
    required this.episodes,
    this.wholeSeason = false,
    this.skippedExisting = const <String>[],
  });

  final String title;
  final List<RemoteVideoSubtitleEpisode> episodes;
  final bool wholeSeason;

  /// 整季：已有日语字幕、不提交的成员标题。
  final List<String> skippedExisting;

  String get key =>
      'remote:${episodes.map((RemoteVideoSubtitleEpisode e) => e.videoId).join('|')}';
}

/// 远端任务的选项（AI 提供商是 host 自己的，不在这里）。
@immutable
class RemoteVideoSubtitleOptions {
  const RemoteVideoSubtitleOptions({
    this.proofread = false,
    this.segmenter = VideoSubtitleSegmenterMode.auto,
    this.mossBackend = MossBackendPreference.auto,
  });

  final bool proofread;
  final VideoSubtitleSegmenterMode segmenter;
  final MossBackendPreference mossBackend;
}

enum RemoteVideoSubtitleJobStatus {
  /// 正在问 host 支不支持。
  probing,
  running,
  succeeded,

  /// host 版本不支持 `video_subtitle`。
  unsupported,

  /// 连不上放视频的 host。
  unreachable,

  /// host 报错（[RemoteVideoSubtitleJob.error] 是 host 的原话）。
  failed,
  cancelled,
}

/// 一集在远端任务里的进度与结果。
class RemoteVideoSubtitleEpisodeProgress {
  RemoteVideoSubtitleEpisodeProgress(this.episode);

  final RemoteVideoSubtitleEpisode episode;

  /// 当前阶段（从 host 的进度文本 `<阶段>: <消息>` 解析）；null = 还没轮到。
  VideoSubtitleStage? stage;
  String? message;
  double progress = 0;

  /// 取回并复制进 `video_subtitles/` 的字幕（有套样式的 ASS 取 ASS，否则 SRT）；
  /// 没导出为 null。
  File? subtitle;

  /// host summary 里这一集的状态（`exported` / `skippedSong` …）与原因。
  String? status;
  String? reason;
  bool done = false;
}

/// 一次远端生成任务。
class RemoteVideoSubtitleJob extends ChangeNotifier {
  RemoteVideoSubtitleJob._(this.target, this.options)
    : episodes = <RemoteVideoSubtitleEpisodeProgress>[
        for (final RemoteVideoSubtitleEpisode e in target.episodes)
          RemoteVideoSubtitleEpisodeProgress(e),
      ];

  final RemoteVideoSubtitleTarget target;
  final RemoteVideoSubtitleOptions options;
  final List<RemoteVideoSubtitleEpisodeProgress> episodes;
  final Completer<void> _done = Completer<void>();

  RemoteVideoSubtitleJobStatus status = RemoteVideoSubtitleJobStatus.probing;

  /// 执行的 host（显示名）。
  String? hostLabel;

  /// host 的报错原话（[RemoteVideoSubtitleJobStatus.failed]）。
  String? error;

  /// 正在跑的那一集下标。
  int current = 0;

  bool _cancelRequested = false;
  StreamSubscription<HostJobEvent>? _subscription;

  /// 正在跑的那一集的收尾：订阅被取消后流不再发任何事件，靠它把这一集结束掉。
  void Function()? _onCancel;

  bool get isRunning =>
      status == RemoteVideoSubtitleJobStatus.probing ||
      status == RemoteVideoSubtitleJobStatus.running;
  bool get cancelRequested => _cancelRequested;
  Future<void> get done => _done.future;

  /// 取消：断开订阅，客户端随即 DELETE 远端任务（host 的管线缓存保留，重提交即续）。
  void cancel() {
    if (!isRunning || _cancelRequested) return;
    _cancelRequested = true;
    unawaited(_subscription?.cancel());
    _onCancel?.call();
    notifyListeners();
  }

  void _changed() => notifyListeners();

  void _finish(RemoteVideoSubtitleJobStatus next) {
    status = next;
    if (!_done.isCompleted) _done.complete();
    notifyListeners();
  }
}

/// host 进度文本 `<阶段>: <消息>` → 阶段（认不出 null）。
VideoSubtitleStage? parseRemoteVideoSubtitleStage(String? message) {
  if (message == null) return null;
  final int colon = message.indexOf(':');
  final String name = (colon < 0 ? message : message.substring(0, colon))
      .trim();
  for (final VideoSubtitleStage s in VideoSubtitleStage.values) {
    if (s.name == name) return s;
  }
  return null;
}

/// host 报错的原话：HTTP 错误体是 `{"error": "..."}` 时取 `error`，否则原样。
String remoteVideoSubtitleErrorText(Object error) {
  if (error is HostJobRemoteException) {
    final String? detail = error.detail;
    if (detail == null || detail.trim().isEmpty) return error.code;
    try {
      final Object? decoded = jsonDecode(detail);
      if (decoded is Map) {
        final Object? message = decoded['message'] ?? decoded['error'];
        if (message is String && message.trim().isNotEmpty) return message;
      }
    } on FormatException {
      // 不是 JSON：原样。
    }
    return detail;
  }
  return '$error';
}

/// 远端生成的编排（进程内一份，面板重开能接回）。
class RemoteVideoSubtitleService {
  RemoteVideoSubtitleService({
    required this.host,
    Future<Directory> Function()? workRoot,
    Future<Directory> Function()? subtitlesDir,
  }) : _workRoot = workRoot ?? _defaultWorkRoot,
       _subtitlesDir = subtitlesDir ?? AppPaths.videoSubtitlesDirectory;

  final RemoteVideoSubtitleHostPort host;
  final Future<Directory> Function() _workRoot;
  final Future<Directory> Function() _subtitlesDir;

  static Future<Directory> _defaultWorkRoot() async => Directory(
    p.join(Directory.systemTemp.path, 'fushi_remote_subtitle_jobs'),
  );

  final Map<String, RemoteVideoSubtitleJob> _latest =
      <String, RemoteVideoSubtitleJob>{};
  RemoteVideoSubtitleJob? _active;
  int _seq = 0;

  RemoteVideoSubtitleJob? get activeJob => _active;

  RemoteVideoSubtitleJob? latestJobFor(RemoteVideoSubtitleTarget target) =>
      _latest[target.key];

  /// 只问 host 支不支持（面板打开时显示用）。
  Future<HostJobTarget?> probe() => host.probe();

  /// 起任务并立即返回。已有远端任务在跑抛 [StateError]（面板先接回它）。
  RemoteVideoSubtitleJob start(
    RemoteVideoSubtitleTarget target,
    RemoteVideoSubtitleOptions options,
  ) {
    final RemoteVideoSubtitleJob? active = _active;
    if (active != null && active.isRunning) {
      throw StateError('remote subtitle job already running');
    }
    final RemoteVideoSubtitleJob job = RemoteVideoSubtitleJob._(
      target,
      options,
    );
    _active = job;
    _latest[target.key] = job;
    unawaited(_run(job));
    return job;
  }

  Future<void> _run(RemoteVideoSubtitleJob job) async {
    try {
      final HostJobTarget? target = await host.probe();
      if (job.cancelRequested) {
        job._finish(RemoteVideoSubtitleJobStatus.cancelled);
        return;
      }
      if (target == null) {
        job._finish(RemoteVideoSubtitleJobStatus.unreachable);
        return;
      }
      job.hostLabel = target.label;
      if (!target.supports(kVideoSubtitleJobKind)) {
        job._finish(RemoteVideoSubtitleJobStatus.unsupported);
        return;
      }
      job.status = RemoteVideoSubtitleJobStatus.running;
      job._changed();
      final Directory root = await _workRoot();
      for (int i = 0; i < job.episodes.length; i++) {
        if (job.cancelRequested) break;
        job.current = i;
        final RemoteVideoSubtitleEpisodeProgress e = job.episodes[i];
        final Directory out = Directory(
          p.join(
            root.path,
            '${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
          ),
        );
        final Map<String, File>? outputs = await _runEpisode(
          job,
          target,
          e,
          out,
        );
        if (outputs == null) return; // 失败 / 取消已收尾
        await _collect(target, e, outputs);
        e.done = true;
        job._changed();
        if (out.existsSync()) await out.delete(recursive: true);
      }
      job._finish(
        job.cancelRequested
            ? RemoteVideoSubtitleJobStatus.cancelled
            : RemoteVideoSubtitleJobStatus.succeeded,
      );
    } catch (error) {
      job.error = remoteVideoSubtitleErrorText(error);
      job._finish(RemoteVideoSubtitleJobStatus.failed);
    } finally {
      if (identical(_active, job)) _active = null;
    }
  }

  /// 跑一集；成功返回产物，失败 / 取消收尾任务并返回 null。
  Future<Map<String, File>?> _runEpisode(
    RemoteVideoSubtitleJob job,
    HostJobTarget target,
    RemoteVideoSubtitleEpisodeProgress e,
    Directory out,
  ) {
    final Completer<Map<String, File>?> result =
        Completer<Map<String, File>?>();
    job._onCancel = () {
      if (result.isCompleted) return;
      job._finish(RemoteVideoSubtitleJobStatus.cancelled);
      result.complete(null);
    };
    final Stream<HostJobEvent> events = host.run(
      target: target,
      params: <String, Object?>{
        'videoId': e.episode.videoId,
        'proofread': job.options.proofread,
        'segmenter': job.options.segmenter.name,
        'mossBackend': job.options.mossBackend.name,
      },
      outputDir: out,
    );
    job._subscription = events.listen(
      (HostJobEvent event) {
        switch (event) {
          case HostJobUploading():
            break;
          case HostJobRunning(:final double progress, :final String? message):
            e
              ..progress = progress
              ..message = message
              ..stage = parseRemoteVideoSubtitleStage(message) ?? e.stage;
            job._changed();
          case HostJobDone(:final Map<String, File> outputs):
            if (!result.isCompleted) result.complete(outputs);
        }
      },
      onError: (Object error) {
        if (result.isCompleted) return;
        final bool cancelled =
            job.cancelRequested ||
            (error is HostJobRemoteException && error.code == 'cancelled');
        if (cancelled) {
          job._finish(RemoteVideoSubtitleJobStatus.cancelled);
        } else {
          job.error = remoteVideoSubtitleErrorText(error);
          job._finish(RemoteVideoSubtitleJobStatus.failed);
        }
        result.complete(null);
      },
      onDone: () {
        if (result.isCompleted) return;
        // 流没给结果就结束了（不该发生）：按失败收尾，不让任务挂住。
        job.error = t.video_subtitle_ai_remote_result_missing;
        job._finish(RemoteVideoSubtitleJobStatus.failed);
        result.complete(null);
      },
      cancelOnError: true,
    );
    return result.future.whenComplete(() {
      job._onCancel = null;
    });
  }

  /// 读 summary.json 记下这一集的去向，把导出的字幕（有 ASS 取 ASS，否则 SRT）复制进
  /// `video_subtitles/`。
  Future<void> _collect(
    HostJobTarget target,
    RemoteVideoSubtitleEpisodeProgress e,
    Map<String, File> outputs,
  ) async {
    String? outputName;
    final File? summary = outputs[kVideoSubtitleSummaryOutput];
    if (summary != null && summary.existsSync()) {
      try {
        final Object? decoded = jsonDecode(await summary.readAsString());
        final Object? list = decoded is Map ? decoded['episodes'] : null;
        if (list is List && list.isNotEmpty && list.first is Map) {
          final Map<Object?, Object?> first =
              list.first as Map<Object?, Object?>;
          e
            ..status = first['status'] as String?
            ..reason = first['reason'] as String?;
          // 套了参考样式的 ASS 优先（颜色 / 位置），没有再取 SRT。
          outputName =
              first['styledOutput'] as String? ?? first['output'] as String?;
        }
      } on FormatException {
        // summary 坏了：退回按扩展名找 SRT。
      }
    }
    File? srt = outputName == null ? null : outputs[outputName];
    srt ??= outputs.values
        .where((File f) => f.path.toLowerCase().endsWith('.srt'))
        .firstOrNull;
    if (srt == null || !srt.existsSync()) return;
    final Directory dir = await _subtitlesDir();
    await dir.create(recursive: true);
    final String key = sha256
        .convert(utf8.encode('${target.baseUrl}|${e.episode.videoId}'))
        .toString()
        .substring(0, 12);
    final File dest = File(
      p.join(dir.path, 'host-$key-${p.basename(srt.path)}'),
    );
    await srt.copy(dest.path);
    e
      ..subtitle = dest
      ..status ??= 'exported';
  }
}

/// 进程内共用的实例：面板 / 合集页 / 视频页共用任务表（重开面板接回同一个任务）。
/// 远端视频都来自互联当前连着的 host（[InterconnectSyncBackend.instance]），任务就
/// 打到那一台。
RemoteVideoSubtitleService appRemoteVideoSubtitleService(AppModel appModel) =>
    _sharedRemote ??= RemoteVideoSubtitleService(
      host: InterconnectVideoSubtitleHostPort(
        client: InterconnectJobClient(repo: SyncRepository(appModel.database)),
        activeBaseUrl: () =>
            InterconnectSyncBackend.instance.resolvedHostBaseUrl,
      ),
    );

RemoteVideoSubtitleService? _sharedRemote;
