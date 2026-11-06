// 字段修改历史（docs/specs/2026-10-25-srs-sync-v2-design.md §10.2）：被后来的修改覆盖掉的那条也列得出来，
// 新的在前；另一台设备同步后看到同样的历史，写入者是原设备。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_edit_history.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_sync2_peers.dart';
import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000e2';

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

  test('覆盖掉的修改也在历史里，另一台设备看到同样的历史', () async {
    final SrsDbStore a = await device('A');
    final SrsDbStore b = await device('B');
    final String field = srsLapisFieldId(kProfile, 'Expression');
    final String note = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: <String, String>{field: '一'},
    );
    await a.updateNote(note, fieldsById: <String, String>{field: '二'});
    await a.updateNote(note, fieldsById: <String, String>{field: '三'});
    final List<SrsHistoryEntry> h = await a.editHistory(
      SrsEntityKind.note,
      note,
    );
    final List<Object?> values = <Object?>[
      for (final SrsHistoryEntry e in h)
        if (e.key == SrsFieldKeys.noteField(field)) e.value,
    ];
    expect(values, <Object?>['三', '二', '一']);
    expect(h.first.writer, a.sync2Device);

    await srsSyncPeers(<SrsDbStore>[a, b], SrsMemoryLocationStore());
    final List<SrsHistoryEntry> hb = await b.editHistory(
      SrsEntityKind.note,
      note,
    );
    expect(<Object?>[
      for (final SrsHistoryEntry e in hb)
        if (e.key == SrsFieldKeys.noteField(field)) e.value,
    ], values);
    expect(
      hb
          .where((SrsHistoryEntry e) => e.key == SrsFieldKeys.noteField(field))
          .first
          .writer,
      a.sync2Device,
    );
  });
}
