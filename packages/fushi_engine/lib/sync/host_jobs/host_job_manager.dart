/// 通用 host 任务管理器：目录持久化 + 单并发串行队列 + TTL 清理。
///
/// 与远程 OCR 的 `MangaOcrHostJobManager` 同一形状（客户端已经会按这套状态机
/// 轮询），差异只有两点：任务类型经 [HostJobRunner] 注册表可插拔；记录落
/// `job.json`，进程重启后 `pending/uploading` 保留、`running` 降级为 `error`
/// （runner 的中间态没法续）。客户端看到 error 即报失败并 DELETE，不自动重投。
///
/// 过期回收：每次 API 触达经 [HostJobManager.housekeep]（节流到 `pruneInterval`
/// 一次）按 `updatedAt` 删掉超过 `jobTtl` 的非 running 记录——终态与被遗弃的
/// `pending/uploading` 都算；running 不按 TTL 清，它自己会走到终态。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/host_jobs/host_input_matcher.dart';
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

/// host 本地输入内容变了；`toString` 即 wire 上的 error（[kHostInputChangedError] 前缀）。
class _HostInputChanged implements Exception {
  const _HostInputChanged(this.names);
  final List<String> names;

  @override
  String toString() => '$kHostInputChangedError: ${names.join(', ')}';
}

class HostJobManager {
  HostJobManager({
    required Directory jobRoot,
    required List<HostJobRunner> runners,
    DateTime Function()? now,
    Duration jobTtl = const Duration(hours: 24),
    Duration pruneInterval = const Duration(minutes: 10),
    Random? random,
    HostInputMatcher? inputMatcher,
  }) : _jobRoot = jobRoot,
       _inputMatcher = inputMatcher,
       _runners = <String, HostJobRunner>{
         for (final HostJobRunner r in runners) r.kind: r,
       },
       _now = now ?? DateTime.now,
       _jobTtl = jobTtl,
       _pruneInterval = pruneInterval,
       _random = random ?? Random.secure();

  final Directory _jobRoot;

  /// 「host 本地已有同内容文件就不必上传」；null = 不提供（能力位不宣告 inputMatch）。
  final HostInputMatcher? _inputMatcher;
  final Map<String, HostJobRunner> _runners;
  final DateTime Function() _now;
  final Duration _jobTtl;
  final Duration _pruneInterval;
  final Random _random;
  final Map<String, HostJobRecord> _jobs = <String, HostJobRecord>{};
  final Map<String, HostJobCancelToken> _cancels =
      <String, HostJobCancelToken>{};
  final List<String> _queue = <String>[];
  bool _draining = false;

  /// 每个 job 在飞的落盘链尾（[_persist]）。同一条记录的落盘必须串行：它们共用
  /// 同一个 `job.json.tmp`，并发时（[cancel] 的落盘撞上 `_runOne` 收尾的落盘）后
  /// rename 的那次抛 PathNotFound（BUG-4462）。[delete] 也靠它等在飞的落盘结束
  /// 再删目录：`rec.state` 在落盘开始前就已可被轮询方看到，看到 done 立刻 DELETE
  /// 会把目录连同 `job.json.tmp` 一起删掉（CI 慢盘上稳定复现）。
  final Map<String, Future<void>> _persisting = <String, Future<void>>{};

  /// 读盘只做一次；并发的首批调用方都等同一个 future，不会在表还没读完时放行。
  Future<void>? _loading;
  DateTime? _lastPruneAt;

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
      if (_inputMatcher != null) 'inputMatch': kHostInputMatchAlgorithm,
      ...perKind,
    };
  }

  Directory dirFor(String id) => Directory(p.join(_jobRoot.path, id));

  /// 进程启动时把磁盘上的记录读回来（running → error）。幂等，并发调用共享同一次读盘。
  Future<void> load() => _loading ??= _loadOnce();

  /// 每次 API 触达时调用：先等读盘完成，再（节流到 `pruneInterval` 一次）回收过期记录。
  Future<void> housekeep() async {
    await load();
    final DateTime now = _now();
    final DateTime? last = _lastPruneAt;
    if (last != null && now.difference(last) < _pruneInterval) return;
    _lastPruneAt = now;
    await pruneExpired();
  }

  Future<void> _loadOnce() async {
    if (!await _jobRoot.exists()) {
      await _jobRoot.create(recursive: true);
      _lastPruneAt = _now();
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
        // 先登记再落盘：落盘只写表里的记录（[_writeRecord]）。
        _jobs[rec.id] = rec;
        if (rec.state == HostJobState.running) {
          rec
            ..state = HostJobState.error
            ..error = 'host restarted while running';
          await _persist(rec);
        }
      } catch (err, stack) {
        engineLog.log('HostJobManager.load(${e.path})', err, stack);
      }
    }
    _lastPruneAt = _now();
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
    await Directory(
      p.join(dirFor(rec.id).path, 'inputs'),
    ).create(recursive: true);
    await Directory(
      p.join(dirFor(rec.id).path, 'outputs'),
    ).create(recursive: true);
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
    ..sort(
      (HostJobRecord a, HostJobRecord b) => b.createdAt.compareTo(a.createdAt),
    );

  /// 写入一个输入文件（流式落盘；名字经 [safeName] 过滤）。
  Future<void> putInput(String id, String name, Stream<List<int>> body) async {
    final HostJobRecord rec = get(id);
    if (rec.state != HostJobState.pending &&
        rec.state != HostJobState.uploading) {
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
    // 上传优先：同名之前按哈希命中过 host 文件，以这次上传的为准。
    rec.hostInputs.remove(safe);
    rec
      ..state = HostJobState.uploading
      ..updatedAt = _now();
    await _persist(rec);
  }

  /// 按内容哈希找 host 本地已有的输入（`POST /api/jobs/<id>/inputs/match`）。命中
  /// 的名字记进 [HostJobRecord.hostInputs]，客户端就不必上传它们。返回本次清单里
  /// **至今**已命中的全部名字（多次询问累计），以及 host 是否还在后台给候选算哈希
  /// （`pending`：客户端稍后再问）。已经上传过的名字不再匹配。host 没配
  /// [HostInputMatcher] 时恒返回空。
  Future<({List<String> matched, bool pending})> matchInputs(
    String id,
    List<HostInputWanted> wanted,
  ) async {
    HostJobRecord rec = get(id);
    _ensureInputsOpen(rec);
    final HostInputMatcher? matcher = _inputMatcher;
    if (matcher == null) return (matched: const <String>[], pending: false);
    final List<HostInputWanted> asked = <HostInputWanted>[
      for (final HostInputWanted w in wanted)
        HostInputWanted(
          name: hostJobInputName(w.name),
          sha256: w.sha256,
          size: w.size,
        ),
    ];
    final List<HostInputWanted> pending = <HostInputWanted>[
      for (final HostInputWanted w in asked)
        if (!rec.inputs.contains(w.name) && !rec.hostInputs.containsKey(w.name))
          w,
    ];
    final HostInputMatchResult result = await matcher.match(pending);
    // 匹配期间任务可能已被删 / 开跑，同名输入也可能已经传上来了（客户端等不及这次
    // 应答、按「没命中」上传了）——上传优先，不能再把它记成 host 本地文件。
    rec = get(id);
    _ensureInputsOpen(rec);
    final Map<String, HostInputRef> fresh = <String, HostInputRef>{
      for (final MapEntry<String, HostInputRef> e in result.matched.entries)
        if (!rec.inputs.contains(e.key)) e.key: e.value,
    };
    if (fresh.isNotEmpty) {
      rec.hostInputs.addAll(fresh);
      rec.updatedAt = _now();
      await _persist(rec);
    }
    return (
      matched: <String>[
        for (final HostInputWanted w in asked)
          if (rec.hostInputs.containsKey(w.name)) w.name,
      ],
      pending: result.pending,
    );
  }

  void _ensureInputsOpen(HostJobRecord rec) {
    if (rec.state != HostJobState.pending &&
        rec.state != HostJobState.uploading) {
      throw HostJobConflict('job ${rec.state.name}, inputs are sealed');
    }
  }

  Future<void> start(String id) async {
    final HostJobRecord rec = get(id);
    if (rec.state != HostJobState.pending &&
        rec.state != HostJobState.uploading) {
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
    // 等这条记录在飞的落盘全部结束（等的时候可能又排进一笔），随后**同步**摘掉
    // 记录：runner 还没停下的话，它收尾的那笔落盘见不到记录就不写（[_writeRecord]），
    // 不会把下面删掉的目录又建出来。
    for (
      Future<void>? persisting = _persisting[id];
      persisting != null;
      persisting = _persisting[id]
    ) {
      await persisting.then<void>((_) {}, onError: (Object _) {});
    }
    _jobs.remove(id);
    _cancels.remove(id);
    final Directory dir = dirFor(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// 所有在飞的终态落盘都完成。测试在观察到终态之后、清理作业根目录之前等它；
  /// 生产里 [delete] 已按 job 逐个等。
  Future<void> whenIdle() => Future.wait<void>(<Future<void>>[
    for (final Future<void> f in _persisting.values)
      f.then<void>((_) {}, onError: (Object _) {}),
  ]);

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
      _runners[get(id).kind]?.contentTypeFor(name) ??
      'application/octet-stream';

  /// 删掉 `updatedAt` 早于 TTL 的非 running 记录（终态 + 被遗弃的 pending/uploading）。
  Future<void> pruneExpired() async {
    final DateTime cutoff = _now().subtract(_jobTtl);
    for (final HostJobRecord rec in list()) {
      if (rec.state != HostJobState.running && rec.updatedAt.isBefore(cutoff)) {
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
      // host 本地输入：排队期间可能被改 / 删，开跑前按缓存核对一次（stat 变了就重算）。
      final List<String> changedBefore = await _changedHostInputs(
        rec,
        force: false,
      );
      if (changedBefore.isNotEmpty) {
        throw _HostInputChanged(changedBefore);
      }
      final HostJobOutcome outcome = await runner.run(
        HostJobContext(
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
          hostInputs: <String, String>{
            for (final MapEntry<String, HostInputRef> e
                in rec.hostInputs.entries)
              e.key: e.value.path,
          },
        ),
      );
      // 跑完整份重读核对：转录途中被改过，产物就是拿错内容算的，不能交出去。
      if (!cancel.isCancelled) {
        final List<String> changedAfter = await _changedHostInputs(
          rec,
          force: true,
        );
        if (changedAfter.isNotEmpty) throw _HostInputChanged(changedAfter);
      }
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
    } on _HostInputChanged catch (e) {
      rec
        ..state = cancel.isCancelled
            ? HostJobState.cancelled
            : HostJobState.error
        ..error = '$e';
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
      // 与上面的状态赋值同一个微任务里排进 [_persisting]：观察到终态的一方一定能
      // 在那里等到这笔落盘。
      await _persist(rec);
    }
  }

  /// 把 [rec] 此刻的状态落盘。同一条记录的落盘排成一条链、逐笔执行（见
  /// [_persisting]）；调用即登记，不等到第一个 await 之后。
  Future<void> _persist(HostJobRecord rec) {
    final Future<void>? previous = _persisting[rec.id];
    late final Future<void> mine;
    mine = () async {
      // 前一笔的失败归它自己的调用方，这里只排队。
      await previous?.then<void>((_) {}, onError: (Object _) {});
      try {
        await _writeRecord(rec);
      } finally {
        if (identical(_persisting[rec.id], mine)) _persisting.remove(rec.id);
      }
    }();
    _persisting[rec.id] = mine;
    return mine;
  }

  Future<void> _writeRecord(HostJobRecord rec) async {
    // 已被 [delete] 摘掉的记录不再落盘（它的目录已删 / 正在删）。
    if (!identical(_jobs[rec.id], rec)) return;
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
  static String safeName(String raw) => hostJobInputName(raw);

  /// host 本地输入现在还是不是匹配时那份内容；返回变了（或没法核对）的名字。
  Future<List<String>> _changedHostInputs(
    HostJobRecord rec, {
    required bool force,
  }) async {
    final HostInputMatcher? matcher = _inputMatcher;
    final List<String> changed = <String>[];
    for (final MapEntry<String, HostInputRef> e in rec.hostInputs.entries) {
      if (matcher == null ||
          !await matcher.stillMatches(e.value, force: force)) {
        changed.add(e.key);
      }
    }
    return changed;
  }
}
