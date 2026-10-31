/// 「制作有声书」任务队列：整本（或选定章节）逐句合成 → 按章编码 → 可选语音识别
/// 校对 → 作为普通有声书入库。
///
/// 形态与 `AudiobookTranscribeImportQueue` 同构：
/// - 清单是一个 JSON 文件，原子写（`.tmp` → rename）；
/// - 单并发串行（合成占满 GPU / 在线配额，编码与识别也吃 CPU）；
/// - 进程退出时 running 的任务下次 [load] 回到 queued。逐句音频在 TTS 缓存里、
///   已编码的章在任务工作目录里，重跑会跳过已完成的部分；
/// - 真正的活由注入的 [TtsRenderRunner] 做，本类不 import 任何 EPUB / 数据库 /
///   ffmpeg 代码，测试用假端口即可覆盖全部编排；
/// - 任务工作目录（`<workRoot>/<job.id>/`，按章 m4a、混音中间文件）的生命周期
///   跟着清单条目走：条目被 [TtsRenderQueue.remove] 或被同一本书的新任务取代时
///   目录一起删，[TtsRenderQueue.load] 时清掉清单里已没有的孤儿目录。清单因此
///   每本书至多一条已结束任务，不再只增不减。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_notifier.dart';
import 'package:path/path.dart' as p;

/// 任务 [jobId] 的工作目录（制作流程与队列共用这一个口径）。
Directory ttsRenderJobWorkDir(Directory workRoot, String jobId) =>
    Directory(p.join(workRoot.path, jobId));

enum TtsRenderJobStatus { queued, running, done, failed, cancelled }

enum TtsRenderJobPhase {
  planning,
  synthesizing,
  encoding,
  verifying,
  importing,
}

/// 校对标出的一句（语音识别结果与原文差得远）。
class TtsRenderFlag {
  const TtsRenderFlag({
    required this.sentence,
    required this.similarity,
    required this.heard,
  });

  /// 计划里的句序（全书下标）。
  final int sentence;

  /// 0..1，归一化文本相似度。
  final double similarity;

  /// 语音识别听到的文本。
  final String heard;

  Map<String, Object?> toJson() => <String, Object?>{
    'i': sentence,
    's': similarity,
    'h': heard,
  };

  static TtsRenderFlag? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? i = raw['i'], s = raw['s'], h = raw['h'];
    if (i is! int || s is! num || h is! String) return null;
    return TtsRenderFlag(sentence: i, similarity: s.toDouble(), heard: h);
  }
}

class TtsRenderJob {
  TtsRenderJob({
    required this.id,
    required this.bookKey,
    required this.title,
    required this.presetId,
    required this.sections,
    required this.verify,
    required this.createdAt,
    required this.updatedAt,
    this.regenerate = const <int>[],
    this.pausePreset = 'standard',
    this.normalizeLoudness = true,
    this.status = TtsRenderJobStatus.queued,
    this.phase,
    this.done = 0,
    this.total = 0,
    this.error,
    this.flags = const <TtsRenderFlag>[],
    this.verified = false,
  });

  final String id;
  final String bookKey;
  final String title;

  /// 用哪份声音预设（运行时按 id 取，凭据不进任务清单）。
  final String presetId;

  /// 要制作的章节下标（EPUB spine）。空 = 全书。
  final List<int> sections;

  /// 制作完用语音识别校对。
  final bool verify;

  /// 开始前丢弃这些句子（全书句序）的缓存音频，强制重新合成。
  final List<int> regenerate;

  /// 停顿预设名（`TtsPausePreset.name`）。
  final String pausePreset;

  /// 编码时做响度归一化（ffmpeg 有 loudnorm 时；没有就如实记 [loudnessSkipped]）。
  final bool normalizeLoudness;

  /// 要求了响度归一化但本机 ffmpeg 不支持而跳过（UI 提示，不算失败）。
  bool loudnessSkipped = false;

  final int createdAt;
  int updatedAt;
  TtsRenderJobStatus status;
  TtsRenderJobPhase? phase;

  /// 当前阶段进度（句数 / 章数，按阶段而定）。
  int done;
  int total;

  /// 失败原因（稳定错误码或简短诊断，不含凭据 / 响应正文）。
  String? error;

  /// 校对结果：被标出的句子。
  List<TtsRenderFlag> flags;

  /// 校对确实跑过（模型不在 / 平台不支持时为 false，[flags] 为空不代表全对）。
  bool verified;

  bool get isTerminal =>
      status == TtsRenderJobStatus.done ||
      status == TtsRenderJobStatus.failed ||
      status == TtsRenderJobStatus.cancelled;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'bookKey': bookKey,
    'title': title,
    'presetId': presetId,
    'sections': sections,
    'verify': verify,
    'regenerate': regenerate,
    'pause': pausePreset,
    'loudnorm': normalizeLoudness,
    'loudnessSkipped': loudnessSkipped,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'status': status.name,
    'phase': phase?.name,
    'done': done,
    'total': total,
    'error': error,
    'flags': <Object?>[for (final TtsRenderFlag f in flags) f.toJson()],
    'verified': verified,
  };

  static TtsRenderJob fromJson(Map<String, Object?> json) {
    List<int> ints(Object? raw) => <int>[
      if (raw is List)
        for (final Object? v in raw)
          if (v is int) v,
    ];
    T byName<T extends Enum>(List<T> values, Object? raw, T fallback) {
      for (final T v in values) {
        if (v.name == raw) return v;
      }
      return fallback;
    }

    final Object? phase = json['phase'];
    final Object? flags = json['flags'];
    return TtsRenderJob(
      id: json['id']! as String,
      bookKey: json['bookKey']! as String,
      title: (json['title'] as String?) ?? '',
      presetId: (json['presetId'] as String?) ?? '',
      sections: ints(json['sections']),
      verify: json['verify'] == true,
      regenerate: ints(json['regenerate']),
      pausePreset: (json['pause'] as String?) ?? 'standard',
      normalizeLoudness: json['loudnorm'] != false,
      createdAt: (json['createdAt'] as int?) ?? 0,
      updatedAt: (json['updatedAt'] as int?) ?? 0,
      status: byName(
        TtsRenderJobStatus.values,
        json['status'],
        TtsRenderJobStatus.failed,
      ),
      phase: phase == null
          ? null
          : byName(TtsRenderJobPhase.values, phase, TtsRenderJobPhase.planning),
      done: (json['done'] as int?) ?? 0,
      total: (json['total'] as int?) ?? 0,
      error: json['error'] as String?,
      flags: <TtsRenderFlag>[
        if (flags is List)
          for (final Object? f in flags)
            if (TtsRenderFlag.fromJson(f) case final TtsRenderFlag flag) flag,
      ],
      verified: json['verified'] == true,
    )..loudnessSkipped = json['loudnessSkipped'] == true;
  }
}

class TtsRenderCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final void Function() l in List<void Function()>.of(_listeners)) {
      l();
    }
    _listeners.clear();
  }

  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void throwIfCancelled() {
    if (_cancelled) throw const TtsRenderCancelled();
  }
}

class TtsRenderCancelled implements Exception {
  const TtsRenderCancelled();
}

/// 失败原因（[code] 进清单，UI 按它出文案）。
class TtsRenderFailure implements Exception {
  const TtsRenderFailure(this.code, [this.detail]);
  final String code;
  final String? detail;

  @override
  String toString() => detail == null
      ? 'TtsRenderFailure($code)'
      : 'TtsRenderFailure($code: $detail)';
}

/// 进度回报：阶段 + 本阶段完成 / 总数。
typedef TtsRenderProgress =
    void Function(TtsRenderJobPhase phase, int done, int total);

/// 制作端口：跑完返回校对结果（没校对返回 null）。
abstract interface class TtsRenderRunner {
  Future<({bool verified, List<TtsRenderFlag> flags})> run(
    TtsRenderJob job, {
    required TtsRenderProgress onProgress,
    required TtsRenderCancelToken cancel,
  });
}

class TtsRenderQueue extends EngineChangeNotifier {
  TtsRenderQueue({
    required File store,
    required Directory workRoot,
    required TtsRenderRunner runner,
    DateTime Function()? now,
  }) : _store = store,
       _workRoot = workRoot,
       _runner = runner,
       _now = now ?? DateTime.now;

  final File _store;

  /// 各任务工作目录的根（每个任务一个 `<id>` 子目录）。
  final Directory _workRoot;
  final TtsRenderRunner _runner;
  final DateTime Function() _now;

  final List<TtsRenderJob> _jobs = <TtsRenderJob>[];
  TtsRenderCancelToken? _runningCancel;
  String? _runningId;
  Future<void>? _drainFuture;
  Future<void> _persistChain = Future<void>.value();
  Future<void>? _loadFuture;
  int _idSeq = 0;
  bool _closed = false;

  List<TtsRenderJob> get jobs => List<TtsRenderJob>.unmodifiable(_jobs);

  /// 这本书最近的一个任务（UI 展示用）。
  TtsRenderJob? latestFor(String bookKey) {
    for (final TtsRenderJob job in _jobs.reversed) {
      if (job.bookKey == bookKey) return job;
    }
    return null;
  }

  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    if (await _store.exists()) {
      try {
        final Object? decoded = jsonDecode(await _store.readAsString());
        for (final Object? raw in decoded! as List<Object?>) {
          final TtsRenderJob job = TtsRenderJob.fromJson(
            Map<String, Object?>.from(raw! as Map<Object?, Object?>),
          );
          if (job.status == TtsRenderJobStatus.running) {
            job
              ..status = TtsRenderJobStatus.queued
              ..phase = null;
          }
          _jobs.add(job);
        }
      } catch (e, stack) {
        engineLog.log('TtsRenderQueue.load', e, stack);
        await _store.rename('${_store.path}.corrupt');
      }
    }
    await _deleteOrphanWorkDirs();
    notifyListeners();
    _kick();
  }

  /// 工作根下名字不是清单里任务 id 的子目录（任务条目早已不在、清单损坏被挪走、
  /// 或旧版本留下的）没有任何人会再用，删掉。只在 [_load] 里跑：此时还没有任务
  /// 在运行，不会删到正在写的目录。
  Future<void> _deleteOrphanWorkDirs() async {
    if (!await _workRoot.exists()) return;
    final Set<String> ids = <String>{
      for (final TtsRenderJob job in _jobs) job.id,
    };
    // listSync：await for 遍历 list() 的完成事件在 widget 测试的 fake-async 里
    // 送不到，会把整页测试挂住；工作根只有每本书一层子目录，同步列举代价可忽略。
    try {
      for (final FileSystemEntity entity in _workRoot.listSync()) {
        if (entity is! Directory) continue;
        if (ids.contains(p.basename(entity.path))) continue;
        await _deleteWorkDir(entity);
      }
    } on FileSystemException catch (e, stack) {
      engineLog.log('TtsRenderQueue.orphanScan', e, stack);
    }
  }

  /// 删一个任务的工作目录。删不掉（Windows 上文件被占用）只记日志：条目已不在
  /// 清单里，下次 [load] 的孤儿扫描会再删一次，不会永久泄漏。
  Future<void> _deleteWorkDir(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException catch (e, stack) {
      engineLog.log('TtsRenderQueue.deleteWorkDir', e, stack);
    }
  }

  /// 排一个任务。同一本书已有未结束的任务时直接返回那个。
  ///
  /// 新任务取代这本书之前所有已结束的任务（失败 / 取消 / 完成）：它们的清单条目与
  /// 工作目录一起删掉——新任务换了 id 与目录，旧目录里的按章成品再也不会被读到。
  Future<TtsRenderJob> enqueue({
    required String bookKey,
    required String title,
    required String presetId,
    List<int> sections = const <int>[],
    bool verify = false,
    List<int> regenerate = const <int>[],
    String pausePreset = 'standard',
    bool normalizeLoudness = true,
  }) async {
    await load();
    for (final TtsRenderJob job in _jobs) {
      if (!job.isTerminal && job.bookKey == bookKey) return job;
    }
    final int now = _now().millisecondsSinceEpoch;
    final TtsRenderJob job = TtsRenderJob(
      id: '$now-${_idSeq++}',
      bookKey: bookKey,
      title: title,
      presetId: presetId,
      sections: List<int>.unmodifiable(sections),
      verify: verify,
      regenerate: List<int>.unmodifiable(regenerate),
      pausePreset: pausePreset,
      normalizeLoudness: normalizeLoudness,
      createdAt: now,
      updatedAt: now,
    );
    final List<TtsRenderJob> superseded = <TtsRenderJob>[
      for (final TtsRenderJob old in _jobs)
        if (old.bookKey == bookKey) old,
    ];
    _jobs
      ..removeWhere(superseded.contains)
      ..add(job);
    await _persist();
    notifyListeners();
    _kick();
    for (final TtsRenderJob old in superseded) {
      await _deleteWorkDir(ttsRenderJobWorkDir(_workRoot, old.id));
    }
    return job;
  }

  Future<void> cancel(String id) async {
    final TtsRenderJob? job = _find(id);
    if (job == null || job.isTerminal) return;
    if (_runningId == id) {
      _runningCancel?.cancel();
      return;
    }
    _finish(job, TtsRenderJobStatus.cancelled);
    await _persist();
    notifyListeners();
  }

  Future<void> retry(String id) async {
    final TtsRenderJob? job = _find(id);
    if (job == null ||
        (job.status != TtsRenderJobStatus.failed &&
            job.status != TtsRenderJobStatus.cancelled)) {
      return;
    }
    job
      ..status = TtsRenderJobStatus.queued
      ..phase = null
      ..error = null
      ..updatedAt = _now().millisecondsSinceEpoch;
    await _persist();
    notifyListeners();
    _kick();
  }

  Future<void> remove(String id) async {
    final TtsRenderJob? job = _find(id);
    if (job == null || !job.isTerminal) return;
    _jobs.remove(job);
    await _persist();
    notifyListeners();
    await _deleteWorkDir(ttsRenderJobWorkDir(_workRoot, job.id));
  }

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
      TtsRenderJob? next;
      for (final TtsRenderJob job in _jobs) {
        if (job.status == TtsRenderJobStatus.queued) {
          next = job;
          break;
        }
      }
      if (next == null) return;
      await _runOne(next);
    }
  }

  Future<void> _runOne(TtsRenderJob job) async {
    final TtsRenderCancelToken cancel = TtsRenderCancelToken();
    _runningCancel = cancel;
    _runningId = job.id;
    job
      ..status = TtsRenderJobStatus.running
      ..phase = TtsRenderJobPhase.planning
      ..done = 0
      ..total = 0
      ..error = null
      ..updatedAt = _now().millisecondsSinceEpoch;
    await _persist();
    notifyListeners();
    try {
      final ({bool verified, List<TtsRenderFlag> flags}) result = await _runner
          .run(
            job,
            onProgress: (TtsRenderJobPhase phase, int done, int total) {
              final bool phaseChanged = job.phase != phase;
              job
                ..phase = phase
                ..done = done
                ..total = total;
              if (phaseChanged) unawaited(_persist());
              notifyListeners();
            },
            cancel: cancel,
          );
      job
        ..verified = result.verified
        ..flags = result.flags;
      _finish(job, TtsRenderJobStatus.done);
    } on TtsRenderCancelled {
      if (_closed) {
        job
          ..status = TtsRenderJobStatus.queued
          ..phase = null;
      } else {
        _finish(job, TtsRenderJobStatus.cancelled);
      }
    } on TtsRenderFailure catch (e) {
      job.error = e.code;
      _finish(job, TtsRenderJobStatus.failed);
    } catch (e, stack) {
      engineLog.log('TtsRenderQueue.run(${job.bookKey})', e, stack);
      job.error = 'internal';
      _finish(job, TtsRenderJobStatus.failed);
    } finally {
      _runningCancel = null;
      _runningId = null;
    }
    await _persist();
    notifyListeners();
  }

  void _finish(TtsRenderJob job, TtsRenderJobStatus status) {
    job
      ..status = status
      ..phase = null
      ..updatedAt = _now().millisecondsSinceEpoch;
  }

  TtsRenderJob? _find(String id) {
    for (final TtsRenderJob job in _jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  Future<void> _persist() {
    final String snapshot = jsonEncode(<Map<String, Object?>>[
      for (final TtsRenderJob job in _jobs) job.toJson(),
    ]);
    return _persistChain = _persistChain.then((_) async {
      try {
        await _store.parent.create(recursive: true);
        final File tmp = File('${_store.path}.tmp');
        await tmp.writeAsString(snapshot, flush: true);
        await tmp.rename(_store.path);
      } catch (e, stack) {
        engineLog.log('TtsRenderQueue.persist', e, stack);
      }
    });
  }
}
