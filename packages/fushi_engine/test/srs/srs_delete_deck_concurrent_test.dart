import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000a3';

/// 删牌组分块移卡，块与块之间别的写入照常插进来（后台导入、建子牌组）。收尾写删除标记前必须在
/// 同一个独占区里重读子树与子树里的卡：否则分块期间放进来的卡 / 建的子牌组会留在已删除的牌组下。
void main() {
  int t = DateTime.utc(2026, 10, 19, 12).millisecondsSinceEpoch;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> device() =>
      openTestStore(profileUid: kProfile, deviceId: 'a', now: () => t);

  Map<String, String> lapis(String word) => <String, String>{
    srsLapisFieldId(kProfile, 'Expression'): word,
  };

  test('cards and child decks added while a deck is being deleted are moved '
      'and tombstoned too', () async {
    final SrsDbStore s = await device();
    final String old = await s.createDeck('Old');
    final String parentNote = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: lapis('一'),
      deckId: old,
    );

    // 删除开始后（读完卡片清单、第一块之前）插进来的写入：建子牌组、往牌组里加卡。
    Future<String>? childDeck;
    Future<String>? lateNote;
    await s.deleteDeck(
      old,
      onProgress: (int done, int total) {
        if (done == 0) {
          childDeck = s.createDeck('Late child', parentId: old);
          lateNote = s.createNote(
            noteTypeId: s.lapisNoteTypeId,
            fieldsById: lapis('二'),
            deckId: old,
          );
        }
      },
    );
    final String child = await childDeck!;
    final String late = await lateNote!;

    final SrsDeckTree tree = await s.deckTree();
    expect(tree[old], isNull, reason: '牌组已删');
    expect(tree[child], isNull, reason: '删除期间建的子牌组也随子树删掉');
    for (final String note in <String>[parentNote, late]) {
      for (final SrsCardCacheRow c in await s.cardsOfNote(note)) {
        expect(c.deckId, s.defaultDeckId, reason: '删除期间放进来的卡也移出了已删除的牌组');
      }
    }
  });
}
