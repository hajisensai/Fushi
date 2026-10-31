import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'fushi_rwkv_library.dart';
import 'rwkv_native.dart';
import 'rwkv_rows.dart';

/// 常驻后台 isolate，独占一个 [RwkvNativeRuntime]。
///
/// 全量回放要几秒到几十秒、大模型一次排程查询几十毫秒，都不能放 UI isolate；runtime 又不是
/// 线程安全的，所以它只活在这个 isolate 里，主 isolate 只发粗粒度命令（整块行数据走
/// [TransferableTypedData]，不复制）。命令按到达顺序串行执行。
class RwkvWorker {
  RwkvWorker._(
    this._isolate,
    this._commands,
    this._responses,
    this.kind,
    this.precision,
  ) {
    _subscription = _responses.listen(_onResponse);
  }

  /// 启动 worker，加载 [libraryPath]（null = 默认定位规则）与 [modelPath] 的权重，建 runtime。
  /// 加载失败抛 [FushiRwkvUnavailableError] / [RwkvNativeException] / [FileSystemException]。
  static Future<RwkvWorker> spawn({
    required String modelPath,
    RwkvPrecision precision = RwkvPrecision.recommended,
    int threads = 0,
    String? libraryPath,
  }) async {
    final ReceivePort responses = ReceivePort('fushi-rwkv');
    final Isolate isolate = await Isolate.spawn<_Boot>(
      _main,
      _Boot(
        responses.sendPort,
        libraryPath,
        modelPath,
        precision.code,
        threads,
      ),
      debugName: 'fushi-rwkv',
      errorsAreFatal: false,
    );
    final StreamIterator<Object?> first = StreamIterator<Object?>(responses);
    await first.moveNext();
    final Object? hello = first.current;
    if (hello is _Failure) {
      responses.close();
      isolate.kill(priority: Isolate.immediate);
      throw hello.rebuild();
    }
    final _Ready ready = hello! as _Ready;
    final StreamController<Object?> rest = StreamController<Object?>();
    unawaited(() async {
      while (await first.moveNext()) {
        rest.add(first.current);
      }
      await rest.close();
    }());
    return RwkvWorker._(
      isolate,
      ready.commands,
      rest.stream,
      RwkvModelKind.values[ready.kind],
      RwkvPrecision.values[ready.precision],
    );
  }

  final Isolate _isolate;
  final SendPort _commands;
  final Stream<Object?> _responses;
  late final StreamSubscription<Object?> _subscription;
  final RwkvModelKind kind;
  final RwkvPrecision precision;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _next = 0;
  bool _closed = false;

  void _onResponse(Object? message) {
    final _Reply reply = message! as _Reply;
    final Completer<Object?>? completer = _pending.remove(reply.id);
    if (completer == null) return;
    final Object? value = reply.value;
    if (value is _Failure) {
      completer.completeError(value.rebuild());
    } else {
      completer.complete(value);
    }
  }

  Future<T> _call<T>(_Op op, [Object? argument]) {
    if (_closed) return Future<T>.error(StateError('RWKV worker closed'));
    final int id = _next++;
    final Completer<Object?> completer = Completer<Object?>();
    _pending[id] = completer;
    _commands.send(_Command(id, op, argument));
    return completer.future.then((Object? value) => value as T);
  }

  /// 追加回放；[predictions] 为 true 时返回每行作答前的 R。
  Future<Float32List?> replay(RwkvRows rows, {bool predictions = false}) async {
    final TransferableTypedData? out = await _call<TransferableTypedData?>(
      _Op.replay,
      (TransferableTypedData.fromList(<Uint8List>[rows.bytes]), predictions),
    );
    return out?.materialize().asFloat32List();
  }

  Future<Float32List> query(RwkvRows rows) async {
    final TransferableTypedData out = await _call<TransferableTypedData>(
      _Op.query,
      TransferableTypedData.fromList(<Uint8List>[rows.bytes]),
    );
    return out.materialize().asFloat32List();
  }

  /// 追加并记撤销日志（[RwkvNativeRuntime.append]）。返回 false = 模型不支持撤销日志（大模型），
  /// 这时行**已按普通回放追加**（状态照样是最新的，只是不能 [unappend]）。
  Future<bool> append(RwkvRows rows, List<int> tags) =>
      _call<bool>(_Op.append, (
        TransferableTypedData.fromList(<Uint8List>[rows.bytes]),
        Uint64List.fromList(tags),
      ));

  /// 撤回最近一条 [append]（仅当标签是 [tag]）。
  Future<bool> unappend(int tag) => _call<bool>(_Op.unappend, tag);

  Future<void> clearScores() => _call<void>(_Op.clearScores);

  Future<RwkvScoreLookup> lookupScores(
    Int64List cardIds,
    Uint64List versions,
  ) async {
    final (TransferableTypedData, TransferableTypedData) out =
        await _call<(TransferableTypedData, TransferableTypedData)>(
          _Op.lookupScores,
          (
            TransferableTypedData.fromList(<Uint8List>[
              cardIds.buffer.asUint8List(
                cardIds.offsetInBytes,
                cardIds.lengthInBytes,
              ),
            ]),
            TransferableTypedData.fromList(<Uint8List>[
              versions.buffer.asUint8List(
                versions.offsetInBytes,
                versions.lengthInBytes,
              ),
            ]),
          ),
        );
    return RwkvScoreLookup(
      out.$1.materialize().asFloat32List(),
      out.$2.materialize().asUint8List(),
    );
  }

  Future<Float32List> updateScores(
    RwkvRows rows,
    Uint64List versions,
    Int64List anchorsMs,
  ) async {
    final TransferableTypedData out =
        await _call<TransferableTypedData>(_Op.updateScores, (
          TransferableTypedData.fromList(<Uint8List>[rows.bytes]),
          Uint64List.fromList(versions),
          Int64List.fromList(anchorsMs),
        ));
    return out.materialize().asFloat32List();
  }

  /// [RwkvNativeRuntime.requeryScores]。
  Future<int> requeryScores(int today, int nowMs) =>
      _call<int>(_Op.requeryScores, (today, nowMs));

  /// [RwkvNativeRuntime.removeScores]。
  Future<int> removeScores(Int64List cardIds) =>
      _call<int>(_Op.removeScores, Int64List.fromList(cardIds));

  Future<RwkvIntervals> nextIntervals(
    RwkvRows answer, {
    required double targetRetention,
    required int maxIntervalDays,
  }) async {
    final (List<int>, List<double>) out =
        await _call<(List<int>, List<double>)>(_Op.nextIntervals, (
          Uint8List.fromList(answer.bytes),
          targetRetention,
          maxIntervalDays,
        ));
    return RwkvIntervals(out.$1, out.$2);
  }

  Future<Uint8List> snapshot() async => (await _call<TransferableTypedData>(
    _Op.snapshot,
  )).materialize().asUint8List();

  Future<void> restore(Uint8List snapshot) => _call<void>(
    _Op.restore,
    TransferableTypedData.fromList(<Uint8List>[snapshot]),
  );

  /// 后台原生流式保存快照，跨 isolate 只传文件路径。
  Future<void> snapshotToFile(String path) =>
      _call<void>(_Op.snapshotToFile, path);

  /// 后台原生流式恢复快照；失败时保留原状态。
  Future<void> restoreFromFile(String path) =>
      _call<void>(_Op.restoreFromFile, path);

  Future<void> reset() => _call<void>(_Op.reset);

  Future<RwkvStats> stats() async {
    final List<int> s = await _call<List<int>>(_Op.stats);
    return RwkvStats(
      reviews: s[0],
      cards: s[1],
      notes: s[2],
      decks: s[3],
      presets: s[4],
      cardStateBytes: s[5],
      noteStateBytes: s[6],
      sharedStateBytes: s[7],
      featureStateBytes: s[8],
    );
  }

  /// 释放 runtime 并结束 isolate；挂起的调用以 [StateError] 结束。
  Future<void> close() async {
    if (_closed) return;
    try {
      await _call<void>(_Op.close);
    } finally {
      _closed = true;
      await _subscription.cancel();
      _isolate.kill(priority: Isolate.immediate);
      for (final Completer<Object?> completer in _pending.values) {
        completer.completeError(StateError('RWKV worker closed'));
      }
      _pending.clear();
    }
  }
}

enum _Op {
  replay,
  query,
  append,
  unappend,
  clearScores,
  lookupScores,
  updateScores,
  requeryScores,
  removeScores,
  nextIntervals,
  snapshot,
  restore,
  snapshotToFile,
  restoreFromFile,
  reset,
  stats,
  close,
}

class _Boot {
  const _Boot(
    this.reply,
    this.libraryPath,
    this.modelPath,
    this.precision,
    this.threads,
  );
  final SendPort reply;
  final String? libraryPath;
  final String modelPath;
  final int precision;
  final int threads;
}

class _Ready {
  const _Ready(this.commands, this.kind, this.precision);
  final SendPort commands;
  final int kind;
  final int precision;
}

class _Command {
  const _Command(this.id, this.op, this.argument);
  final int id;
  final _Op op;
  final Object? argument;
}

class _Reply {
  const _Reply(this.id, this.value);
  final int id;
  final Object? value;
}

/// 跨 isolate 传回的错误（异常对象本身不一定能发送）。
class _Failure {
  const _Failure(this.kind, this.code, this.message);

  factory _Failure.of(Object error) => switch (error) {
    RwkvNativeException(:final int code, :final String message) => _Failure(
      0,
      code,
      message,
    ),
    FushiRwkvUnavailableError() => _Failure(1, 0, error.toString()),
    FileSystemException() => _Failure(2, 0, error.toString()),
    _ => _Failure(3, 0, error.toString()),
  };

  final int kind;
  final int code;
  final String message;

  Object rebuild() => switch (kind) {
    0 => RwkvNativeException(code, message),
    1 => FushiRwkvUnavailableError(message),
    2 => FileSystemException(message),
    _ => StateError(message),
  };
}

Future<void> _main(_Boot boot) async {
  final RwkvNativeRuntime runtime;
  try {
    final FushiRwkv library = boot.libraryPath == null
        ? FushiRwkv.instance
        : FushiRwkv.load(libraryPath: boot.libraryPath);
    final RwkvNativeModel model = RwkvNativeModel.load(
      File(boot.modelPath).readAsBytesSync(),
      library: library,
    );
    runtime = RwkvNativeRuntime.create(
      model,
      precision: RwkvPrecision.values.firstWhere(
        (RwkvPrecision p) => p.code == boot.precision,
      ),
      threads: boot.threads,
    );
  } catch (error) {
    boot.reply.send(_Failure.of(error));
    return;
  }
  final ReceivePort commands = ReceivePort();
  boot.reply.send(
    _Ready(commands.sendPort, runtime.kind.index, runtime.precision.index),
  );
  await for (final Object? message in commands) {
    final _Command command = message! as _Command;
    Object? value;
    try {
      value = _run(runtime, command);
    } catch (error) {
      value = _Failure.of(error);
    }
    boot.reply.send(_Reply(command.id, value));
    if (command.op == _Op.close) {
      commands.close();
    }
  }
}

Object? _run(RwkvNativeRuntime runtime, _Command command) {
  RwkvRows rowsOf(Object? argument) => RwkvRows.fromBytes(
    (argument! as TransferableTypedData).materialize().asUint8List(),
  );
  switch (command.op) {
    case _Op.replay:
      final (TransferableTypedData rows, bool predictions) =
          command.argument! as (TransferableTypedData, bool);
      final Float32List? out = runtime.replay(
        rowsOf(rows),
        predictions: predictions,
      );
      return out == null
          ? null
          : TransferableTypedData.fromList(<Uint8List>[
              out.buffer.asUint8List(),
            ]);
    case _Op.query:
      final Float32List out = runtime.query(rowsOf(command.argument));
      return TransferableTypedData.fromList(<Uint8List>[
        out.buffer.asUint8List(),
      ]);
    case _Op.append:
      final (TransferableTypedData rows, Uint64List tags) =
          command.argument! as (TransferableTypedData, Uint64List);
      final RwkvRows batch = rowsOf(rows);
      try {
        runtime.append(batch, tags);
        return true;
      } on RwkvNativeException catch (error) {
        if (!error.isUnsupported) rethrow;
        runtime.replay(batch);
        return false;
      }
    case _Op.unappend:
      return runtime.unappend(command.argument! as int);
    case _Op.clearScores:
      runtime.clearScores();
      return null;
    case _Op.lookupScores:
      final (TransferableTypedData ids, TransferableTypedData versions) =
          command.argument! as (TransferableTypedData, TransferableTypedData);
      final RwkvScoreLookup out = runtime.lookupScores(
        ids.materialize().asInt64List(),
        versions.materialize().asUint64List(),
      );
      return (
        TransferableTypedData.fromList(<Uint8List>[
          out.scores.buffer.asUint8List(),
        ]),
        TransferableTypedData.fromList(<Uint8List>[out.found]),
      );
    case _Op.updateScores:
      final (
        TransferableTypedData rows,
        Uint64List versions,
        Int64List anchors,
      ) = command.argument! as (TransferableTypedData, Uint64List, Int64List);
      final Float32List out = runtime.updateScores(
        rowsOf(rows),
        versions,
        anchors,
      );
      return TransferableTypedData.fromList(<Uint8List>[
        out.buffer.asUint8List(),
      ]);
    case _Op.requeryScores:
      final (int today, int nowMs) = command.argument! as (int, int);
      return runtime.requeryScores(today, nowMs);
    case _Op.removeScores:
      return runtime.removeScores(command.argument! as Int64List);
    case _Op.nextIntervals:
      final (Uint8List row, double target, int max) =
          command.argument! as (Uint8List, double, int);
      final RwkvIntervals out = runtime.nextIntervals(
        RwkvRows.fromBytes(row),
        targetRetention: target,
        maxIntervalDays: max,
      );
      return (out.days, out.retrievability);
    case _Op.snapshot:
      return TransferableTypedData.fromList(<Uint8List>[runtime.snapshot()]);
    case _Op.restore:
      runtime.restore(
        (command.argument! as TransferableTypedData)
            .materialize()
            .asUint8List(),
      );
      return null;
    case _Op.snapshotToFile:
      runtime.snapshotToFile(command.argument! as String);
      return null;
    case _Op.restoreFromFile:
      runtime.restoreFromFile(command.argument! as String);
      return null;
    case _Op.reset:
      runtime.reset();
      return null;
    case _Op.stats:
      final RwkvStats s = runtime.stats();
      return <int>[
        s.reviews,
        s.cards,
        s.notes,
        s.decks,
        s.presets,
        s.cardStateBytes,
        s.noteStateBytes,
        s.sharedStateBytes,
        s.featureStateBytes,
      ];
    case _Op.close:
      runtime.dispose();
      return null;
  }
}
