/// 通用 host 任务管理器：目录持久化 + 单并发串行队列 + TTL 清理。
///
/// 与远程 OCR 的 `MangaOcrHostJobManager` 同一形状（客户端已经会按这套状态机
/// 轮询），差异只有两点：任务类型经 [HostJobRunner] 注册表可插拔；记录落
/// `job.json`，进程重启后 `pending/uploading` 保留、`running` 降级为 `error`
/// （runner 的中间态没法续，客户端看到 error 会重投）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/host_jobs/host_job.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

class HostJobNotFound implements Exception {
  const HostJobNotFound(this.id);
  final String id;
}

class HostJobConflict implements Exception {
  const HostJobConflict(this.reason);
  final String reason;

  @override
  String toString() => 'HostJobConflict($reason)';
}

class HostJobManager {
  HostJobManager({
    required Directory jobRoot,
    required List<HostJobRunner> runners,
    DateTime Function()? now,
    Duration jobTtl = const Duration(hours: 24),
    Random? random,
  })  : _jobRoot = jobRoot,
        _runners = <String, HostJobRunner>{
          for (final HostJobRunner r in runners) r.kind: r,
        },
        _now = now ?? DateTime.now,
        _jobTtl = jobTtl,
        _random = random ?? Random.secure();

  final Directory _jobRoot;
  final Map<String, HostJobRunner> _runners;
  final DateTime Function() _now;
  final Duration _jobTtl;
  final Random _random;
  final Map<String, HostJobRecord> _jobs = <String, HostJobRecord>{};
  final Map<String, HostJobCancelToken> _cancels = <String, HostJobCancelToken>{};
  final List<String> _queue = <String>[];
  bool _draining = false;
  bool _loaded = false;

  Iterable<String> get kinds => _runners.keys;

  /// `/api/capabilities` 的 `jobs` 字段。
  Future<Map<String, Object?>> capability() async {
    final Map<String, Object?> perKind = <String, Object?>{};
    for (final HostJobRunner r in _runners.values) {
      try {
        perKind[r.kind] = await r.capability();
      } catch (e, stack) {
        engineLog.log('HostJobManager.capability(${r.kind})', e, stack);
        perKind[r.kind] = <String, Object?>{'error': '$e'};
      }
    }
    return <String, Object?>{
      'kinds': _runners.keys.toList(growable: false),
      ...perKind,
    };
  }

  Directory dirFor(String id) => Directory(p.join(_jobRoot.path, id));

  /// 进程启动时把磁盘上的记录读回来（running → error）。幂等。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (!await _jobRoot.exists()) {
      await _jobRoot.create(recursive: true);
      return;
    }
    // 必须是 listSync，不能是 `await for (… in _jobRoot.list())`。
    // 异步目录流的完成事件走真实事件循环，而 widget 测试在 fake-async 里推进
    // 时钟——那个事件永远送不到，`load()` 的 future 因此永不 resolve。本类被 app
    // 侧 `FushiSyncServer` 消费，任何驱动到 `/api/jobs` 的 widget 测试都会挂在
    // `pumpAndSettle` 上（同 video_book_repository.dart 里那处的成因）。
    // 循环体内的 await 不受影响：那是普通 future，不依赖目录流的完成事件。
    for (final FileSystemEntity e in _jobRoot.listSync()) {
      if (e is! Directory) continue;
      final File f = File(p.join(e.path, 'job.json'));
      if (!await f.exists()) continue;
      try {
        final HostJobRecord rec = HostJobRecord.fromJson(
          Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map),
        );
        if (rec.state == HostJobState.running) {
          rec
            ..state = HostJobState.error
            ..error = 'host restarted while running';
          await _persist(rec);
        }
        _jobs[rec.id] = rec;
      } catch (err, stack) {
        engineLog.log('HostJobManager.load(${e.path})', err, stack);
      }
    }
    await pruneExpired();
  }

  Future<HostJobRecord> create(String kind, Map<String, Object?> params) async {
    await load();
    final HostJobRunner? runner = _runners[kind];
    if (runner == null) throw FormatException('unknown job kind: $kind');
    runner.validateParams(params);
    final DateTime now = _now();
    final HostJobRecord rec = HostJobRecord(
      id: _newId(),
      kind: kind,
      params: params,
      createdAt: now,
      updatedAt: now,
    );
    await Directory(p.join(dirFor(rec.id).path, 'inputs')).create(recursive: true);
    await Directory(p.join(dirFor(rec.id).path, 'outputs')).create(recursive: true);
    _jobs[rec.id] = rec;
    await _persist(rec);
    return rec;
  }

  HostJobRecord get(String id) {
    final HostJobRecord? rec = _jobs[id];
    if (rec == null) throw HostJobNotFound(id);
    return rec;
  }

  List<HostJobRecord> list() => _jobs.values.toList(growable: false)
    ..sort((HostJobRecord a, HostJobRecord b) => b.createdAt.compareTo(a.createdAt));

  /// 写入一个输入文件（流式落盘；名字经 [safeName] 过滤）。
  Future<void> putInput(String id, String name, Stream<List<int>> body) async {
    final HostJobRecord rec = get(id);
    if (rec.state != HostJobState.pending && rec.state != HostJobState.uploading) {
      throw HostJobConflict('job ${rec.state.name}, inputs are sealed');
    }
    final String safe = safeName(name);
    final File target = File(p.join(dirFor(id).path, 'inputs', safe));
    final IOSink sink = target.openWrite();
    try {
      await sink.addStream(body);
    } finally {
      await sink.close();
    }
    if (!rec.inputs.contains(safe)) rec.inputs.add(safe);
    rec
      ..state = HostJobState.uploading
      ..updatedAt = _now();
    await _persist(rec);
  }

  Future<void> start(String id) async {
    final HostJobRecord rec = get(id);
    if (rec.state != HostJobState.pending && rec.state != HostJobState.uploading) {
      throw HostJobConflict('job already ${rec.state.name}');
    }
    rec
      ..state = HostJobState.running
      ..progress = 0
      ..updatedAt = _now();
    await _persist(rec);
    _cancels[id] = HostJobCancelToken();
    _queue.add(id);
    unawaited(_drain());
  }

  Future<void> cancel(String id) async {
    final HostJobRecord rec = get(id);
    _cancels[id]?.cancel();
    _queue.remove(id);
    if (!rec.isTerminal) {
      rec
        ..state = HostJobState.cancelled
        ..updatedAt = _now();
      await _persist(rec);
    }
  }

  /// 取消 + 删目录。
  Future<void> delete(String id) async {
    await cancel(id);
    _jobs.remove(id);
    _cancels.remove(id);
    final Directory dir = dirFor(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// 产物文件；[name] 为空取 primaryOutput。
  File? result(String id, [String? name]) {
    final HostJobRecord rec = get(id);
    final String? key = name ?? rec.primaryOutput;
    if (key == null) return null;
    final String? file = rec.outputs[key];
    if (file == null) return null;
    return File(p.join(dirFor(id).path, 'outputs', file));
  }

  String contentTypeFor(String id, String name) =>
      _runners[get(id).kind]?.contentTypeFor(name) ?? 'application/octet-stream';

  Future<void> pruneExpired() async {
    final DateTime cutoff = _now().subtract(_jobTtl);
    for (final HostJobRecord rec in list()) {
      if (rec.isTerminal && rec.updatedAt.isBefore(cutoff)) {
        await delete(rec.id);
      }
    }
  }

  Future<void> disposeAll() async {
    for (final HostJobCancelToken t in _cancels.values) {
      t.cancel();
    }
    _queue.clear();
  }

  // ── 内部 ─────────────────────────────────────────────────────────────

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final String id = _queue.removeAt(0);
        final HostJobRecord? rec = _jobs[id];
        if (rec == null || rec.state != HostJobState.running) continue;
        await _runOne(rec);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _runOne(HostJobRecord rec) async {
    final HostJobRunner runner = _runners[rec.kind]!;
    final HostJobCancelToken cancel = _cancels[rec.id] ?? HostJobCancelToken();
    final Directory dir = dirFor(rec.id);
    try {
      final HostJobOutcome outcome = await runner.run(HostJobContext(
        jobId: rec.id,
        params: rec.params,
        inputsDir: Directory(p.join(dir.path, 'inputs')),
        outputsDir: Directory(p.join(dir.path, 'outputs')),
        onProgress: (double progress, String? message) {
          rec
            ..progress = progress.clamp(0, 1).toDouble()
            ..message = message
            ..updatedAt = _now();
        },
        cancel: cancel,
      ));
      if (cancel.isCancelled) {
        rec.state = HostJobState.cancelled;
      } else {
        rec
          ..state = HostJobState.done
          ..progress = 1
          ..message = outcome.message
          ..primaryOutput = outcome.primaryOutput;
        rec.outputs
          ..clear()
          ..addAll(outcome.outputs);
      }
    } on HostJobCancelledException {
      rec.state = HostJobState.cancelled;
    } catch (e, stack) {
      engineLog.log('HostJobManager.run(${rec.kind}/${rec.id})', e, stack);
      if (cancel.isCancelled) {
        rec.state = HostJobState.cancelled;
      } else {
        rec
          ..state = HostJobState.error
          ..error = '$e';
      }
    } finally {
      rec.updatedAt = _now();
      _cancels.remove(rec.id);
      await _persist(rec);
    }
  }

  Future<void> _persist(HostJobRecord rec) async {
    final File f = File(p.join(dirFor(rec.id).path, 'job.json'));
    await f.parent.create(recursive: true);
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(rec.encode(), flush: true);
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
  }

  String _newId() {
    const String alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List<String>.generate(
      24,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
  }

  /// 输入名只允许一段文件名：去路径、去 `..`、空则给默认名。
  @visibleForTesting
  static String safeName(String raw) {
    final String base = p.basename(raw.replaceAll('\\', '/')).trim();
    final String cleaned = base.replaceAll(RegExp(r'[^\w.\-() ]'), '_');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'input';
    return cleaned;
  }
}
