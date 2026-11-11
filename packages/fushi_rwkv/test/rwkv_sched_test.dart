// 真库：排程内核（frwkv_sched_*）经后台 isolate 的消息通道。库找不到判红（硬依赖，不 skip）。
// 这里只验通道本身（编解码、接管输入内存、分段输出、报错路径）；编排逻辑的用例在
// native/fushi_rwkv/src/sched/tests.rs 与 packages/fushi_engine/test/srs/srs_rwkv_service_test.dart。
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:test/test.dart';

/// 把 worker 的输出拆成记录，按到达顺序一条条取。
class _Records {
  _Records(RwkvSchedWorker worker) {
    _subscription = worker.outputs.listen(
      (Uint8List output) {
        _queue.addAll(rwkvSchedRecords(output));
        _wake();
      },
      onError: (Object error) {
        errors.add(error);
        _wake();
      },
      onDone: () {
        done = true;
        _wake();
      },
    );
  }

  late final StreamSubscription<Uint8List> _subscription;
  final Queue<RwkvSchedRecord> _queue = Queue<RwkvSchedRecord>();
  final List<Object> errors = <Object>[];
  bool done = false;
  Completer<void>? _waiting;

  /// 输出流结束（worker 停了）。
  Future<void> get finished async {
    while (!done) {
      await _wait();
    }
  }

  void _wake() {
    final Completer<void>? waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  Future<void> _wait() => (_waiting ??= Completer<void>()).future.timeout(
    const Duration(seconds: 30),
  );

  /// 下一条 tag 为 [tag] 的记录的正文（跳过日志记录）。
  Future<RwkvSchedReader> next(int tag) async {
    while (true) {
      while (_queue.isEmpty) {
        if (errors.isNotEmpty) fail('kernel error: ${errors.first}');
        if (done) fail('worker stopped while waiting for record $tag');
        await _wait();
      }
      final RwkvSchedRecord record = _queue.removeFirst();
      if (record.tag == RwkvSchedWire.outLog) continue;
      expect(record.tag, tag);
      return RwkvSchedReader(record.body);
    }
  }

  Future<Object> nextError() async {
    while (errors.isEmpty) {
      if (done) fail('worker stopped without an error');
      await _wait();
    }
    return errors.removeAt(0);
  }

  Future<void> cancel() => _subscription.cancel();
}

Future<RwkvSchedWorker> _spawn(Directory dir) => RwkvSchedWorker.spawn(
  config: rwkvSchedConfig(
    profile: 'p',
    snapshotDir: dir.path,
    threads: 1,
    journalSeed: 500,
    requeryAfter: const Duration(hours: 1),
    hostBackend: true,
    snapshotIdle: const Duration(minutes: 2),
    retryAfter: const Duration(minutes: 10),
  ),
);

Uint8List _command(
  int op,
  int command, [
  void Function(RwkvSchedWriter)? more,
]) {
  final RwkvSchedWriter w = RwkvSchedWriter()
    ..u8(RwkvSchedWire.inCommand)
    ..u32(op)
    ..u8(command);
  more?.call(w);
  return w.take();
}

Uint8List _reply(int effect, [void Function(RwkvSchedWriter)? body]) {
  final RwkvSchedWriter w = RwkvSchedWriter()
    ..u8(RwkvSchedWire.inReply)
    ..u32(effect)
    ..boolean(true);
  body?.call(w);
  return w.take();
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fushi-rwkv-sched');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test('编解码往返：各种标量、可空值、数组与分段正文', () {
    final RwkvSchedWriter w = RwkvSchedWriter(1)
      ..u8(7)
      ..boolean(true)
      ..u32(0xfffffffe)
      ..i64(-5)
      ..u64(-1)
      ..f32(0.25)
      ..optI64(null)
      ..optI64(9)
      ..str('复习')
      ..optStr(null)
      ..optStr('x')
      ..bytes(Uint8List.fromList(<int>[1, 2, 3]))
      ..i64s(<int>[1, -2])
      ..u64s(<int>[3, -1])
      ..f32s(<double>[0.5, 1.5]);
    final RwkvSchedReader r = RwkvSchedReader(w.take());
    expect(r.u8(), 7);
    expect(r.boolean(), isTrue);
    expect(r.u32(), 0xfffffffe);
    expect(r.i64(), -5);
    expect(r.u64(), -1);
    expect(r.f32(), 0.25);
    expect(r.optI64(), isNull);
    expect(r.optI64(), 9);
    expect(r.str(), '复习');
    expect(r.optStr(), isNull);
    expect(r.optStr(), 'x');
    expect(r.bytes(), <int>[1, 2, 3]);
    expect(r.i64s(), <int>[1, -2]);
    expect(r.u64s(), <int>[3, -1]);
    expect(r.f32s(), <double>[0.5, 1.5]);
    expect(r.isDone, isTrue);
    expect(r.u8, throwsFormatException);
  });

  test('没就绪时打分回「没有」，只顺手触发准备', () async {
    final RwkvSchedWorker worker = await _spawn(dir);
    final _Records records = _Records(worker);
    worker.send(<Uint8List>[
      _command(3, RwkvSchedWire.cmdInstant, (RwkvSchedWriter w) {
        w
          ..u32(2)
          ..i64(1000);
      }),
    ]);
    // 没就绪：这一次不打分，顺手开始准备（第一步是清理已移除的模型，这里挂着不回）。
    final RwkvSchedReader fx = await records.next(RwkvSchedWire.outEffect);
    fx.u32();
    expect(fx.u8(), RwkvSchedWire.fxDeleteRetired);
    final RwkvSchedReader done = await records.next(RwkvSchedWire.outDone);
    expect(done.u32(), 3);
    expect(done.boolean(), isTrue, reason: 'ok');
    expect(done.boolean(), isFalse, reason: 'no scores');
    expect(done.isDone, isTrue);

    worker.send(<Uint8List>[_command(4, RwkvSchedWire.cmdClose)]);
    final RwkvSchedReader closed = await records.next(RwkvSchedWire.outDone);
    expect(closed.u32(), 4);
    expect(closed.boolean(), isTrue);
    await worker.dispose();
    await records.cancel();
  });

  test('启动：权重没就位 → 下载进度 → 下载失败转出错，命令照常结束', () async {
    final RwkvSchedWorker worker = await _spawn(dir);
    final _Records records = _Records(worker);
    worker.send(<Uint8List>[
      _command(1, RwkvSchedWire.cmdStart, (RwkvSchedWriter w) {
        w.boolean(false);
      }),
    ]);

    RwkvSchedReader fx = await records.next(RwkvSchedWire.outEffect);
    int effect = fx.u32();
    expect(fx.u8(), RwkvSchedWire.fxDeleteRetired);
    worker.send(<Uint8List>[_reply(effect)]);

    fx = await records.next(RwkvSchedWire.outEffect);
    effect = fx.u32();
    expect(fx.u8(), RwkvSchedWire.fxModelReady);
    // 回复分两段递：内核收到的是拼好的一条。
    final RwkvSchedWriter path = RwkvSchedWriter()..str('weights.bin');
    worker.send(<Uint8List>[
      _reply(effect, (RwkvSchedWriter w) => w.boolean(false)),
      path.take(),
    ]);

    RwkvSchedReader status = await records.next(RwkvSchedWire.outStatus);
    expect(status.u8(), 1, reason: 'downloading');
    expect(status.boolean(), isTrue, reason: 'phase changed');

    fx = await records.next(RwkvSchedWire.outEffect);
    final int download = fx.u32();
    expect(fx.u8(), RwkvSchedWire.fxDownload);
    final RwkvSchedWriter progress = RwkvSchedWriter()
      ..u8(RwkvSchedWire.inProgress)
      ..u32(download)
      ..i64(5)
      ..i64(10);
    worker.send(<Uint8List>[progress.take()]);

    status = await records.next(RwkvSchedWire.outStatus);
    expect(status.u8(), 1);
    expect(status.boolean(), isFalse, reason: 'same phase');
    expect(status.i64(), 5);
    expect(status.i64(), 10);
    expect(status.boolean(), isFalse, reason: 'no error');

    final RwkvSchedWriter failed = RwkvSchedWriter()
      ..u8(RwkvSchedWire.inReply)
      ..u32(download)
      ..boolean(false)
      ..str('offline');
    worker.send(<Uint8List>[failed.take()]);

    status = await records.next(RwkvSchedWire.outStatus);
    expect(status.u8(), 4, reason: 'failed');
    expect(status.boolean(), isTrue);
    expect(status.i64(), 0);
    expect(status.i64(), 0);
    expect(status.boolean(), isTrue, reason: 'has error');
    expect(status.u32(), download, reason: 'origin = the effect that failed');
    expect(status.str(), 'offline');

    final RwkvSchedReader done = await records.next(RwkvSchedWire.outDone);
    expect(done.u32(), 1);
    expect(done.boolean(), isTrue);

    await worker.dispose();
    await records.cancel();
  });

  test('不合布局的输入：报错不崩，之后照常工作', () async {
    final RwkvSchedWorker worker = await _spawn(dir);
    final _Records records = _Records(worker);
    worker.send(<Uint8List>[
      Uint8List.fromList(<int>[99]),
    ]);
    final Object error = await records.nextError();
    expect(error, isA<RwkvNativeException>());
    expect(error.toString(), contains('unknown input kind 99'));

    worker.send(<Uint8List>[_command(8, RwkvSchedWire.cmdAnswered)]);
    final RwkvSchedReader done = await records.next(RwkvSchedWire.outDone);
    expect(done.u32(), 8);
    await worker.dispose();
    await records.finished;
    await records.cancel();
  });

  test('配置不合布局：spawn 抛 RwkvNativeException', () async {
    await expectLater(
      RwkvSchedWorker.spawn(config: Uint8List.fromList(<int>[1, 2])),
      throwsA(isA<RwkvNativeException>()),
    );
  });
}
