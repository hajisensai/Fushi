import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('srs_core_test'));
  tearDown(() => dir.deleteSync(recursive: true));

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

  test('open, legacy import, snapshot and debug query', () {
    final String path = '${dir.path}${Platform.pathSeparator}srs.db';
    final SrsCore core = SrsCore.open(path);
    addTearDown(core.close);
    expect(core.legacyImported, isFalse);

    core.legacyBegin();
    core.legacyPage(
      'srs_unknown_events',
      srsEncodeRows(3, <List<Object?>>[
        <Object?>['e1', 'p', '{"k":"あ"}'],
      ]),
    );
    core.legacyPage(
      'srs_sent_batches',
      srsEncodeRows(4, <List<Object?>>[
        <Object?>[
          'p',
          'w',
          1,
          Uint8List.fromList(<int>[1, 2, 3]),
        ],
      ]),
    );
    expect(
      () => core.legacyPage('srs_nope', srsEncodeRows(0, <List<Object?>>[])),
      throwsA(isA<SrsCoreException>()),
    );
    core.legacyCommit();
    expect(core.legacyImported, isTrue);

    expect(
      core.debugQuery(
        'SELECT id, json FROM srs_unknown_events WHERE id = ?',
        <Object?>['e1'],
      ),
      <Map<String, Object?>>[
        <String, Object?>{'id': 'e1', 'json': '{"k":"あ"}'},
      ],
    );
    expect(
      () => core.debugQuery('DELETE FROM srs_unknown_events'),
      throwsA(isA<SrsCoreException>()),
    );

    final String snap = '${dir.path}${Platform.pathSeparator}snap.db';
    core.snapshotInto(snap, stripDeviceLocal: true);
    final SrsCore s = SrsCore.open(snap);
    addTearDown(s.close);
    expect(
      s.debugQuery('SELECT COUNT(*) AS n FROM srs_sent_batches'),
      <Map<String, Object?>>[
        <String, Object?>{'n': 0},
      ],
    );
    expect(
      s.debugQuery('SELECT COUNT(*) AS n FROM srs_unknown_events'),
      <Map<String, Object?>>[
        <String, Object?>{'n': 1},
      ],
    );
    expect(s.legacyImported, isFalse);
  });

  test('a borrowed handle does not close the owner', () {
    final SrsCore core = SrsCore.open(
      '${dir.path}${Platform.pathSeparator}srs.db',
    );
    final SrsCore borrowed = SrsCore.fromAddress(
      core.address,
      libraryPath: core.libraryPath,
    );
    borrowed.close();
    expect(core.legacyImported, isFalse);
    core.close();
    expect(() => core.legacyImported, throwsStateError);
  });

  // 3.1.0 安卓白屏：app 打开 srs.db（含整表重建的格式升级）必须在后台 isolate，句柄回到调用方并归它拥有。
  test('openInBackground hands the caller an owned, usable handle', () async {
    final String path = '${dir.path}${Platform.pathSeparator}srs.db';
    final SrsCore core = await SrsCore.openInBackground(path);
    expect(core.owned, isTrue);
    expect(core.legacyImported, isFalse);
    expect(core.debugQuery('SELECT 1 AS one').single['one'], 1);
    core.close();
    expect(() => core.legacyImported, throwsStateError);
    // 关闭返回时库文件已没有打开的句柄（后台 isolate 没留下第二个拥有者）。
    File(path).deleteSync();
  });

  test('openInBackground rethrows the open failure as SrsCoreException', () {
    // 路径是个目录：SQLite 打不开。错误要以原类型回到调用方（打开页按类型区分「空间不够」等）。
    expect(
      SrsCore.openInBackground(dir.path),
      throwsA(isA<SrsCoreException>()),
    );
  });

  // 回归（2026-10-25 CI SIGABRT）：拥有者关库时，后台 isolate 经 fromAddress 拿着同一个句柄还在
  // 跑命令。原来 ffsrs_store_close 直接释放结构体，那边 use-after-free（`free(): invalid
  // pointer`）。现在关闭等在途命令跑完；之后经旧地址的命令报「已关闭」而不是崩。
  test('closing while a worker isolate uses the handle neither crashes nor '
      'leaves the address dangling', () async {
    final String path = '${dir.path}${Platform.pathSeparator}srs.db';
    final SrsCore core = SrsCore.open(path);
    final int address = core.address;
    final String? libraryPath = core.libraryPath;

    // 一条足够慢的只读查询，让关闭大概率落在它执行期间（落在之前 / 之后也必须同样不崩）。
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

    // 关闭之后，别的 isolate 手上的旧地址仍是有效的（已关闭的）句柄。
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
    // 关闭返回时库文件已没有打开的句柄（覆盖恢复要删换 srs.db）。
    File(path).deleteSync();
  });

  // ID 列存 16 字节 BLOB（schema v17）：Dart 原生 SQL 里拼 / 绑 ID 必须过 `srs_id()`，漏了查不到也写错形状。
  // 审计只在 `--features id_audit` 构建的库里装（native/fushi_fsrs/src/store/ids.rs `audit`）；CI 的 Dart 单测
  // 库就是这么编的，并设 FUSHI_FSRS_ID_AUDIT=1——这条金丝雀钉住「审计真的开着」，库被换成不带审计的构建就红，
  // 否则整套 SRS 测试会在没有审计的情况下静默变绿。
  test(
    'the id audit is live in audited builds',
    () {
      final SrsCore core = SrsCore.open(
        '${dir.path}${Platform.pathSeparator}srs.db',
      );
      addTearDown(core.close);
      const String uuid = '0193a1b2-0005-7000-8000-00000000ffff';
      expect(
        () => core.execQuery(
          "SELECT COUNT(*) FROM srs_review_logs WHERE id = '$uuid'",
          const <Object?>[],
        ),
        throwsA(
          isA<SrsCoreException>().having(
            (SrsCoreException e) => e.message,
            'message',
            contains('id audit'),
          ),
        ),
      );
      final (int _, List<List<Object?>> rows) = srsDecodeRows(
        core.execQuery(
          'SELECT COUNT(*) AS n FROM srs_review_logs WHERE id = srs_id(?)',
          const <Object?>[uuid],
        ),
      );
      expect(rows[1], <Object?>[0]);
    },
    skip: Platform.environment['FUSHI_FSRS_ID_AUDIT'] == '1'
        ? false
        : 'needs a fushi_fsrs built with --features id_audit '
              '(FUSHI_FSRS_ID_AUDIT=1)',
  );

  test('an upgrade refused for disk space surfaces as a typed, readable error', () {
    // 与 Rust 侧同一份契约：状态码 store/ffi.rs STORE_NO_SPACE、前缀 store/schema.rs UPGRADE_NO_SPACE。
    final String ffi = File(
      '../../native/fushi_fsrs/src/store/ffi.rs',
    ).readAsStringSync();
    final String schema = File(
      '../../native/fushi_fsrs/src/store/schema.rs',
    ).readAsStringSync();
    expect(
      ffi,
      contains(
        'pub const STORE_NO_SPACE: i32 = ${SrsUpgradeNoSpaceException.statusCode};',
      ),
    );
    expect(
      schema,
      contains(
        'pub const UPGRADE_NO_SPACE: &str = "${SrsUpgradeNoSpaceException.prefix}";',
      ),
    );
    final SrsUpgradeNoSpaceException? e = SrsUpgradeNoSpaceException.tryParse(
      -3,
      '${SrsUpgradeNoSpaceException.prefix}'
      '{"need":209715200,"free":1048576,"from":8,"to":18}',
    );
    expect(e, isNotNull);
    expect(e!.neededBytes, 209715200);
    expect(e.freeBytes, 1048576);
    expect(e, isA<SrsCoreException>());
    expect('$e', contains('209715200'));
    // 别的状态码 / 形状不对：照一般错误报。
    expect(
      SrsUpgradeNoSpaceException.tryParse(
        -1,
        '${SrsUpgradeNoSpaceException.prefix}{"need":1,"free":0}',
      ),
      isNull,
    );
    expect(
      SrsUpgradeNoSpaceException.tryParse(
        -3,
        '${SrsUpgradeNoSpaceException.prefix}oops',
      ),
      isNull,
    );
  });
}
