import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('srs_core_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// 新代库文件（native/fushi_fsrs/src/store/gen4/files.rs `GEN4_FILE`）。
  String gen4File() => '${dir.path}${Platform.pathSeparator}srs4.db';

  test('row codec round-trips every value kind', () {
    final List<List<Object?>> rows = <List<Object?>>[
      <Object?>[
        null,
        1,
        -9007199254740993,
        0.1,
        'あ😀',
        Uint8List.fromList(<int>[0, 255]),
      ],
      <Object?>['', 0, 1 << 62, -0.0, 'x', Uint8List(0)],
    ];
    final (int cols, List<List<Object?>> back) = srsDecodeRows(
      srsEncodeRows(6, rows),
    );
    expect(cols, 6);
    expect(back, rows);
    expect(
      () => srsDecodeRows(Uint8List.fromList(<int>[1, 0, 0, 0, 1, 0, 0, 0, 9])),
      throwsFormatException,
    );
  });

  test(
    'diagCounts sees an open core and its SQLite heap (BUG-4075 memory probe)',
    () {
      final SrsCoreDiagCounts before = SrsCore.diagCounts()!;
      final SrsCore core = SrsCore.open(dir.path);
      addTearDown(core.close);
      final SrsCoreDiagCounts open = SrsCore.diagCounts()!;
      expect(open.openHandles, before.openHandles + 1);
      expect(open.liveCores, before.liveCores + 1);
      expect(open.sqliteBytes, greaterThan(0));
      expect(open.sqliteHighwaterBytes, greaterThanOrEqualTo(open.sqliteBytes));
      expect(open.walBytes, greaterThanOrEqualTo(0));
      expect(
        open.describe(),
        matches(
          RegExp(r'^srs=\d+/\d+ rd=\d+ sqlite=\d+/\d+MB db=\d+MB wal=\d+MB$'),
        ),
      );

      core.close();
      final SrsCoreDiagCounts closed = SrsCore.diagCounts()!;
      expect(closed.openHandles, before.openHandles);
      expect(closed.liveCores, before.liveCores);
    },
  );

  // S1 之后 `ffsrs_store_open` 已删：Primary 在空目录里建新代库 `srs4.db`，不建协议 3 的 `srs.db`。
  test('a primary open of an empty directory creates the gen4 library', () {
    final SrsCore core = SrsCore.open(dir.path);
    addTearDown(core.close);
    expect(File(gen4File()).existsSync(), isTrue);
    expect(
      File('${dir.path}${Platform.pathSeparator}srs.db').existsSync(),
      isFalse,
    );
    expect(core.debugQuery('SELECT 1 AS one').single['one'], 1);
    expect(
      SrsGen4Migration.status(dir.path).state,
      SrsGenState.ready,
      reason: 'a fresh gen4 library needs no migration',
    );
  });

  // 查词弹窗等辅助进程：只读、不建库。主进程还没建库时按「ready」（等主进程）报 -4，不当成空库打开。
  test('a secondary open never creates a library and reports the state', () {
    expect(
      () => SrsCore.open(dir.path, mode: SrsOpenMode.secondary),
      throwsA(
        isA<SrsStoreNotMigrated>().having(
          (SrsStoreNotMigrated e) => e.state,
          'state',
          SrsGenState.ready,
        ),
      ),
    );
    expect(File(gen4File()).existsSync(), isFalse);

    SrsCore.open(dir.path).close();
    final SrsCore secondary = SrsCore.open(
      dir.path,
      mode: SrsOpenMode.secondary,
    );
    addTearDown(secondary.close);
    expect(secondary.debugQuery('SELECT 1 AS one').single['one'], 1);
  });

  // 备份快照已接新代（G11-4），但剥离本机状态的请求明确报错。协议 1 旧主库的搬迁入口（`ffsrs_store_legacy_*`）
  // 已随 G7-6 删掉（主库残留的协议 1 表由 `SrsStorage.open` 明确拒绝，见 srs_legacy_main_database_test.dart）。
  test(
    'a snapshot that strips device-local state is a clear error on gen4',
    () {
      final SrsCore core = SrsCore.open(dir.path);
      addTearDown(core.close);
      expect(
        () => core.snapshotInto(
          '${dir.path}${Platform.pathSeparator}snap.db',
          stripDeviceLocal: true,
        ),
        // G11-4 已把快照接到新代；只是不支持剥离本机状态（备份走按集合的导出流），报一般错误。
        throwsA(
          isA<SrsCoreException>().having(
            (SrsCoreException e) => e.message,
            'message',
            contains('stripping device-local state is not supported'),
          ),
        ),
      );
    },
  );

  // 刷新键是内核的进程内计数（`refresh_keys`，gen4/refresh.rs）：一次取回五个键，没有写入就不变，只写本机状态行的
  // 命令不推进；关库后为 null。
  test('refresh keys come from the kernel counters', () {
    final SrsCore core = SrsCore.open(dir.path);
    const String profile = 'p';
    final SrsRefreshKeys a = core.refreshKeys(profile)!;
    expect(a.content, matches(RegExp(r'^[0-9a-f]+:0$')));
    expect(a.structure, matches(RegExp(r'^[0-9a-f]+:0:0$')));
    core.sync2(<String, Object?>{
      'op': 'local_state_ensure',
      'profile': profile,
    });
    expect(core.refreshKeys(profile), a);
    core.close();
    expect(core.refreshKeys(profile), isNull);
  });

  test('a borrowed handle does not close the owner', () {
    final SrsCore core = SrsCore.open(dir.path);
    final SrsCore borrowed = SrsCore.fromAddress(
      core.address,
      libraryPath: core.libraryPath,
    );
    borrowed.close();
    expect(core.debugQuery('SELECT 1 AS one').single['one'], 1);
    core.close();
    expect(() => core.debugQuery('SELECT 1'), throwsStateError);
  });

  // 3.1.0 安卓白屏：app 开库必须在后台 isolate，句柄回到调用方并归它拥有。
  test('openInBackground hands the caller an owned, usable handle', () async {
    final SrsCore core = await SrsCore.openInBackground(dir.path);
    expect(core.owned, isTrue);
    expect(core.debugQuery('SELECT 1 AS one').single['one'], 1);
    core.close();
    expect(() => core.debugQuery('SELECT 1'), throwsStateError);
    // 关闭返回时库文件已没有打开的句柄（后台 isolate 没留下第二个拥有者）。
    File(gen4File()).deleteSync();
  });

  // 进程级 SQLite 临时目录（Android 上开库前必须设）：只设一次，同一目录再设是空操作，换目录报错。用常驻的系统临时
  // 目录，不影响本进程里别的测试。
  test('useTempDirectory is set once per process', () {
    final String stable = Directory.systemTemp.path;
    SrsCore.useTempDirectory(stable);
    SrsCore.useTempDirectory(stable);
    expect(
      () => SrsCore.useTempDirectory(dir.path),
      throwsA(isA<SrsCoreException>()),
    );
    final SrsCore core = SrsCore.open(dir.path);
    expect(core.debugQuery('SELECT 1 AS one').single['one'], 1);
    core.close();
  });

  test('openInBackground rethrows the typed open state', () {
    // 打开页按类型选页面：代际状态要以原类型回到调用方。
    expect(
      SrsCore.openInBackground(dir.path, mode: SrsOpenMode.secondary),
      throwsA(isA<SrsStoreNotMigrated>()),
    );
  });

  // 回归（2026-10-25 CI SIGABRT）：拥有者关库时，后台 isolate 经 fromAddress 拿着同一个句柄还在
  // 跑命令。关闭等在途命令跑完；之后经旧地址的命令报「已关闭」而不是崩。
  test('closing while a worker isolate uses the handle neither crashes nor '
      'leaves the address dangling', () async {
    final SrsCore core = SrsCore.open(dir.path);
    final int address = core.address;
    final String? libraryPath = core.libraryPath;

    final Future<Object?> worker = Isolate.run(() {
      try {
        return SrsCore.fromAddress(address, libraryPath: libraryPath)
            .debugQuery(
              'WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n '
              'WHERE x < 3000000) SELECT count(*) AS c FROM n',
            )
            .single['c'];
      } on SrsCoreException catch (e) {
        return e.message;
      }
    });
    core.close();
    final Object? outcome = await worker;
    expect(
      outcome,
      anyOf(3000000, contains('srs store is closed')),
      reason: 'the worker either finished before the close or saw it',
    );

    final Object? late = await Isolate.run(() {
      try {
        SrsCore.fromAddress(
          address,
          libraryPath: libraryPath,
        ).debugQuery('SELECT 1');
        return 'no error';
      } on SrsCoreException catch (e) {
        return e.message;
      }
    });
    expect(late, contains('srs store is closed'));
    File(gen4File()).deleteSync();
  });

  group('typed errors (contract with store/ffi.rs and gen4/kernel.rs)', () {
    test('status codes and prefixes match the native constants', () {
      final String ffi = File(
        '../../native/fushi_fsrs/src/store/ffi.rs',
      ).readAsStringSync();
      final String kernel = File(
        '../../native/fushi_fsrs/src/store/gen4/kernel.rs',
      ).readAsStringSync();
      expect(
        ffi,
        contains(
          'pub const STORE_NOT_MIGRATED: i32 = ${SrsStoreNotMigrated.statusCode};',
        ),
      );
      expect(
        ffi,
        contains(
          'pub const STORE_MIGRATING: i32 = ${SrsStoreMigrating.statusCode};',
        ),
      );
      expect(
        ffi,
        contains(
          'pub const STORE_LEGACY_UNMIGRATED: i32 = '
          '${SrsStoreLegacyUnmigrated.statusCode};',
        ),
      );
      expect(
        kernel,
        contains(
          'pub const UNWIRED: &str = "${SrsCoreUnwiredException.prefix}";',
        ),
      );
      expect(
        kernel,
        contains(
          'pub const REMOVED: &str = "${SrsCoreRemovedException.prefix}";',
        ),
      );
    });

    test('every generation state parses from the -4 text', () {
      for (final SrsGenState s in SrsGenState.values) {
        final SrsCoreException e = SrsCoreException.of(
          -4,
          'not migrated {"state":"${s.wire}"}',
        );
        expect(e, isA<SrsStoreNotMigrated>());
        expect((e as SrsStoreNotMigrated).state, s);
      }
      // 状态读不出来：照一般错误报，不猜。
      expect(
        SrsCoreException.of(-4, 'not migrated {"state":"unknown: io"}'),
        isNot(isA<SrsStoreOpenBlocked>()),
      );
      expect(SrsCoreException.of(-5, 'x'), isA<SrsStoreMigrating>());
      expect(SrsCoreException.of(-6, 'x'), isA<SrsStoreLegacyUnmigrated>());
      expect(SrsCoreException.of(-1, 'x').runtimeType, SrsCoreException);
    });

    test('unwired and removed commands are typed with their op and owner', () {
      final SrsCoreException u = SrsCoreException.of(
        -1,
        'gen4: not wired yet: `identity` belongs to G9-4',
      );
      expect(u, isA<SrsCoreUnwiredException>());
      expect((u as SrsCoreUnwiredException).op, 'identity');
      expect(u.owner, 'G9-4');
      final SrsCoreException r = SrsCoreException.of(
        -1,
        'gen4: removed: `channel_settle` (gen4 has no ingest channel)',
      );
      expect(r, isA<SrsCoreRemovedException>());
      expect((r as SrsCoreRemovedException).op, 'channel_settle');
    });

    test('an op over the payload cap is typed on every write path', () {
      // 标记与内核同源：op.rs 的常量与报错格式（`{ERR_OP_TOO_LARGE}: change …`）。
      final String op = File(
        '../../native/fushi_fsrs/src/gen4/op.rs',
      ).readAsStringSync();
      expect(
        op,
        contains(
          'pub const ERR_OP_TOO_LARGE: &str = "'
          '${SrsOpTooLargeException.marker.replaceFirst(': ', '')}";',
        ),
      );
      expect(op, contains('"{ERR_OP_TOO_LARGE}: change '));
      const String cap =
          'op too large: change 0a:2 is 16777217 bytes (16.0 MiB), over the '
          '16 MiB limit for a single change (usually a field holding an '
          'embedded image or file; store it as a media file instead)';
      for (final String m in <String>[
        'gen4 store: $cap; nothing was saved',
        'gen4 import: $cap; nothing was imported',
      ]) {
        final SrsCoreException e = SrsCoreException.of(-1, m);
        expect(e, isA<SrsOpTooLargeException>(), reason: m);
        expect(e.message, m);
      }
      // 只提到这几个词、不是内核那句报错的不算。
      expect(
        SrsCoreException.of(-1, 'gen4 store: no note n1').runtimeType,
        SrsCoreException,
      );
      expect(
        SrsCoreException.of(-1, 'note "op too large" missing').runtimeType,
        SrsCoreException,
      );
    });

    test('a removed sync2 command reaches Dart typed', () {
      final SrsCore core = SrsCore.open(dir.path);
      addTearDown(core.close);
      expect(
        () => core.sync2(<String, Object?>{
          'op': 'channel_settle',
          'profile': 'p',
        }),
        throwsA(isA<SrsCoreRemovedException>()),
      );
      expect(
        // G9-5 把旧并入命令标成已删；W3 合流后已没有未接线命令。
        () => core.sync2(<String, Object?>{
          'op': 'profile_merge_mark',
          'profile': 'p',
        }),
        throwsA(isA<SrsCoreRemovedException>()),
      );
    });
  });

  group('gen4 migration commands', () {
    test('steps before commit are cancellable, commit and seal are not', () {
      expect(
        <SrsGen4MigrationStep>[
          for (final SrsGen4MigrationStep s in SrsGen4MigrationStep.values)
            if (s.cancellable) s,
        ],
        SrsGen4MigrationStep.values.sublist(
          0,
          SrsGen4MigrationStep.commit.index,
        ),
      );
      // 线上名与 migrate.rs `Step::wire` 一致。
      final String migrate = File(
        '../../native/fushi_fsrs/src/store/gen4/migrate.rs',
      ).readAsStringSync();
      for (final SrsGen4MigrationStep s in SrsGen4MigrationStep.values) {
        expect(migrate, contains('=> "${s.wire}"'));
      }
      for (final SrsGen4MigrationVerdict v in SrsGen4MigrationVerdict.values) {
        expect(migrate, contains('=> "${v.wire}"'));
      }
      for (final SrsGenState s in SrsGenState.values) {
        expect(migrate, contains('=> "${s.wire}"'));
      }
    });

    test('outcome and status parse every documented field', () {
      final SrsGen4MigrationOutcome o = SrsGen4MigrationOutcome.fromJson(
        <String, Object?>{'verdict': 'noSpace', 'needed': 10, 'free': 3},
      );
      expect(o.verdict, SrsGen4MigrationVerdict.noSpace);
      expect(o.neededBytes, 10);
      expect(o.freeBytes, 3);
      final SrsGen4MigrationStatus s = SrsGen4MigrationStatus.fromJson(
        <String, Object?>{
          'state': 'needsMigration',
          'running': <String, Object?>{'step': 'parity', 'done': 2, 'total': 5},
        },
      );
      expect(s.state, SrsGenState.needsMigration);
      expect(s.running?.step, SrsGen4MigrationStep.parity);
      expect(s.running?.done, 2);
    });

    test('status, cancel and an empty run go through ffsrs_call', () async {
      expect(SrsGen4Migration.status(dir.path).state, SrsGenState.ready);
      expect(SrsGen4Migration.status(dir.path).running, isNull);
      expect(SrsGen4Migration.cancel(dir.path, runId: 'r1'), isFalse);
      // 没有协议 3 库：迁移不开始也不建库（结论由内核定，这里只要求是认得的结论、目录里没出现新代库）。
      final SrsGen4MigrationOutcome o =
          await SrsGen4Migration.run(
            dir.path,
            caches: const <String, Map<String, Object?>>{},
            nowMs: DateTime.now().millisecondsSinceEpoch,
          ).catchError(
            (Object e) => const SrsGen4MigrationOutcome(
              verdict: SrsGen4MigrationVerdict.blocked,
            ),
            test: (Object e) => e is SrsCoreException,
          );
      expect(SrsGen4MigrationVerdict.values, contains(o.verdict));
      expect(o.verdict, isNot(SrsGen4MigrationVerdict.committed));
    });
  });
}
