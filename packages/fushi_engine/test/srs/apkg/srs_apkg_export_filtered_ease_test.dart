// 普通 Anki 导出：Anki 筛选牌组里的复习（revlog.type 3，ease 1–4）往返后保留原评分。
//
// 导出以前只认 learn / review / relearn 为评分复习，type 3 被写成 ease 0（Anki 里 ease 0 = 手动改期），
// Anki → Fushi → Anki 往返丢评分。现在普通导出与捐赠包共用一条规则：kind=review 的行写真实评分。
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/apkg/srs_anki_package.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_export.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000001';

int ms(int y, int m, int d, [int h = 0]) =>
    DateTime.utc(y, m, d, h).millisecondsSinceEpoch;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final int rLearn = ms(2026, 9, 1, 10);
  final int rFiltered = ms(2026, 9, 2, 10);
  final int rFilteredZero = ms(2026, 9, 3, 10);
  final int rManual = ms(2026, 9, 4, 10);

  Uint8List apkg() => zipOf(<String, List<int>>{
    'collection.anki21': buildLegacyCollection(
      crtSecs: ms(2026, 1, 1, 4) ~/ 1000,
      conf: <String, Object?>{'rollover': 4, 'localOffset': 0},
      models: <String, Object?>{
        '77': <String, Object?>{
          'id': 77,
          'name': 'Basic',
          'type': 0,
          'css': '',
          'flds': <Object?>[
            <String, Object?>{'name': 'Front', 'ord': 0},
            <String, Object?>{'name': 'Back', 'ord': 1},
          ],
          'tmpls': <Object?>[
            <String, Object?>{
              'name': 'Card 1',
              'ord': 0,
              'qfmt': '{{Front}}',
              'afmt': '{{Back}}',
            },
          ],
        },
      },
      decks: <String, Object?>{
        '1': <String, Object?>{'id': 1, 'name': 'Default', 'dyn': 0, 'conf': 1},
      },
      dconf: <String, Object?>{
        '1': <String, Object?>{'id': 1, 'name': 'Default'},
      },
      notes: <FxNote>[
        FxNote(
          id: ms(2026, 8, 1),
          guid: 'g0',
          mid: 77,
          fields: <String>['犬', 'dog'],
          cards: <FxCard>[
            FxCard(
              id: 100,
              ord: 0,
              did: 1,
              type: 2,
              queue: 2,
              due: 300,
              ivl: 4,
              factor: 2500,
              reps: 3,
              revlog: <FxRevlog>[
                FxRevlog(rLearn, type: 0, ease: 3, ivl: 1),
                FxRevlog(rFiltered, type: 3, ease: 2, ivl: 4),
                FxRevlog(rFilteredZero, type: 3, ease: 0, ivl: 4),
                FxRevlog(rManual, type: 4, ease: 0, ivl: 9),
              ],
            ),
          ],
        ),
      ],
    ),
    'media': utf8.encode('{}'),
  });

  test('Anki → Fushi → Anki：筛选牌组复习保留评分，手动 / ease 0 仍写 0', () async {
    final int now = ms(2026, 10, 14, 12);
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => now,
    );
    await importAnkiPackage(
      store: s,
      bytes: apkg(),
      storeMedia: (String n, Uint8List b) async => 'h_$n',
      options: const SrsAnkiImportOptions(
        withScheduling: true,
        withDeckConfigs: true,
      ),
      zstdDecompress: (Uint8List b) => null,
    );
    final Uint8List out = await exportAnkiPackage(store: s);
    final SrsAnkiPackage p = SrsAnkiPackage.open(
      out,
      zstd: (Uint8List b) => null,
    );
    final SrsAnkiCollection col = await SrsAnkiCollection.open(
      p.collectionBytes,
    );
    try {
      final Map<int, (int, int)> rev = <int, (int, int)>{
        for (final Row r in col.db.select('SELECT id, type, ease FROM revlog'))
          r['id'] as int: (r['type'] as int, r['ease'] as int),
      };
      expect(rev[rLearn], (0, 3));
      expect(rev[rFiltered], (3, 2), reason: '筛选牌组复习的评分不能丢成 ease 0');
      expect(rev[rFilteredZero], (3, 0));
      expect(rev[rManual]?.$2, 0);
    } finally {
      await col.close();
    }
  });
}
