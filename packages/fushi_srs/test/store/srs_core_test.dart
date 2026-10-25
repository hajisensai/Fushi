import 'dart:io';
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
}
