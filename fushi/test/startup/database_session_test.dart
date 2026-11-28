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

void main() {
  group('DatabaseSession', () {
    test('每个登记资源恰好关一次，按登记逆序，连接最后关', () async {
      final List<String> events = <String>[];
      final _RecordingDatabase db = _RecordingDatabase(events);
      final DatabaseSession session = DatabaseSession(
        db,
        label: 'test',
        onError: _Errors().call,
      );
      final Map<String, int> closes = <String, int>{};
      for (final String name in <String>['a', 'b', 'c']) {
        session.own<String>(name, (String r) {
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
      final DatabaseSession session = DatabaseSession(
        db,
        label: 'gen1',
        onError: _Errors().call,
      );
      bool queriedDuringClose = false;
      session.own<Object>(Object(), (Object _) async {
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

    test('关闭开始后不再接受登记（不会挂上一个没人收的资源）', () async {
      final DatabaseSession session = DatabaseSession(
        _RecordingDatabase(<String>[]),
        label: 'test',
        onError: _Errors().call,
      );
      final Completer<void> gate = Completer<void>();
      session.own<Object>(Object(), (Object _) => gate.future, label: 'slow');
      final Future<void> closing = session.close();
      expect(session.isOpen, isFalse);
      expect(
        () => session.own<Object>(Object(), (Object _) {}, label: 'late'),
        throwsA(isA<DatabaseSessionClosedException>()),
      );
      expect(
        () => session.onClosing(() {}, label: 'late'),
        throwsA(isA<DatabaseSessionClosedException>()),
      );
      gate.complete();
      await closing;
    });

    test('一个收尾抛错只记日志，不挡后面的资源与连接', () async {
      final _RecordingDatabase db = _RecordingDatabase(<String>[]);
      final _Errors errors = _Errors();
      final DatabaseSession session = DatabaseSession(
        db,
        label: 'test',
        onError: errors.call,
      );
      bool earlierClosed = false;
      session.own<Object>(
        Object(),
        (Object _) => earlierClosed = true,
        label: 'earlier',
      );
      session.own<Object>(
        Object(),
        (Object _) => throw StateError('boom'),
        label: 'broken',
      );

      await session.close();

      expect(earlierClosed, isTrue);
      expect(db.closeCalls, 1);
      expect(errors.scopes, <String>['test.close(broken)']);
    });

    test('release 提前收掉一个资源，close 时不再收第二次', () async {
      final DatabaseSession session = DatabaseSession(
        _RecordingDatabase(<String>[]),
        label: 'test',
        onError: _Errors().call,
      );
      int closes = 0;
      final Object service = session.own<Object>(
        Object(),
        (Object _) => closes++,
        label: 'service',
      );
      expect(session.owns(service), isTrue);

      await session.release(service);
      expect(session.owns(service), isFalse);
      await session.release(service);
      await session.close();

      expect(closes, 1);
    });

    test('排空上限由 close 的调用方给，收尾动作现读', () async {
      final DatabaseSession session = DatabaseSession(
        _RecordingDatabase(<String>[]),
        label: 'test',
        onError: _Errors().call,
      );
      Duration? seen;
      session.own<Object>(
        Object(),
        (Object _) => seen = session.drainTimeout,
        label: 'pipeline',
      );

      await session.close(drainTimeout: const Duration(seconds: 3));

      expect(seen, const Duration(seconds: 3));
    });

    test('重开后的一代只收自己的资源，旧一代的资源不被重复收', () async {
      final _RecordingDatabase oldDb = _RecordingDatabase(<String>[]);
      final _RecordingDatabase newDb = _RecordingDatabase(<String>[]);
      final DatabaseSession gen1 = DatabaseSession(
        oldDb,
        label: 'gen1',
        onError: _Errors().call,
      );
      final Map<String, int> closes = <String, int>{};
      void count(String r) => closes[r] = (closes[r] ?? 0) + 1;
      gen1.own<String>('repo@gen1', count, label: 'repo');
      await gen1.close();

      final DatabaseSession gen2 = DatabaseSession(
        newDb,
        label: 'gen2',
        onError: _Errors().call,
      );
      gen2.own<String>('repo@gen2', count, label: 'repo');
      expect(identical(gen2.database, newDb), isTrue);
      expect(oldDb.closeCalls, 1);
      expect(newDb.closeCalls, 0);

      await gen2.close();
      expect(closes, <String, int>{'repo@gen1': 1, 'repo@gen2': 1});
      expect(newDb.closeCalls, 1);
    });
  });

  group('ProcessLifetime', () {
    test('逆序收尾、每项恰好一次、关后不再接受登记', () async {
      final ProcessLifetime lifetime = ProcessLifetime(
        label: 'process',
        onError: _Errors().call,
      );
      final List<String> events = <String>[];
      lifetime.own<String>('server', events.add, label: 'server');
      lifetime.own<String>('client', events.add, label: 'client');

      await Future.wait(<Future<void>>[lifetime.close(), lifetime.close()]);

      expect(events, <String>['client', 'server']);
      expect(
        () => lifetime.own<String>('late', events.add, label: 'late'),
        throwsA(isA<DatabaseSessionClosedException>()),
      );
    });
  });
}
