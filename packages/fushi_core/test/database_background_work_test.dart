// BUG-5387：换库（备份恢复 / 合并导入 / 迁移 / 退出）前，后台写库工作必须被取消并
// 停稳，库才关；停稳之后旧工作的任何 SQL 都发不出去（哪怕发给另一个库实例）。
import 'dart:async';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

FushiDatabase _memoryDb() => FushiDatabase.forTesting(NativeDatabase.memory());

void main() {
  test('close() 取消并等待在跑的后台写手，取消后的写入一条都不落库', () async {
    final FushiDatabase db = _memoryDb();
    await db.setPref('seed', '0');
    final Completer<void> firstWritten = Completer<void>();
    final Completer<void> release = Completer<void>();
    final List<int> written = <int>[];
    bool workExited = false;
    Object? workError;

    // 模拟媒体库扫描：逐条写，每条之间要等一个不经数据库的慢操作（读文件 / 网络）。
    final Future<void> work = db
        .runBackgroundWork<void>('test.scan', (DatabaseWorkToken token) async {
          for (int i = 0; i < 100; i++) {
            await db.setPref('scan_$i', '$i');
            written.add(i);
            if (i == 0) {
              firstWritten.complete();
              await release.future;
            }
          }
        })
        .catchError((Object e) {
          workError = e;
        })
        .whenComplete(() => workExited = true);

    await firstWritten.future;
    expect(db.backgroundWork.inFlightLabels, <String>['test.scan']);

    // 读 seed 证明关库前库还活着；随后开始关库（恢复备份走的就是这条）。
    final Future<void> closing = db.close();
    // 关库必须等工作退出：工作还卡在 release 上时 close 不能完成。
    bool closed = false;
    unawaited(closing.then((_) => closed = true));
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse, reason: '后台工作没退出，close 不能先完成');
    expect(workExited, isFalse);

    release.complete();
    await closing;
    await work;
    expect(workExited, isTrue);
    expect(workError, isA<DatabaseWorkCancelledException>());
    expect(written, <int>[0], reason: '取消之后的写入一条都不能发出去');
    expect(db.backgroundWork.inFlightLabels, isEmpty);
  });

  test('关库开始后不再接新的后台工作', () async {
    final FushiDatabase db = _memoryDb();
    await db.close();
    bool ran = false;
    await expectLater(
      db.runBackgroundWork<void>('late', (_) async => ran = true),
      throwsA(isA<DatabaseWorkCancelledException>()),
    );
    expect(ran, isFalse);
  });

  test('被取消的工作里事务半截回滚，旧库读出的行身份写不进新库', () async {
    final FushiDatabase oldDb = _memoryDb();
    final FushiDatabase newDb = _memoryDb();
    await oldDb.setPref('row', 'old-identity');
    final Completer<void> inTransaction = Completer<void>();
    final Completer<void> release = Completer<void>();

    // 模拟刮削 / 封面回填：从旧库读到行身份，在等慢操作期间库被换掉，之后才写。
    final Future<Object?> work = oldDb
        .runBackgroundWork<void>('test.scrape', (
          DatabaseWorkToken token,
        ) async {
          final String? identity = await oldDb.getPref('row');
          await oldDb.transaction(() async {
            await oldDb.setPref('half', 'written');
            inTransaction.complete();
            await release.future;
            await oldDb.setPref('half2', 'written');
          });
          // 换库之后旧工作拿着旧身份去写「当前库」（新库实例）也必须被拦下。
          await newDb.setPref('stale', identity!);
        })
        .then<Object?>((_) => null, onError: (Object e) => e);

    await inTransaction.future;
    final Future<void> closing = oldDb.quiesceBackgroundWork();
    release.complete();
    await closing;
    expect(await work, isA<DatabaseWorkCancelledException>());
    expect(await oldDb.getPref('half'), isNull, reason: '半截事务必须回滚');
    expect(await newDb.getPref('stale'), isNull);
    await oldDb.close();
    await newDb.close();
  });

  test('guard：等不经数据库的慢操作时，关库立即放行、不等它跑完', () async {
    final FushiDatabase db = _memoryDb();
    final Completer<String> slowHash = Completer<String>();
    final Future<Object?> work = db
        .runBackgroundWork<String>(
          'test.hash',
          (DatabaseWorkToken token) => token.guard(slowHash.future),
        )
        .then<Object?>((String v) => v, onError: (Object e) => e);
    await Future<void>.delayed(Duration.zero);
    await db.close();
    expect(await work, isA<DatabaseWorkCancelledException>());
    // 慢操作之后才完成，也不会成为未处理的异步错误。
    slowHash.complete('late');
  });

  test('不在后台工作里的普通查询不受影响', () async {
    final FushiDatabase db = _memoryDb();
    await db.setPref('k', 'v');
    expect(await db.getPref('k'), 'v');
    expect(DatabaseWorkToken.current, isNull);
    await db.close();
  });

  test('guard / onCancelled 结束即注销：长寿命的库上取消回调不随操作数累积', () async {
    final FushiDatabase db = _memoryDb();
    await db.runBackgroundWork<void>('test.manyFiles', (
      DatabaseWorkToken token,
    ) async {
      for (int i = 0; i < 500; i++) {
        await token.guard(Future<int>.value(i));
        await expectLater(
          token.guard(Future<int>.error(StateError('bad file $i'))),
          throwsStateError,
        );
      }
      final void Function() unlink = token.onCancelled(() {});
      expect(db.backgroundWork.pendingCancelListenerCount, 1);
      unlink();
    });
    expect(db.backgroundWork.pendingCancelListenerCount, 0);
    await db.close();
  });

  test('onCancelled：关库时触发；库已在关时登记当场触发', () async {
    final FushiDatabase db = _memoryDb();
    final Completer<void> release = Completer<void>();
    int fired = 0;
    final Future<void> work = db.runBackgroundWork<void>('test.scrape', (
      DatabaseWorkToken token,
    ) async {
      final void Function() unlink = token.onCancelled(() => fired++);
      try {
        await release.future;
      } finally {
        unlink();
      }
      token.onCancelled(() => fired++);
    });
    final Future<void> closing = db.close();
    expect(fired, 1);
    release.complete();
    await work;
    await closing;
    expect(fired, 2);
    expect(db.backgroundWork.pendingCancelListenerCount, 0);
  });

  test('在本库自己的后台工作里关库直接报错，不自等挂死', () async {
    final FushiDatabase db = _memoryDb();
    await expectLater(
      db.runBackgroundWork<void>('test.self', (_) => db.close()),
      throwsStateError,
    );
    expect(db.backgroundWork.isClosing, isFalse);
    await db.close();
  });
}
