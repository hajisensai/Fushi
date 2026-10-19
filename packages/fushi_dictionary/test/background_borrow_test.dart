import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';

/// HBK-AUDIT-009：后台借用原生词典句柄的 Dart 侧次序（[borrowNativeHandle] /
/// [BackgroundBorrowLedger]）。
///
/// 原生侧的引用计数与读写锁由 ctest `handle_lifecycle_concurrency_test` 用真线程验证；
/// 这里用一个与原生同契约的假句柄（create 带 1 个引用、retain 退役后拒绝、destroy 退役
/// 只还一次、最后一个 release 销毁）加屏障，钉住 Dart 侧必须保证的三件事：
///   * 借用期间宿主 dispose（退役）不会销毁句柄；工作体结束、引用归还才销毁，且只一次；
///   * 借到就一定还：工作体同步抛 / 异步抛 / release 自己抛，都不漏还、不卡死 settled；
///   * 「释放映射」= dispose 后等 settled：settled 完成时旧句柄一定已销毁（BUG-1756
///     删目录的前提），settled 只等此刻已登记的借用。
class _FakeNativeHandle {
  int refs = 1;
  bool retired = false;
  int destroyCount = 0;
  int retainCalls = 0;
  int releaseCalls = 0;

  bool get destroyed => destroyCount > 0;

  bool retain() {
    retainCalls++;
    if (retired) return false;
    refs++;
    return true;
  }

  void _drop() {
    refs--;
    expect(refs, greaterThanOrEqualTo(0), reason: 'reference count underflow');
    if (refs == 0) destroyCount++;
  }

  void release() {
    releaseCalls++;
    _drop();
  }

  /// `fushidicts_destroy`：退役只发生一次。
  void destroy() {
    if (retired) return;
    retired = true;
    _drop();
  }
}

void main() {
  test(
    'dispose during a borrow retires; the last release destroys once',
    () async {
      final BackgroundBorrowLedger ledger = BackgroundBorrowLedger();
      final _FakeNativeHandle h = _FakeNativeHandle();
      final Completer<List<int>> gate = Completer<List<int>>();

      final Future<List<int>?> borrowed = borrowNativeHandle<List<int>>(
        ledger: ledger,
        retain: h.retain,
        release: h.release,
        work: () => gate.future,
      );
      expect(h.refs, 2);
      expect(ledger.inFlight, 1);

      // 词典重载：宿主实例 dispose。
      h.destroy();
      expect(
        h.destroyed,
        isFalse,
        reason: 'borrowed handle must survive dispose',
      );

      bool settled = false;
      final Future<void> settle = ledger.settled().then((_) => settled = true);
      await pumpEventQueue();
      expect(settled, isFalse, reason: 'settled must wait for the borrow');
      expect(h.destroyed, isFalse);

      gate.complete(<int>[3, 2]);
      expect(await borrowed, <int>[3, 2]);
      await settle;
      expect(settled, isTrue);
      expect(h.destroyCount, 1);
      expect(h.retainCalls, 1);
      expect(h.releaseCalls, 1);
      expect(ledger.inFlight, 0);
    },
  );

  test('a retired handle is not borrowed and the work never runs', () async {
    final BackgroundBorrowLedger ledger = BackgroundBorrowLedger();
    final _FakeNativeHandle h = _FakeNativeHandle()..destroy();
    bool ran = false;
    final List<int>? out = await borrowNativeHandle<List<int>>(
      ledger: ledger,
      retain: h.retain,
      release: h.release,
      work: () async {
        ran = true;
        return <int>[];
      },
    );
    expect(out, isNull);
    expect(ran, isFalse);
    expect(h.releaseCalls, 0, reason: 'nothing borrowed, nothing to return');
    expect(h.destroyCount, 1);
    expect(ledger.inFlight, 0);
  });

  test(
    'the reference is returned when the work throws (sync or async)',
    () async {
      final BackgroundBorrowLedger ledger = BackgroundBorrowLedger();
      final _FakeNativeHandle h = _FakeNativeHandle();

      await expectLater(
        borrowNativeHandle<int>(
          ledger: ledger,
          retain: h.retain,
          release: h.release,
          work: () => throw StateError('isolate failed to start'),
        ),
        throwsStateError,
      );
      await expectLater(
        borrowNativeHandle<int>(
          ledger: ledger,
          retain: h.retain,
          release: h.release,
          work: () async => throw const FormatException('worker failed'),
        ),
        throwsFormatException,
      );
      expect(h.retainCalls, 2);
      expect(h.releaseCalls, 2);
      expect(h.refs, 1);
      await ledger.settled();
      expect(ledger.inFlight, 0);
    },
  );

  test('settled still completes when release itself throws', () async {
    final BackgroundBorrowLedger ledger = BackgroundBorrowLedger();
    final _FakeNativeHandle h = _FakeNativeHandle();
    await expectLater(
      borrowNativeHandle<int>(
        ledger: ledger,
        retain: h.retain,
        release: () => throw StateError('release failed'),
        work: () async => 1,
      ),
      throwsStateError,
    );
    await ledger.settled().timeout(const Duration(seconds: 5));
    expect(ledger.inFlight, 0);
  });

  test(
    'settled only waits for borrows registered before it was asked',
    () async {
      final BackgroundBorrowLedger ledger = BackgroundBorrowLedger();
      final _FakeNativeHandle oldHandle = _FakeNativeHandle();
      final _FakeNativeHandle newHandle = _FakeNativeHandle();
      final Completer<int> oldGate = Completer<int>();
      final Completer<int> newGate = Completer<int>();

      unawaited(
        borrowNativeHandle<int>(
          ledger: ledger,
          retain: oldHandle.retain,
          release: oldHandle.release,
          work: () => oldGate.future,
        ),
      );
      // releaseAllMappingsAndSettle 的形状：dispose 旧实例后等 settled。
      oldHandle.destroy();
      final Future<void> settle = ledger.settled();
      // 等待期间新实例上又起了一次借用：它不该拖住这次释放。
      unawaited(
        borrowNativeHandle<int>(
          ledger: ledger,
          retain: newHandle.retain,
          release: newHandle.release,
          work: () => newGate.future,
        ),
      );
      oldGate.complete(1);
      await settle.timeout(const Duration(seconds: 5));
      expect(oldHandle.destroyCount, 1, reason: 'old mappings released');
      expect(newHandle.destroyed, isFalse);
      expect(ledger.inFlight, 1);
      newGate.complete(2);
      await ledger.settled();
      expect(newHandle.refs, 1);
    },
  );

  test('a real background isolate keeps the borrow until it returns', () async {
    final BackgroundBorrowLedger ledger = BackgroundBorrowLedger();
    final _FakeNativeHandle h = _FakeNativeHandle();
    final ReceivePort ready = ReceivePort();
    final ReceivePort finish = ReceivePort();
    final Future<String?> worker = borrowNativeHandle<String>(
      ledger: ledger,
      retain: h.retain,
      release: h.release,
      work: () => _runParked(ready.sendPort),
    );
    // 后台 isolate 已经在跑、并停在屏障上。
    final SendPort release = await ready.first as SendPort;
    h.destroy();
    await pumpEventQueue();
    expect(h.destroyed, isFalse, reason: 'worker still holds the borrow');
    release.send(finish.sendPort);
    expect(await worker, 'worker-done');
    await ledger.settled();
    expect(h.destroyCount, 1);
    finish.close();
  });
}

/// 后台 isolate：把自己的屏障端口交回，收到放行信号后结束。
Future<String> _runParked(SendPort ready) => Isolate.run(() async {
  final ReceivePort gate = ReceivePort();
  ready.send(gate.sendPort);
  await gate.first;
  gate.close();
  return 'worker-done';
});
