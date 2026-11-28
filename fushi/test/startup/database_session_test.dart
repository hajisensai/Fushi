import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/startup/database_session.dart';
import 'package:fushi_core/fushi_core.dart';

/// 记录 close 调用的内存库：断言「连接最后关、只关一次」。
class _RecordingDatabase extends FushiDatabase {
  _RecordingDatabase(this.events) : super.forTesting(NativeDatabase.memory());

  final List<String> events;
  int closeCalls = 0;

  @override
  Future<void> close() {
    closeCalls++;
    events.add('connection');
    return super.close();
  }
}

/// 收尾失败的去处（生产接 ErrorLogService）。
class _Errors {
  final List<String> scopes = <String>[];

  void call(String scope, Object error, StackTrace stack) => scopes.add(scope);
}

DatabaseSession _session(
  _RecordingDatabase db, {
  String label = 'test',
  _Errors? errors,
}) => DatabaseSession(db, label: label, onError: (errors ?? _Errors()).call);

void main() {
  group('DatabaseSession', () {
    test('每个登记资源恰好关一次，按登记逆序，连接最后关', () async {
      final List<String> events = <String>[];
      final _RecordingDatabase db = _RecordingDatabase(events);
      final DatabaseSession session = _session(db);
      final Map<String, int> closes = <String, int>{};
      for (final String name in <String>['a', 'b', 'c']) {
        session.own<String>(() => name, (String r) {
          closes[r] = (closes[r] ?? 0) + 1;
          events.add(r);
        }, label: name);
      }
      session.onClosing(() => events.add('closing'), label: 'signal');

      // 并发 / 重复关拿到同一次关闭。
      await Future.wait(<Future<void>>[session.close(), session.close()]);
      await session.close();

      expect(closes, <String, int>{'a': 1, 'b': 1, 'c': 1});
      expect(events, <String>['closing', 'c', 'b', 'a', 'connection']);
      expect(db.closeCalls, 1);
      expect(session.isClosed, isTrue);
    });

    test('收尾期间还能用这一代的连接；关完再取抛类型化异常', () async {
      final _RecordingDatabase db = _RecordingDatabase(<String>[]);
      final DatabaseSession session = _session(db, label: 'gen1');
      bool queriedDuringClose = false;
      session.own<Object>(Object.new, (Object _) async {
        // 例如词典写入队列排空：收尾动作自己要写本代的库。
        await session.database.getAllDictionaryMetadata();
        queriedDuringClose = true;
      }, label: 'flush');

      await session.close();

      expect(queriedDuringClose, isTrue);
      expect(
        () => session.database,
        throwsA(
          isA<DatabaseSessionClosedException>()
              .having((e) => e.owner, 'owner', 'gen1')
              .having((e) => e.operation, 'operation', 'database'),
        ),
      );
    });

    test('先登记后构造：关闭开始后工厂根本不会被调用，没有建好却没人收的对象', () async {
      final DatabaseSession session = _session(_RecordingDatabase(<String>[]));
      final Completer<void> gate = Completer<void>();
      session.own<Object>(Object.new, (Object _) => gate.future, label: 'slow');
      final Future<void> closing = session.close();

      expect(session.isOpen, isFalse, reason: '门闩与「登记会不会被拒」是同一个条件');
      expect(session.isClosed, isFalse);
      int constructed = 0;
      expect(
        () => session.own<Object>(
          () {
            constructed++;
            return Object();
          },
          (Object _) {},
          label: 'late',
        ),
        throwsA(isA<DatabaseSessionClosedException>()),
      );
      final OwnedSlot<Object> slot = OwnedSlot<Object>('lazy', (Object _) {});
      expect(
        () => slot.obtain(session, () {
          constructed++;
          return Object();
        }),
        throwsA(isA<DatabaseSessionClosedException>()),
      );
      expect(constructed, 0);
      expect(slot.valueOrNull, isNull, reason: '被拒的登记不会在槽位里留下东西');
      expect(
        () => session.onClosing(() {}, label: 'late'),
        throwsA(isA<DatabaseSessionClosedException>()),
      );
      expect(
        () => session.onConnectionClosing(() {}, label: 'late'),
        throwsA(isA<DatabaseSessionClosedException>()),
      );
      gate.complete();
      await closing;
    });

    test('关闭信号的回调里再登记同样被拒（封栈先于任何回调）', () async {
      final DatabaseSession session = _session(_RecordingDatabase(<String>[]));
      Object? rejected;
      session.onClosing(() {
        try {
          session.own<Object>(Object.new, (Object _) {}, label: 'reentrant');
        } catch (e) {
          rejected = e;
        }
      }, label: 'reentrant');

      await session.close();

      expect(rejected, isA<DatabaseSessionClosedException>());
    });

    test('工厂自己抛错时什么都没登记', () async {
      final _RecordingDatabase db = _RecordingDatabase(<String>[]);
      final DatabaseSession session = _session(db);
      int closes = 0;
      expect(
        () => session.own<Object>(
          () => throw StateError('ctor'),
          (Object _) => closes++,
          label: 'broken',
        ),
        throwsStateError,
      );
      expect(session.debugOwnedLabels.withSession, isEmpty);
      await session.close();
      expect(closes, 0);
    });

    test('一个收尾抛错只记日志，不挡后面的资源与连接', () async {
      final _RecordingDatabase db = _RecordingDatabase(<String>[]);
      final _Errors errors = _Errors();
      final DatabaseSession session = _session(db, errors: errors);
      bool earlierClosed = false;
      session.own<Object>(
        Object.new,
        (Object _) => earlierClosed = true,
        label: 'earlier',
      );
      session.own<Object>(
        Object.new,
        (Object _) => throw StateError('boom'),
        label: 'broken',
      );

      await session.close();

      expect(earlierClosed, isTrue);
      expect(db.closeCalls, 1);
      expect(errors.scopes, <String>['test.close(broken)']);
    });

    test('排空上限由 close 的调用方给，收尾动作现读', () async {
      final DatabaseSession session = _session(_RecordingDatabase(<String>[]));
      Duration? seen;
      session.own<Object>(
        Object.new,
        (Object _) => seen = session.drainTimeout,
        label: 'pipeline',
      );

      await session.close(drainTimeout: const Duration(seconds: 3));

      expect(seen, const Duration(seconds: 3));
    });

    test('关连接的顺序：信号 → 模型侧资源 → 后台工作退出 → 与连接同寿命的资源 → 连接', () async {
      final List<String> events = <String>[];
      final _RecordingDatabase db = _RecordingDatabase(events);
      final DatabaseSession session = _session(db);
      final Completer<void> workMayExit = Completer<void>();
      final Future<void> work = db.runBackgroundWork<void>('scan', (
        DatabaseWorkToken _,
      ) async {
        await workMayExit.future;
        events.add('background work exited');
      });
      session.own<String>(
        () => 'storage',
        events.add,
        label: 'storage',
        phase: ReleasePhase.withConnection,
      );
      session.own<String>(
        () => 'writers',
        events.add,
        label: 'writers',
        phase: ReleasePhase.withConnection,
      );
      session.own<String>(() => 'service', (String r) {
        events.add(r);
        workMayExit.complete();
      }, label: 'service');
      session.onClosing(() => events.add('stop intake'), label: 'intake');
      session.onConnectionClosing(
        () => events.add('connection closing'),
        label: 'signal',
      );

      await session.close();
      await work;

      expect(events, <String>[
        'connection closing',
        'stop intake',
        'service',
        'background work exited',
        'writers',
        'storage',
        'connection',
      ]);
    });

    test('重开后的一代只收自己的资源，旧一代的资源不被重复收', () async {
      final _RecordingDatabase oldDb = _RecordingDatabase(<String>[]);
      final _RecordingDatabase newDb = _RecordingDatabase(<String>[]);
      final DatabaseSession gen1 = _session(oldDb, label: 'gen1');
      final Map<String, int> closes = <String, int>{};
      void count(String r) => closes[r] = (closes[r] ?? 0) + 1;
      gen1.own<String>(() => 'repo@gen1', count, label: 'repo');
      await gen1.close();

      final DatabaseSession gen2 = _session(newDb, label: 'gen2');
      gen2.own<String>(() => 'repo@gen2', count, label: 'repo');
      expect(identical(gen2.database, newDb), isTrue);
      expect(oldDb.closeCalls, 1);
      expect(newDb.closeCalls, 0);

      await gen2.close();
      expect(closes, <String, int>{'repo@gen1': 1, 'repo@gen2': 1});
      expect(newDb.closeCalls, 1);
    });
  });

  group('DatabaseSession.detach（持有者自身销毁）', () {
    test('只收模型侧资源：不发关连接信号、不动与连接同寿命的资源、不关连接', () async {
      final List<String> events = <String>[];
      final _RecordingDatabase db = _RecordingDatabase(events);
      final DatabaseSession session = _session(db, label: 'owner-dispose');
      session.own<String>(() => 'repo', events.add, label: 'repo');
      session.own<String>(
        () => 'storage',
        events.add,
        label: 'storage',
        phase: ReleasePhase.withConnection,
      );
      session.onClosing(() => events.add('stop intake'), label: 'intake');
      session.onConnectionClosing(
        () => events.add('connection closing'),
        label: 'signal',
      );

      await session.detach();
      // 先 detach 之后再 close 不会回头关连接。
      await session.close();

      expect(events, <String>['stop intake', 'repo']);
      expect(db.closeCalls, 0);
      expect(session.isOpen, isFalse);
      expect(
        () => session.database,
        throwsA(isA<DatabaseSessionClosedException>()),
      );
      expect(
        () => session.own<Object>(Object.new, (Object _) {}, label: 'late'),
        throwsA(isA<DatabaseSessionClosedException>()),
      );
      expect(await db.getAllDictionaryMetadata(), isEmpty);
      await db.close();
    });

    test('后台工作不进入关闭态：连接的持有方之后还能登记新的后台工作', () async {
      final _RecordingDatabase db = _RecordingDatabase(<String>[]);
      final DatabaseSession session = _session(db);

      await session.detach();

      expect(
        await db.runBackgroundWork<int>(
          'after-detach',
          (DatabaseWorkToken _) async => 7,
        ),
        7,
      );
      await db.close();
    });
  });

  group('OwnedSlot', () {
    test('写槽位与登记是同一步；所属那一代关闭时收尾并清空，下一代重建', () async {
      final List<String> closed = <String>[];
      final OwnedSlot<String> slot = OwnedSlot<String>('service', closed.add);
      final DatabaseSession gen1 = _session(
        _RecordingDatabase(<String>[]),
        label: 'gen1',
      );
      int built = 0;
      String build(String generation) {
        built++;
        return 'service@$generation';
      }

      expect(slot.valueOrNull, isNull);
      expect(slot.obtain(gen1, () => build('gen1')), 'service@gen1');
      expect(slot.obtain(gen1, () => build('gen1')), 'service@gen1');
      expect(built, 1, reason: '同一代里只建一次');
      expect(gen1.debugOwnedLabels.withSession, <String>['service']);

      await gen1.close();
      expect(closed, <String>['service@gen1']);
      expect(slot.valueOrNull, isNull, reason: '上一代的对象不会被带到下一代');

      final DatabaseSession gen2 = _session(
        _RecordingDatabase(<String>[]),
        label: 'gen2',
      );
      expect(slot.obtain(gen2, () => build('gen2')), 'service@gen2');
      await gen2.close();
      expect(closed, <String>['service@gen1', 'service@gen2']);
    });

    test('收尾动作看到的槽位已经是空的（收尾途中不会被当成还活着）', () async {
      late final OwnedSlot<Object> slot;
      Object? seenDuringClose = Object();
      slot = OwnedSlot<Object>(
        'service',
        (Object _) => seenDuringClose = slot.valueOrNull,
      );
      final DatabaseSession session = _session(_RecordingDatabase(<String>[]));
      slot.obtain(session, Object.new);

      await session.close();

      expect(seenDuringClose, isNull);
    });

    test('release 提前收掉当前值，close 时不再收第二次；replace 先收旧的', () async {
      final List<String> closed = <String>[];
      final OwnedSlot<String> slot = OwnedSlot<String>('service', closed.add);
      final DatabaseSession session = _session(_RecordingDatabase(<String>[]));
      slot.obtain(session, () => 'v1');

      final Future<void> released = slot.release();
      expect(slot.valueOrNull, isNull, reason: '槽位同步清空');
      await released;
      await slot.release();
      expect(closed, <String>['v1']);

      slot.obtain(session, () => 'v2');
      expect(slot.replace(session, () => 'v3'), 'v3');
      expect(closed, <String>['v1', 'v2']);
      expect(session.debugOwnedLabels.withSession, <String>['service']);

      await session.close();
      expect(closed, <String>['v1', 'v2', 'v3']);
    });

    test('与连接同寿命的槽位在 detach 之后原样留着', () async {
      final List<String> closed = <String>[];
      final OwnedSlot<String> slot = OwnedSlot<String>(
        'storage',
        closed.add,
        phase: ReleasePhase.withConnection,
      );
      final _RecordingDatabase db = _RecordingDatabase(<String>[]);
      final DatabaseSession session = _session(db);
      slot.obtain(session, () => 'srs');
      expect(session.debugOwnedLabels.withConnection, <String>['storage']);

      await session.detach();

      expect(closed, isEmpty);
      expect(slot.valueOrNull, 'srs');
      await db.close();
    });
  });

  group('ProcessLifetime', () {
    test('逆序收尾、每项恰好一次、关后不再接受登记', () async {
      final ProcessLifetime lifetime = ProcessLifetime(
        label: 'process',
        onError: _Errors().call,
      );
      final List<String> events = <String>[];
      lifetime.own<String>(() => 'server', events.add, label: 'server');
      final OwnedSlot<String> slot = OwnedSlot<String>('client', events.add);
      expect(slot.obtain(lifetime, () => 'client'), 'client');

      await Future.wait(<Future<void>>[lifetime.close(), lifetime.close()]);

      expect(events, <String>['client', 'server']);
      expect(slot.valueOrNull, isNull);
      int constructed = 0;
      expect(
        () => slot.obtain(lifetime, () {
          constructed++;
          return 'late';
        }),
        throwsA(isA<DatabaseSessionClosedException>()),
      );
      expect(constructed, 0);
    });

    test('进程级生命周期没有「与连接同寿命」这一档', () {
      final ProcessLifetime lifetime = ProcessLifetime(
        label: 'process',
        onError: _Errors().call,
      );
      final OwnedSlot<String> slot = OwnedSlot<String>(
        'storage',
        (String _) {},
        phase: ReleasePhase.withConnection,
      );
      expect(() => slot.obtain(lifetime, () => 'x'), throwsArgumentError);
      expect(slot.valueOrNull, isNull);
    });
  });
}
