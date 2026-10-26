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
}
