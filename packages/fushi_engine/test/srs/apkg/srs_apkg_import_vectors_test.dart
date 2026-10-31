// Anki 包导入的结果向量：笔记 / 卡片缓存行 / 复习日志 / 牌组 / 笔记类型 / 导入报告逐项比对固定的向量文件。
//
// 向量由按笔记逐条查卡、逐卡查 revlog 的旧读法生成（改成三条游标归并之前）；新读法必须逐项一致。来源库
// 都不带 ix_cards_nid / ix_revlog_cid，卡片 id 与 ord 反序、revlog 跨卡交错、有孤儿卡与孤儿 revlog，
// 归并的每条分支都走得到。
//
// 重新生成（只在有意改变导入结果时）：
//   FUSHI_APKG_VECTORS_WRITE=1 dart test test/srs/apkg/srs_apkg_import_vectors_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'apkg_test_support.dart';
import 'srs_apkg_import_bench_test.dart' show benchApkg;
import 'srs_apkg_import_test.dart'
    show
        crtSecs,
        kBasic,
        kCloze,
        kDeckJp,
        kDeckLang,
        kFullOptions,
        legacyApkg,
        legacyDconf,
        legacyDecks,
        legacyModels,
        ms;

const String _vectorsPath = 'test/srs/fixtures/apkg_import_vectors.json';

final int _nowMs = ms(2026, 6, 1);

const SrsAnkiImportOptions _noScheduling = SrsAnkiImportOptions(
  mergeNoteTypes: true,
  updateNotes: SrsImportUpdateCondition.never,
  updateNoteTypes: SrsImportUpdateCondition.never,
  withScheduling: false,
  withDeckConfigs: true,
);

/// 卡片 id 与 ord 反序、revlog 跨卡交错、孤儿卡（笔记不存在）、孤儿 revlog（卡不存在）、没有卡的笔记、
/// 笔记 id 与插入顺序相反。
Uint8List _interleavedApkg() {
  final int t = ms(2026, 2, 1);
  final Uint8List col = patchSqlite(
    buildLegacyCollection(
      crtSecs: crtSecs,
      conf: <String, Object?>{'rollover': 4, 'localOffset': 0, 'fsrs': true},
      models: legacyModels(),
      decks: legacyDecks(),
      dconf: legacyDconf(),
      notes: <FxNote>[
        FxNote(
          id: t + 300,
          guid: 'late',
          mid: kBasic,
          fields: <String>['後', 'later'],
          cards: <FxCard>[
            // ord 1 的卡 id 更小：按 (ord, id) 排，它仍排在 ord 0 之后。
            FxCard(
              id: 5,
              ord: 1,
              did: kDeckLang,
              type: 2,
              queue: 2,
              due: 40,
              ivl: 9,
              factor: 2300,
              reps: 3,
              lapses: 1,
              revlog: <FxRevlog>[
                FxRevlog(t + 11, type: 0, ease: 3, ivl: -600, factor: 0),
                FxRevlog(t + 86400011, type: 1, ease: 1, ivl: 1),
                FxRevlog(t + 172800011, type: 2, ease: 3, ivl: 9),
              ],
            ),
            FxCard(
              id: 900,
              ord: 0,
              did: kDeckJp,
              type: 2,
              queue: 2,
              due: 33,
              ivl: 6,
              factor: 2500,
              reps: 2,
              data: '{"s":7.5,"d":4.2}',
              revlog: <FxRevlog>[
                FxRevlog(t + 10, type: 0, ease: 3, ivl: -600, factor: 0),
                FxRevlog(t + 86400010, type: 1, ease: 3, ivl: 6),
                FxRevlog(t + 90000010, type: 3, ease: 3, ivl: 6),
              ],
            ),
          ],
        ),
        FxNote(
          id: t + 100,
          guid: 'early',
          mid: kCloze,
          fields: <String>['{{c1::雨}}が{{c2::降る}}{{c3::日}}', ''],
          tags: <String>['weather', 'marked'],
          cards: <FxCard>[
            FxCard(
              id: 702,
              ord: 2,
              did: kDeckJp,
              due: 9,
              revlog: <FxRevlog>[
                FxRevlog(t + 20, type: 0, ease: 3, ivl: 1),
                FxRevlog(t + 30, type: 4, ease: 0, ivl: 0, factor: 0),
              ],
            ),
            FxCard(id: 701, ord: 1, did: kDeckJp, queue: -1, due: 8),
            FxCard(
              id: 700,
              ord: 0,
              did: kDeckJp,
              type: 1,
              queue: 1,
              due: 7,
              revlog: <FxRevlog>[FxRevlog(t + 25, type: 0, ease: 2, ivl: -60)],
            ),
          ],
        ),
        FxNote(
          id: t + 200,
          guid: 'bare',
          mid: kBasic,
          fields: <String>['空', 'no cards'],
          cards: <FxCard>[],
        ),
        FxNote(
          id: t + 400,
          guid: 'fresh',
          mid: kBasic,
          fields: <String>['新', 'new'],
          tags: <String>['leech'],
          cards: <FxCard>[
            FxCard(id: 41, ord: 0, did: kDeckJp, due: 12),
            FxCard(id: 40, ord: 1, did: kDeckLang, queue: -1, due: 11),
          ],
        ),
      ],
    ),
    (Database db) {
      // 孤儿卡（笔记 t+250 不存在）与它的 revlog、孤儿 revlog（卡 12345 不存在）：都不导入。
      db.execute(
        'INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, '
        'ivl, factor, reps, lapses, left, odue, odid, flags, data) '
        'VALUES (77, ?, ?, 0, 0, 0, 2, 2, 5, 3, 2500, 1, 0, 0, 0, 0, 0, ?)',
        <Object?>[t + 250, kDeckJp, ''],
      );
      for (final (int id, int cid) in <(int, int)>[
        (t + 15, 77),
        (t + 16, 12345),
        (t + 17, 77),
      ]) {
        db.execute(
          'INSERT INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, '
          'type) VALUES (?, ?, 0, 3, 3, 0, 2500, 4000, 1)',
          <Object?>[id, cid],
        );
      }
    },
  );
  return zipOf(<String, List<int>>{'collection.anki21': col});
}

/// 一次导入后的库内容。
Future<Map<String, Object?>> _dump(
  SrsDbStore store,
  SrsImportReport report,
) async {
  final List<String> noteIds = (await store.entityIds(
    SrsEntityKind.note,
  )).toList()..sort();
  final Map<String, SrsNoteView?> notes = await store.notes(noteIds);
  final List<SrsCardCacheRow> cards = (await store.allCardRows())
    ..sort((SrsCardCacheRow a, SrsCardCacheRow b) => a.id.compareTo(b.id));
  final Map<String, List<SrsReviewLog>> logs = await store.logsOfCards(<String>[
    for (final SrsCardCacheRow c in cards) c.id,
  ]);
  final SrsDeckTree tree = await store.deckTree();
  final List<SrsNoteTypeView> types = await store.noteTypes()
    ..sort((SrsNoteTypeView a, SrsNoteTypeView b) => a.id.compareTo(b.id));
  return <String, Object?>{
    'report': report.toJson(),
    'notes': <Object?>[
      for (final String id in noteIds)
        if (notes[id] case final SrsNoteView n)
          <String, Object?>{
            'id': n.id,
            'type': n.noteTypeId,
            'guid': n.guid,
            'createdAt': n.createdAt,
            'fields': Map<String, String>.fromEntries(
              n.fields.entries.toList()..sort(
                (MapEntry<String, String> a, MapEntry<String, String> b) =>
                    a.key.compareTo(b.key),
              ),
            ),
            'tags': n.tags,
            'deck': n.deckId,
            'deletedAt': n.deletedAt,
          },
    ],
    'cards': <Object?>[for (final SrsCardCacheRow c in cards) c.toJson()],
    'logs': <String, Object?>{
      for (final String card in logs.keys.toList()..sort())
        card: <Object?>[
          for (final SrsReviewLog l
              in logs[card]!..sort(
                (SrsReviewLog a, SrsReviewLog b) => a.id.compareTo(b.id),
              ))
            l.toJson(),
        ],
    },
    'decks': <Object?>[
      for (final SrsDeckView d
          in tree.decks.toList()
            ..sort((SrsDeckView a, SrsDeckView b) => a.id.compareTo(b.id)))
        <String, Object?>{'id': d.id, 'name': d.name, 'parent': d.parentId},
    ],
    'noteTypes': <Object?>[
      for (final SrsNoteTypeView t in types)
        <String, Object?>{
          'id': t.id,
          'name': t.name,
          'kind': t.kind,
          'fields': <Object?>[
            for (final SrsFieldDef f in t.fields)
              <Object?>[f.id, f.name, f.ord],
          ],
          'templates': <Object?>[
            for (final SrsTemplateDef x in t.templates)
              <Object?>[x.id, x.name, x.ord],
          ],
        },
    ],
  };
}

Future<SrsImportReport> _import(
  SrsDbStore store,
  Uint8List bytes,
  SrsAnkiImportOptions options,
) => importAnkiPackage(
  store: store,
  bytes: bytes,
  storeMedia: (String name, Uint8List b) async => name,
  options: options,
  zstdDecompress: (Uint8List b) => null,
);

/// 一个场景：新开一个库，按顺序导入若干个包，每次导入后取一份内容。
Future<List<Object?>> _scenario(
  List<(Uint8List, SrsAnkiImportOptions)> imports,
) async {
  final SrsDbStore store = await openTestStore(
    profileUid: '01928c3e-0000-7000-8000-0000000a0001',
    deviceId: 'vectors',
    now: () => _nowMs,
  );
  return <Object?>[
    for (final (Uint8List bytes, SrsAnkiImportOptions options) in imports)
      await _dump(store, await _import(store, bytes, options)),
  ];
}

void main() {
  final Uint8List interleaved = _interleavedApkg();
  final Map<String, List<(Uint8List, SrsAnkiImportOptions)>> scenarios =
      <String, List<(Uint8List, SrsAnkiImportOptions)>>{
        'interleaved': <(Uint8List, SrsAnkiImportOptions)>[
          (interleaved, kFullOptions),
          // 再导一次：全部走「本机已有」的分支（预读、历史判重）。
          (interleaved, kFullOptions),
        ],
        'interleaved_no_scheduling': <(Uint8List, SrsAnkiImportOptions)>[
          (interleaved, _noScheduling),
        ],
        'fixture': <(Uint8List, SrsAnkiImportOptions)>[
          (legacyApkg(_nowMs), kFullOptions),
        ],
        'bench8': <(Uint8List, SrsAnkiImportOptions)>[
          (benchApkg(8), kFullOptions),
        ],
      };

  test('导入结果与向量逐项一致（卡 / 笔记 / 日志 / 牌组 / 笔记类型 / 报告）', () async {
    final Map<String, Object?> got = <String, Object?>{
      for (final MapEntry<String, List<(Uint8List, SrsAnkiImportOptions)>> s
          in scenarios.entries)
        s.key: await _scenario(s.value),
    };
    // 经一次编解码：比较的是 JSON 值，不是 Dart 对象类型。
    final Object? actual = jsonDecode(jsonEncode(got));
    final File file = File(_vectorsPath);
    if (Platform.environment['FUSHI_APKG_VECTORS_WRITE'] == '1') {
      file.writeAsStringSync(
        '${const JsonEncoder.withIndent(' ').convert(actual)}\n',
      );
      return;
    }
    final Object? expected = jsonDecode(file.readAsStringSync());
    for (final String name in scenarios.keys) {
      expect(
        (actual! as Map<String, Object?>)[name],
        (expected! as Map<String, Object?>)[name],
        reason: name,
      );
    }
  });
}
