// 真实新设备第一次同步（BUG-4478 的场景，新代）：`SrsDbStore.open` 在任何同步之前就写下内置身份记录（默认牌组 +
// 内置笔记类型，`ensureBuiltins`），A 改过内置牌组与内置笔记类型的名字、删过笔记、答过卡并已同步。B 是新装的：第一次
// 同步就收齐 A 的全部改动（含对内置实体的改动与删除），之后两边摘要相同、照常互相同步。
//
// 以前这里测的是协议 3 的收段通道（`store/sync2/channel.rs`，先追加后折叠，`sync2_boot*` 表）：新代没有收段通道（收段
// 即落真相，交接 §「命令对照」`ingest_begin` 已删），只测通道机制的两条随之删掉，收敛的断言留在这里。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000b7';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> device(String id) async {
    final SrsStorage st = await openTestSrsStorage();
    return SrsDbStore.open(
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

  Future<SrsSync2Report> round(SrsDbStore s, SrsLocationStore loc) =>
      srsSync2Round(
        host: s,
        location: loc,
        locationId: 'loc',
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
      );

  test('真实新设备（开库已写内置实体）第一次同步：收齐 A 对内置实体的改动与删除，收敛后照常同步', () async {
    final SrsLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await device('A');
    final List<String> notes = <String>[
      for (int i = 0; i < 24; i++) await addNote(a, '語$i'),
    ];
    for (final String n in notes.take(16)) {
      await a.answer((await a.cardsOfNote(n)).first.id, 3);
    }
    await a.editField(
      SrsEntityKind.deck,
      a.defaultDeckId,
      SrsFieldKeys.name,
      'Mine',
    );
    await a.editField(
      SrsEntityKind.noteType,
      a.lapisNoteTypeId,
      SrsFieldKeys.name,
      'My Lapis',
    );
    await a.deleteNote(notes.last);
    expect((await round(a, loc)).error, isNull);

    final SrsDbStore b = await device('B');
    final SrsSync2Report r = await round(b, loc);
    expect(r.error, isNull);
    expect(r.applied, greaterThan(50));

    // B 看到 A 的数据，包括 A 对内置实体的改动与删除。
    expect(await b.note(notes.first), isNotNull);
    expect((await b.deckTree())[b.defaultDeckId]?.name, 'Mine');
    expect((await b.noteType(b.lapisNoteTypeId))?.name, 'My Lapis');
    expect(
      (await b.note(notes.last))?.deletedAt,
      (await a.note(notes.last))?.deletedAt,
    );
    final String card = (await a.cardsOfNote(notes.first)).first.id;
    expect(
      srsCanonicalJson((await b.history(card)).state.toJson()),
      srsCanonicalJson((await a.history(card)).state.toJson()),
    );

    // A 收下 B 的内置身份记录（与自己的同 ID 同内容）之后，两边摘要相同。
    expect((await round(a, loc)).error, isNull);
    expect((await round(b, loc)).error, isNull);
    expect(
      (await b.sync2Digest())['digest'],
      (await a.sync2Digest())['digest'],
    );
    expect((await b.sync2Status())['pending'], 0);

    // 之后本机照常写、照常同步。
    final String mine = await addNote(b, '後');
    expect((await round(b, loc)).error, isNull);
    expect((await round(a, loc)).error, isNull);
    expect(await a.note(mine), isNotNull);
    expect(
      (await b.sync2Digest())['digest'],
      (await a.sync2Digest())['digest'],
    );
  });
}
