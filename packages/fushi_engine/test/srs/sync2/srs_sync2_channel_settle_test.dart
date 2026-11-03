// 新设备收段通道（native/fushi_fsrs/src/store/sync2/channel.rs）没做完时的本机写入：SrsDbStore 在开 Drift 事务
// 之前先发 `channel_settle`，内核按片做完（每片一个事务），不把整段塞进写入的那笔 Drift 事务。之后照常逐条投递，
// 结果与没插写入的设备收到的远端操作相同。
import 'dart:async';

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

  Future<SrsSync2Report> round(SrsDbStore s, SrsLocationStore loc) =>
      srsSync2Round(
        host: s,
        location: loc,
        locationId: 'loc',
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
      );

  Future<bool> channelInCore(SrsDbStore s) async =>
      (await s.sync2Command(<String, Object?>{
        'op': 'identity',
        'now': DateTime.now().millisecondsSinceEpoch,
      })).map['channel'] ==
      true;

  test('新设备首同步途中本机新建笔记：开事务前先按片做完通道，之后照常收完', () async {
    final SrsMemoryLocationStore loc = SrsMemoryLocationStore();
    final SrsDbStore a = await device('A');
    for (int i = 0; i < 30; i++) {
      final String n = await addNote(a, '語$i');
      await a.answer((await a.cardsOfNote(n)).first.id, 3);
    }
    expect((await round(a, loc)).error, isNull);

    final SrsDbStore b = await device('B');
    expect(b.debugChannelLive, isFalse);
    final List<bool> seen = <bool>[];
    Future<void>? wrote;
    b.debugOnIngestSlice = () {
      if (wrote != null) return;
      // 第一片投完：新设备在通道的追加阶段。钩子在独占区里，从根 zone 发起才是真的排队写入。
      seen.add(b.debugChannelLive);
      wrote = Zone.root.run(() async {
        await addNote(b, '途中');
        seen.add(b.debugChannelLive);
        seen.add(await channelInCore(b));
      });
    };
    final SrsSync2Report r = await round(b, loc);
    await wrote;
    expect(r.error, isNull);
    expect(seen, <bool>[true, false, false]);
    expect(await channelInCore(b), isFalse);

    // B 的笔记回到 A、两边再各同步一轮：两台设备的操作集合相同。
    expect((await round(a, loc)).error, isNull);
    expect((await round(b, loc)).error, isNull);
    final Set<String> idsA = <String>{
      for (final SrsEvent e in await a.exportAll()) e.id,
    };
    final Set<String> idsB = <String>{
      for (final SrsEvent e in await b.exportAll()) e.id,
    };
    expect(idsB, idsA);
  });
}
