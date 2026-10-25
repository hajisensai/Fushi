// 手动导出 / 导入 `.fushisrs`（sync2/srs_fushisrs.dart，docs/specs/2026-10-25-srs-sync-v2-design.md §10.4）：
// 导出到文件、在另一台设备导入后笔记 / 复习 / 媒体都到齐；导入是并入（不覆盖本机）、幂等；别的 profile 的包拒收；
// 导入前自动打还原点；导入后两台设备照常经同步位置收敛。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_fushisrs.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/srs_fake_engine.dart';
import '../support/srs_sync2_peers.dart';
import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000f1';
const String kOtherProfile = '01928c3e-0000-7000-8000-0000000000f2';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  int t = DateTime.utc(2026, 10, 25, 9).millisecondsSinceEpoch;

  setUp(() {
    t = DateTime.utc(2026, 10, 25, 9).millisecondsSinceEpoch;
    tmp = Directory.systemTemp.createTempSync('srs_fushisrs_');
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄滞后（Windows）：留给系统清理。
    }
  });

  Future<SrsDbStore> device(String id, {String profile = kProfile}) async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: profile,
      deviceId: id,
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        monotonicMs: () => t,
        bootId: 'boot-$id',
      ),
    );
  }

  Directory dir(String name) =>
      Directory(p.join(tmp.path, name))..createSync(recursive: true);

  String expr(SrsDbStore s) => srsLapisFieldId(s.profileUid, 'Expression');

  Future<String> addNote(SrsDbStore s, String text, {String picture = ''}) {
    t += 1000;
    return s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        expr(s): text,
        srsLapisFieldId(s.profileUid, 'Picture'): picture,
      },
    );
  }

  Future<int> noteCount(SrsDbStore s) async =>
      (await s.entityIds(SrsEntityKind.note)).length;

  test('导出 → 另一台设备导入：笔记、复习、媒体到齐；再导入一次什么也不变', () async {
    final SrsDbStore a = await device('a');
    final Directory mediaA = dir('media_a');
    File(p.join(mediaA.path, 'cat.png')).writeAsBytesSync(<int>[1, 2, 3]);
    final String n = await addNote(a, '猫', picture: '<img src="cat.png">');
    final String card = (await a.cardsOfNote(n)).single.id;
    t += 60 * 1000;
    await a.answer(card, 3);
    final File pkg = File(p.join(tmp.path, 'out', 'a.$kSrsFushiSrsExtension'));
    final SrsFushiSrsExport exp = await srsExportFushiSrs(
      a,
      pkg,
      mediaRoot: mediaA,
    );
    expect(pkg.existsSync(), isTrue);
    expect(exp.bytes, pkg.lengthSync());
    expect(exp.mediaFiles, 1);

    final SrsDbStore b = await device('b');
    final Directory mediaB = dir('media_b');
    final String own = await addNote(b, '犬');
    final SrsFushiSrsImport imp = await srsImportFushiSrs(
      b,
      pkg,
      mediaRoot: mediaB,
    );
    expect(imp.applied, greaterThan(0));
    expect(imp.mediaFiles, 1);
    expect((await b.note(n))!.field(expr(b)), '猫');
    expect((await b.note(own))!.field(expr(b)), '犬', reason: '并入，不覆盖本机');
    expect((await b.history(card)).effective, hasLength(1));
    expect(
      srsCanonicalJson((await b.history(card)).state.toJson()),
      srsCanonicalJson((await a.history(card)).state.toJson()),
    );
    expect(File(p.join(mediaB.path, 'cat.png')).readAsBytesSync(), <int>[
      1,
      2,
      3,
    ]);
    expect(
      <String>[
        for (final Map<String, Object?> c in await b.sync2Checkpoints())
          '${c['reason']}',
      ],
      contains('import'),
      reason: '导入前自动打还原点',
    );

    // 幂等：同一个包再导一次，不并入任何操作、不补媒体、笔记数不变。
    final int notes = await noteCount(b);
    final SrsFushiSrsImport again = await srsImportFushiSrs(
      b,
      pkg,
      mediaRoot: mediaB,
    );
    expect(again.applied, 0);
    expect(again.mediaFiles, 0);
    expect(await noteCount(b), notes);

    // 导入后两台设备照常经同步位置收敛（导进来的操作不会被当成新的再造一份）。
    await srsSyncPeers(<SrsDbStore>[a, b], SrsMemoryLocationStore());
    expect((await a.note(own))!.field(expr(a)), '犬');
    expect(await noteCount(a), await noteCount(b));
    expect(
      (await a.sync2Digest())['digest'],
      (await b.sync2Digest())['digest'],
    );
  });

  test('不带媒体导出：包里没有媒体，导入只并操作', () async {
    final SrsDbStore a = await device('a');
    final Directory mediaA = dir('media_a');
    File(p.join(mediaA.path, 'cat.png')).writeAsBytesSync(<int>[1]);
    final String n = await addNote(a, '猫', picture: '<img src="cat.png">');
    final File pkg = File(p.join(tmp.path, 'a.$kSrsFushiSrsExtension'));
    expect(
      (await srsExportFushiSrs(
        a,
        pkg,
        mediaRoot: mediaA,
        withMedia: false,
      )).mediaFiles,
      0,
    );
    final SrsDbStore b = await device('b');
    final Directory mediaB = dir('media_b');
    final SrsFushiSrsImport imp = await srsImportFushiSrs(
      b,
      pkg,
      mediaRoot: mediaB,
    );
    expect(imp.mediaFiles, 0);
    expect(await b.note(n), isNotNull);
    expect(File(p.join(mediaB.path, 'cat.png')).existsSync(), isFalse);
  });

  test('别的 profile 的包拒收，本机什么也不变；不是 .fushisrs 的文件也拒收', () async {
    final SrsDbStore other = await device('x', profile: kOtherProfile);
    await addNote(other, '雪');
    final File pkg = File(p.join(tmp.path, 'x.$kSrsFushiSrsExtension'));
    await srsExportFushiSrs(other, pkg);

    final SrsDbStore b = await device('b');
    final int notes = await noteCount(b);
    final Object? ops = (await b.sync2Status())['ops'];
    await expectLater(srsImportFushiSrs(b, pkg), throwsFormatException);
    expect(await noteCount(b), notes);
    expect((await b.sync2Status())['ops'], ops, reason: '拒收前不打还原点、不并入');

    final File junk = File(p.join(tmp.path, 'junk.$kSrsFushiSrsExtension'))
      ..writeAsBytesSync(<int>[
        0x50,
        0x4b,
        0x05,
        0x06,
        ...List<int>.filled(18, 0),
      ]);
    await expectLater(srsImportFushiSrs(b, junk), throwsFormatException);
  });
}
