/// 「转录后入库」队列：只有音频的有声书下载完成后，在后台用设备端语音模型
/// 转出字幕，再入库（有正文 → 对齐；没有 → 独立字幕书）。
///
/// 为什么要单独一个队列而不是在导入那一步里同步跑：一本书的转录是小时级的，
/// 视频/发现下载管线是单并发的，同步跑会把其它所有下载堵住几个小时。
///
/// - 落盘：任务清单是一个 JSON 文件（原子写：先写 `.tmp` 再 rename）。
/// - 单并发串行：转录本身吃满 CPU/GPU，并行只会互相拖慢。
/// - 重启续跑：进程退出时 running 的任务下次 [load] 回到 queued。转录服务的
///   中间进度按「音频路径 + 语言」落在它自己的任务目录里，重跑会从断点接着来。
/// - 转录与入库都是注入的端口（[AudiobookTranscriber] / [AudiobookTranscribeImporter]），
///   本类不 import 任何 ASR 或数据库代码，测试用假端口即可覆盖全部编排。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_notifier.dart';

/// 任务生命周期。[done] / [failed] / [cancelled] 是终态。
enum AudiobookTranscribeJobStatus { queued, running, done, failed, cancelled }

/// running 状态下进行到哪一步。
enum AudiobookTranscribeJobPhase {
  preparing,
  downloadingModel,
  transcribing,
  importing,
}

/// 队列里的一个任务（可变快照；变更经队列 notifyListeners 广播）。
class AudiobookTranscribeJob {
  AudiobookTranscribeJob({
    required this.id,
    required this.title,
    required this.audioPaths,
    this.contentPath,
    required this.createdAt,
    required this.updatedAt,
    this.status = AudiobookTranscribeJobStatus.queued,
    this.phase,
    this.progress,
    this.error,
    this.resultKey,
  });

  factory AudiobookTranscribeJob.fromJson(Map<String, Object?> json) {
    final String? phase = json['phase'] as String?;
    return AudiobookTranscribeJob(
      id: json['id']! as String,
      title: json['title']! as String,
      audioPaths: <String>[
        for (final Object? path in json['audioPaths']! as List<Object?>)
          path! as String,
      ],
      contentPath: json['contentPath'] as String?,
      createdAt: json['createdAt']! as int,
      updatedAt: json['updatedAt']! as int,
      status: AudiobookTranscribeJobStatus.values.byName(
        json['status']! as String,
      ),
      phase: phase == null
          ? null
          : AudiobookTranscribeJobPhase.values.byName(phase),
      progress: (json['progress'] as num?)?.toDouble(),
      error: json['error'] as String?,
      resultKey: json['resultKey'] as String?,
    );
  }

  final String id;
  final String title;
  final List<String> audioPaths;
  final String? contentPath;
  final int createdAt;
  int updatedAt;
  AudiobookTranscribeJobStatus status;
  AudiobookTranscribeJobPhase? phase;

  /// 当前步骤的完成度 0..1；null = 不确定。
  double? progress;
  String? error;

  /// 入库后的身份键；任务 done 而它为 null = 同名书已在库被跳过。
  String? resultKey;

  bool get isTerminal =>
      status == AudiobookTranscribeJobStatus.done ||
      status == AudiobookTranscribeJobStatus.failed ||
      status == AudiobookTranscribeJobStatus.cancelled;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'audioPaths': audioPaths,
    'contentPath': contentPath,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'status': status.name,
    'phase': phase?.name,
    'progress': progress,
    'error': error,
    'resultKey': resultKey,
  };
}

/// 取消信号。转录端口在 [onCancel] 里登记「请求暂停」，取消后抛
/// [AudiobookTranscribeCancelled]。
class AudiobookTranscribeCancelToken {
  bool _cancelled = false;
  final List<void Function()> _callbacks = <void Function()>[];

  bool get isCancelled => _cancelled;

  void onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
      return;
    }
    _callbacks.add(callback);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final void Function() callback in _callbacks) {
      callback();
    }
  }
}

/// 转录端口在被取消时抛它。
class AudiobookTranscribeCancelled implements Exception {
  const AudiobookTranscribeCancelled();

  @override
  String toString() => 'AudiobookTranscribeCancelled';
}

/// 转录端口：把 [job] 的音频转成字幕，返回字幕文件路径（逐 token 时间 sidecar
/// 放在同目录，入库链路会自己找）。失败抛异常；被取消抛
/// [AudiobookTranscribeCancelled]。
abstract interface class AudiobookTranscriber {
  Future<String> transcribe(
    AudiobookTranscribeJob job, {
    required void Function(AudiobookTranscribeJobPhase phase, double? progress)
    onProgress,
    required AudiobookTranscribeCancelToken cancel,
  });
}

/// 入库端口：拿转出的字幕把 [job] 入库，返回身份键；同名书已在库返回 null。
typedef AudiobookTranscribeImporter =
    Future<String?> Function(AudiobookTranscribeJob job, String subtitlePath);

class AudiobookTranscribeImportQueue extends EngineChangeNotifier {
  AudiobookTranscribeImportQueue({
    required File store,
    required AudiobookTranscriber transcriber,
    required AudiobookTranscribeImporter importer,
    DateTime Function()? now,
  }) : _store = store,
       _transcriber = transcriber,
       _importer = importer,
       _now = now ?? DateTime.now;

  final File _store;
  final AudiobookTranscriber _transcriber;
  final AudiobookTranscribeImporter _importer;
  final DateTime Function() _now;

  final List<AudiobookTranscribeJob> _jobs = <AudiobookTranscribeJob>[];
  AudiobookTranscribeCancelToken? _runningCancel;
  String? _runningId;
  Future<void>? _drainFuture;
  Future<void> _persistChain = Future<void>.value();
  Future<void>? _loadFuture;
  int _idSeq = 0;
  bool _closed = false;

  /// 全部任务，按入队先后。
  List<AudiobookTranscribeJob> get jobs =>
      List<AudiobookTranscribeJob>.unmodifiable(_jobs);

  /// 把磁盘上的任务读回来（running → queued）并开始处理。幂等。
  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    if (await _store.exists()) {
      try {
        final Object? decoded = jsonDecode(await _store.readAsString());
        for (final Object? raw in decoded! as List<Object?>) {
          final AudiobookTranscribeJob job = AudiobookTranscribeJob.fromJson(
            Map<String, Object?>.from(raw! as Map<Object?, Object?>),
          );
          if (job.status == AudiobookTranscribeJobStatus.running) {
            job
              ..status = AudiobookTranscribeJobStatus.queued
              ..phase = null
              ..progress = null;
          }
          _jobs.add(job);
        }
      } catch (e, stack) {
        // 清单坏了不能让整个 app 起不来；记日志，按空队列继续（文件留着不覆盖
        // 之前先挪开，便于事后取证）。
        engineLog.log('AudiobookTranscribeImportQueue.load', e, stack);
        await _store.rename('${_store.path}.corrupt');
      }
    }
    notifyListeners();
    _kick();
  }

  /// 排一个任务。同一组音频已有未结束的任务时直接返回那个，不重复排。
  Future<AudiobookTranscribeJob> enqueue({
    required List<String> audioPaths,
    String? contentPath,
    required String title,
  }) async {
    await load();
    for (final AudiobookTranscribeJob job in _jobs) {
      if (!job.isTerminal && _samePaths(job.audioPaths, audioPaths)) {
        return job;
      }
    }
    final int now = _now().millisecondsSinceEpoch;
    final AudiobookTranscribeJob job = AudiobookTranscribeJob(
      id: '$now-${_idSeq++}',
      title: title,
      audioPaths: List<String>.unmodifiable(audioPaths),
      contentPath: contentPath,
      createdAt: now,
      updatedAt: now,
    );
    _jobs.add(job);
    await _persist();
    notifyListeners();
    _kick();
    return job;
  }

  /// 取消：排队中的直接落 cancelled；正在跑的请求暂停，跑完当前检查点后落
  /// cancelled（转录进度保留在磁盘上，[retry] 会从断点接着来）。
  Future<void> cancel(String id) async {
    final AudiobookTranscribeJob? job = _find(id);
    if (job == null || job.isTerminal) return;
    if (_runningId == id) {
      _runningCancel?.cancel();
      return;
    }
    _finish(job, AudiobookTranscribeJobStatus.cancelled);
    await _persist();
    notifyListeners();
  }

  /// 失败/取消的任务重新排队。
  Future<void> retry(String id) async {
    final AudiobookTranscribeJob? job = _find(id);
    if (job == null ||
        (job.status != AudiobookTranscribeJobStatus.failed &&
            job.status != AudiobookTranscribeJobStatus.cancelled)) {
      return;
    }
    job
      ..status = AudiobookTranscribeJobStatus.queued
      ..phase = null
      ..progress = null
      ..error = null
      ..updatedAt = _now().millisecondsSinceEpoch;
    await _persist();
    notifyListeners();
    _kick();
  }

  /// 移除已结束的任务（只动清单，不删任何文件）。未结束的先 [cancel]。
  Future<void> remove(String id) async {
    final AudiobookTranscribeJob? job = _find(id);
    if (job == null || !job.isTerminal) return;
    _jobs.remove(job);
    await _persist();
    notifyListeners();
  }

  /// 停止处理（不改任务状态：正在跑的下次 [load] 回到 queued）。测试与进程
  /// 退出用。
  Future<void> close() async {
    _closed = true;
    _runningCancel?.cancel();
    await _drainFuture;
    await _persistChain;
  }

  void _kick() {
    if (_closed || _drainFuture != null) return;
    _drainFuture = _drain().whenComplete(() => _drainFuture = null);
  }

  Future<void> _drain() async {
    while (!_closed) {
      AudiobookTranscribeJob? next;
      for (final AudiobookTranscribeJob job in _jobs) {
        if (job.status == AudiobookTranscribeJobStatus.queued) {
          next = job;
          break;
        }
      }
      if (next == null) return;
      await _runOne(next);
    }
  }

  Future<void> _runOne(AudiobookTranscribeJob job) async {
    final AudiobookTranscribeCancelToken cancel =
        AudiobookTranscribeCancelToken();
    _runningCancel = cancel;
    _runningId = job.id;
    job
      ..status = AudiobookTranscribeJobStatus.running
      ..phase = AudiobookTranscribeJobPhase.preparing
      ..progress = null
      ..error = null
      ..updatedAt = _now().millisecondsSinceEpoch;
    await _persist();
    notifyListeners();
    try {
      final String subtitlePath = await _transcriber.transcribe(
        job,
        onProgress: (AudiobookTranscribeJobPhase phase, double? progress) {
          final bool phaseChanged = job.phase != phase;
          job
            ..phase = phase
            ..progress = progress;
          if (phaseChanged) unawaited(_persist());
          notifyListeners();
        },
        cancel: cancel,
      );
      if (cancel.isCancelled) throw const AudiobookTranscribeCancelled();
      job
        ..phase = AudiobookTranscribeJobPhase.importing
        ..progress = null;
      notifyListeners();
      job.resultKey = await _importer(job, subtitlePath);
      _finish(job, AudiobookTranscribeJobStatus.done);
    } on AudiobookTranscribeCancelled {
      // close() 触发的取消不是用户取消：保持 queued，下次启动接着跑。
      if (_closed) {
        job
          ..status = AudiobookTranscribeJobStatus.queued
          ..phase = null
          ..progress = null;
      } else {
        _finish(job, AudiobookTranscribeJobStatus.cancelled);
      }
    } catch (e, stack) {
      engineLog.log(
        'AudiobookTranscribeImportQueue.run(${job.title})',
        e,
        stack,
      );
      job.error = '$e';
      _finish(job, AudiobookTranscribeJobStatus.failed);
    } finally {
      _runningCancel = null;
      _runningId = null;
    }
    await _persist();
    notifyListeners();
  }

  void _finish(
    AudiobookTranscribeJob job,
    AudiobookTranscribeJobStatus status,
  ) {
    job
      ..status = status
      ..phase = null
      ..progress = null
      ..updatedAt = _now().millisecondsSinceEpoch;
  }

  AudiobookTranscribeJob? _find(String id) {
    for (final AudiobookTranscribeJob job in _jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  /// 串行化落盘：每次写全量快照，后一次总在前一次之后完成。
  ///
  /// 写失败（盘满、权限）记日志，不打断队列也不污染后续的写：内存里的状态
  /// 仍是对的，只是这一版没存下来，下一次状态变化会再写一次全量。
  Future<void> _persist() {
    final String snapshot = jsonEncode(<Map<String, Object?>>[
      for (final AudiobookTranscribeJob job in _jobs) job.toJson(),
    ]);
    return _persistChain = _persistChain.then((_) async {
      try {
        await _store.parent.create(recursive: true);
        final File tmp = File('${_store.path}.tmp');
        await tmp.writeAsString(snapshot, flush: true);
        await tmp.rename(_store.path);
      } catch (e, stack) {
        engineLog.log('AudiobookTranscribeImportQueue.persist', e, stack);
      }
    });
  }

  static bool _samePaths(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
