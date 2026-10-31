// 内核列式读（store/bulk.rs）：统计指纹的订阅粒度、v13 出处列的升级回填、AnkiConnect 数字 id 反查、
// `cardColumns` 与逐行读同值。
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000c4';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;

  Future<(SrsDbStore, String, String)> seeded() async {
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'd',
      now: () => t,
    );
    final String deck = await s.ensureDeckPath('Deck');
    final String note = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '食べる',
      },
      deckId: deck,
      source: SrsSourceRef.book(
        bookKey: 'b',
        sectionIndex: 0,
        charStart: 0,
        title: '本',
      ),
    );
    return (s, deck, (await s.cardsOfNote(note)).single.id);
  }

  test('统计指纹：界面状态不推进，作答 / 暂停推进', () async {
    final (SrsDbStore s, String deck, String card) = await seeded();
    final String f0 = s.statsFingerprint;
    await s.setDeckCollapsed(deck, true);
    expect(s.statsFingerprint, f0, reason: '牌组收起不改变统计');
    t += 1000;
    await s.answer(card, 3);
    final String f1 = s.statsFingerprint;
    expect(f1, isNot(f0));
    await s.setSuspended(card, true);
    expect(s.statsFingerprint, isNot(f1));
    final SrsStatsBundle b = await loadSrsStats(s);
    expect(b.fingerprint, s.statsFingerprint);
  });

  test('缓存修订号 6 的老库：打开时补齐出处列，统计按出处分组', () async {
    final (SrsDbStore s, _, _) = await seeded();
    await s.db.customStatement(
      "UPDATE srs_notes_cache SET source_kind = '', source_title = ''",
    );
    await s.db.customStatement(
      "UPDATE srs_local_state SET json = json_set(json, '\$.cacheRev', 6)",
    );
    final SrsDbStore reopened = await SrsDbStore.open(
      db: s.db,
      core: s.core,
      profileUid: kProfile,
      deviceId: 'd',
      engine: const FakeFsrsEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        monotonicMs: () => t,
        bootId: 'boot-d',
      ),
      fallbackRolloverHour: () => 4,
    );
    final SrsStatsData d = (await loadSrsStats(reopened)).data;
    expect(
      d.sourceShares().map((SrsSourceShare x) => '${x.kind}/${x.title}'),
      <String>['${SrsSourceKind.book}/本'],
    );
    final String json =
        (await s.db
                .customSelect('SELECT json FROM srs_local_state')
                .getSingle())
            .read<String>('json');
    expect((jsonDecode(json) as Map)['cacheRev'], 8);
  });

  test(
    'AnkiConnect 数字 id 由内核按 anki_id 列反查，与 SrsIds.ankiNumericId 同值',
    () async {
      final (SrsDbStore s, _, String card) = await seeded();
      final String note = (await s.cardRow(card))!.noteId;
      final int nn = SrsIds.ankiNumericId(note);
      final int cn = SrsIds.ankiNumericId(card);
      expect(await s.noteIdForAnkiNumericId(nn), note);
      expect(await s.cardIdForAnkiNumericId(cn), card);
      expect(await s.noteIdsForAnkiNumericIds(<int>[cn, nn, 1]), <String?>[
        null,
        note,
        null,
      ]);
      expect(await s.cardIdsForAnkiNumericIds(const <int>[]), isEmpty);
    },
  );

  test('cardColumns 与 allCardRows 同值；fields / visibleOnly 限定', () async {
    final (SrsDbStore s, _, String card) = await seeded();
    t += 1000;
    await s.answer(card, 4);
    final List<SrsCardCacheRow> rows = await s.allCardRows();
    final List<SrsCardCacheRow> drift = await (s.db.select(
      s.db.srsCardsCache,
    )..where((c) => c.profileUid.equals(kProfile))).get();
    expect(rows, drift);
    final SrsColumns ids = await s.cardColumns(
      fields: const <String>['id'],
      visibleOnly: true,
    );
    expect(ids.has('deck_id'), isFalse);
    expect(ids.strings('id').toList(), <String>[card]);
  });
}
