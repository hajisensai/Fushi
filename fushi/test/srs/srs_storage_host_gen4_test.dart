// G7-5：进程级存储持有者的开库状态机（srs_storage_host.dart）——假 opener，不碰原生库。
// 主进程 Primary + 带主库；弹窗 / 查词窗 Secondary、不带主库；Secondary 遇到「主进程还没建库」= null（不缓存）；
// 代际状态（要迁移 / 别的进程在迁移 / 旁边有旧库）原样抛给页面、不缓存，下次重开；close 之后一律失败。
import 'package:drift/drift.dart' show DatabaseConnectionUser;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_storage_host.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

class _Call {
  _Call(this.directory, this.mode, this.legacy);

  final String directory;
  final SrsOpenMode mode;
  final DatabaseConnectionUser? legacy;
}

void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  SrsStorageHost hostWith(
    bool main,
    List<_Call> calls,
    Exception Function(int attempt) outcome,
  ) => SrsStorageHost(
    dbDirectory: 'D:/data/db',
    isMainProcess: main,
    legacyDatabase: () => db,
    opener:
        ({
          required String directory,
          required SrsOpenMode mode,
          DatabaseConnectionUser? legacy,
        }) async {
          calls.add(_Call(directory, mode, legacy));
          throw outcome(calls.length);
        },
  );

  test('the main process opens primary with the main database', () async {
    final List<_Call> calls = <_Call>[];
    final SrsStorageHost h = hostWith(
      true,
      calls,
      (_) => const SrsStoreNotMigrated('x', SrsGenState.needsMigration),
    );
    expect(h.isMainProcess, isTrue);
    expect(h.path, endsWith('srs4.db'));
    expect(h.legacyPath, endsWith('srs.db'));
    await expectLater(h.acquire(), throwsA(isA<SrsStoreNotMigrated>()));
    expect(calls.single.mode, SrsOpenMode.primary);
    expect(calls.single.directory, 'D:/data/db');
    expect(calls.single.legacy, same(db));
  });

  test(
    'a secondary before the primary created the library reads as no data',
    () async {
      final List<_Call> calls = <_Call>[];
      final SrsStorageHost h = hostWith(
        false,
        calls,
        (_) => const SrsStoreNotMigrated('x', SrsGenState.ready),
      );
      expect(await h.acquire(), isNull);
      expect(calls.single.mode, SrsOpenMode.secondary);
      expect(calls.single.legacy, isNull, reason: '辅助进程不碰主库里的旧数据');
      // 不缓存：下次再看（主进程可能已经建好了）。
      expect(await h.acquire(), isNull);
      expect(calls, hasLength(2));
    },
  );

  test('generation states reach the page and are not cached', () async {
    for (final bool main in <bool>[true, false]) {
      for (final SrsStoreOpenBlocked blocked in <SrsStoreOpenBlocked>[
        const SrsStoreNotMigrated('x', SrsGenState.needsMigration),
        const SrsStoreNotMigrated('x', SrsGenState.migrationFailed),
        const SrsStoreNotMigrated('x', SrsGenState.sealedOldOnly),
        const SrsStoreMigrating('x'),
        const SrsStoreLegacyUnmigrated('x'),
      ]) {
        final List<_Call> calls = <_Call>[];
        final SrsStorageHost h = hostWith(main, calls, (_) => blocked);
        await expectLater(h.acquire(), throwsA(same(blocked)));
        await expectLater(h.acquire(), throwsA(same(blocked)));
        expect(calls, hasLength(2), reason: '$blocked main=$main');
      }
    }
  });

  test(
    'reopen after a failed open is harmless; close fails later acquires',
    () async {
      final List<_Call> calls = <_Call>[];
      final SrsStorageHost h = hostWith(
        true,
        calls,
        (_) => const SrsStoreMigrating('x'),
      );
      await expectLater(h.acquire(), throwsA(isA<SrsStoreMigrating>()));
      await h.reopen();
      await h.close();
      await expectLater(h.acquire(), throwsA(isA<StateError>()));
      expect(calls, hasLength(1));
    },
  );
}
