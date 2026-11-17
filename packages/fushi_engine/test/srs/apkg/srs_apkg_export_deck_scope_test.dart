// 按牌组导出 .apkg（拍板台 5h2vW-kVi3：牌组菜单「导出此牌组」）：
// - 范围是所选牌组的子树，兄弟牌组的笔记不进包；
// - 祖先牌组随包导出（全名「父::子」不丢，同 Anki gather_decks 补父牌组）；
// - 子牌组继承的参数组归属子树外的父牌组时，包里子牌组的 conf 指向父牌组那份预设，
//   导回另一份库后子牌组仍继承到同样的参数。
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/apkg/srs_anki_package.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_export.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'apkg_test_support.dart';
import 'srs_apkg_import_test.dart' show kFullOptions;

const String kProfile = '01928c3e-0000-7000-8000-000000000001';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final int t = DateTime.utc(2026, 11, 16, 12).millisecondsSinceEpoch;

  Future<String> note(SrsDbStore s, String expr, String deckId) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(s.profileUid, 'Expression'): expr,
    },
    deckId: deckId,
  );

  Future<Map<String, Object?>> colJson(Uint8List pkg, String column) async {
    final SrsAnkiPackage p = SrsAnkiPackage.open(
      pkg,
      zstd: (Uint8List b) => null,
    );
    final SrsAnkiCollection col = await SrsAnkiCollection.open(
      p.collectionBytes,
    );
    try {
      final Database db = col.db;
      return (jsonDecode(
                db.select('SELECT $column FROM col').single[column] as String,
              )
              as Map)
          .cast<String, Object?>();
    } finally {
      await col.close();
    }
  }

  test('导出子牌组：只含子树的笔记，带上祖先全名与父牌组预设，导回后继承不变', () async {
    final SrsDbStore a = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    final String jp = await a.createDeck('JP');
    final String n5 = await a.createDeck('N5', parentId: jp);
    final String other = await a.createDeck('Other');
    await a.editFields(SrsEntityKind.deck, jp, <String, Object?>{
      SrsFieldKeys.deckParamsMode: 'own',
      SrsFieldKeys.deckRetention: 0.8,
    });
    await a.editFields(SrsEntityKind.deck, n5, <String, Object?>{
      SrsFieldKeys.deckParamsMode: 'inherit',
    });
    expect((await a.deckTree()).paramsOwner(n5).id, jp);
    await note(a, '雪', n5);
    await note(a, '雨', jp);
    await note(a, '風', other);

    final Uint8List pkg = await exportAnkiPackage(store: a, deckId: n5);

    final Map<String, Object?> decks = await colJson(pkg, 'decks');
    final Map<String, Map<String, Object?>> byName =
        <String, Map<String, Object?>>{
          for (final Object? d in decks.values)
            ((d! as Map)['name']! as String): (d as Map)
                .cast<String, Object?>(),
        };
    expect(byName.keys.toSet(), <String>{'Default', 'JP', 'JP::N5'});
    final int jpConf = byName['JP']!['conf']! as int;
    expect(byName['JP::N5']!['conf'], jpConf, reason: '继承的子牌组用父牌组那份预设');
    final Map<String, Object?> dconf = await colJson(pkg, 'dconf');
    expect(
      ((dconf['$jpConf']! as Map)['desiredRetention']! as num).toDouble(),
      closeTo(0.8, 1e-9),
    );

    final SrsDbStore b = await openTestStore(
      profileUid: '01928c3e-0000-7000-8000-0000000000ee',
      deviceId: 'b',
      now: () => t,
    );
    final SrsImportReport rep = await importAnkiPackage(
      store: b,
      bytes: pkg,
      options: kFullOptions,
      storeMedia: (String name, Uint8List bytes) async => name,
    );
    expect(rep.notesAdded, 1, reason: '只有 JP::N5 里那一条，父牌组和兄弟牌组的笔记不进包');
    final SrsDeckTree tree = await b.deckTree();
    final String n5b = tree.decks
        .firstWhere((SrsDeckView d) => tree.fullName(d.id) == 'JP::N5')
        .id;
    expect(tree.paramsOwner(n5b).desiredRetention, closeTo(0.8, 1e-9));
  });

  test('导出顶层牌组包含整棵子树', () async {
    final SrsDbStore a = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    final String jp = await a.createDeck('JP');
    final String n5 = await a.createDeck('N5', parentId: jp);
    final String other = await a.createDeck('Other');
    await note(a, '雪', n5);
    await note(a, '雨', jp);
    await note(a, '風', other);

    final Uint8List pkg = await exportAnkiPackage(store: a, deckId: jp);
    final Map<String, Object?> decks = await colJson(pkg, 'decks');
    expect(
      decks.values.map((Object? d) => (d! as Map)['name']).toSet(),
      <String>{'Default', 'JP', 'JP::N5'},
    );
    final SrsDbStore b = await openTestStore(
      profileUid: '01928c3e-0000-7000-8000-0000000000ee',
      deviceId: 'b',
      now: () => t,
    );
    final SrsImportReport rep = await importAnkiPackage(
      store: b,
      bytes: pkg,
      options: kFullOptions,
      storeMedia: (String name, Uint8List bytes) async => name,
    );
    expect(rep.notesAdded, 2);
  });
}
