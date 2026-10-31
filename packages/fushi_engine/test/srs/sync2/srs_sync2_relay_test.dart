// 同步 v2 的段 / head 转发（审查 S-1，内核 store/sync2/relay.rs）：A ↔ B 只经互联、B ↔ C 只经网盘，
// C 照样收齐 A 的操作（以前永远收不到，B 此后的操作在 C 的因果缓冲里无界堆积），反方向同样；网盘加密时转发件
// 用网盘的密钥封装。
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000ee';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
      engine: FfiFsrsEngine.tryCreate(),
    );
  }

  Future<String> addNote(SrsDbStore s, String expression) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(kProfile, 'Expression'): expression,
    },
  );

  Future<SrsSync2Report> round(SrsDbStore s, SrsLocationStore loc, String id) =>
      srsSync2Round(
        host: s,
        location: loc,
        locationId: id,
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
      );

  test('A↔B 只经互联、B↔C 只经网盘：C 收齐 A 的操作，A 收齐 C 的', () async {
    final SrsMemoryLocationStore ic = SrsMemoryLocationStore();
    final SrsMemoryLocationStore cloud = SrsMemoryLocationStore();
    final SrsDbStore a = await device('A');
    final SrsDbStore b = await device('B');
    final SrsDbStore c = await device('C');
    Future<void> laps(int n) async {
      for (int i = 0; i < n; i++) {
        await round(a, ic, 'ic');
        await round(b, ic, 'ic');
        await round(b, cloud, 'cloud');
        await round(c, cloud, 'cloud');
      }
    }

    final String fromA = await addNote(a, '雪');
    await laps(3);
    expect(await c.note(fromA), isNotNull, reason: 'C got A\'s note by relay');
    final String card = (await a.cardsOfNote(fromA)).first.id;
    await a.answer(card, 3);
    final String fromC = await addNote(c, '雨');
    await laps(4);
    expect(await a.note(fromC), isNotNull, reason: 'A got C\'s note by relay');
    expect((await c.history(card)).effective.length, 1);
    for (final SrsDbStore s in <SrsDbStore>[a, b, c]) {
      expect((await s.sync2Status())['pending'], 0);
    }
    expect(
      (await a.sync2Digest())['digest'],
      (await c.sync2Digest())['digest'],
    );
    // A 从没连过网盘：它在网盘上只有转发件（作者签名原样），没有自己写的段。
    final String aId =
        (await a.sync2Command(<String, Object?>{
              'op': 'identity',
              'now': 0,
            })).map['device']!
            as String;
    final Iterable<String> aFiles = cloud.files.keys.where(
      (String k) => k.startsWith('devices/$aId/'),
    );
    expect(aFiles.where((String k) => k.contains('/rly-')), isNotEmpty);
    expect(aFiles.where((String k) => k.contains('/seg-')), isEmpty);
    final Uint8List envelope =
        cloud.files[aFiles.firstWhere((String k) => k.contains('/rly-'))]!;
    expect(String.fromCharCodes(envelope.sublist(0, 4)), 'FSRL');
  });

  test('段文件名与转发件名一一对应', () {
    expect(
      srsRelayPath('devices/x/seg-000000000001-000000000002-abcdef01.bin'),
      'devices/x/rly-000000000001-000000000002-abcdef01.bin',
    );
    expect(
      srsRelayPath('devices/x/head-000000000001-abcdef01.json'),
      'devices/x/head-000000000001-abcdef01.json',
    );
  });
}
