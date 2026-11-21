// BUG-4657：apkg 导入丢掉「卡已删除、revlog 仍在」的复习。
//
// 来源包里 Anki 端删过的卡，cards 表里没有了、revlog 表里它的复习还在。导入按卡收 revlog（JOIN cards），这些复习
// 一条不进 Fushi，统计页 / 日历上那几天的复习凭空消失。所有者定案：保留，只进统计与日历的历史，不参与排期。
// 承载：挂在 SrsIds.deletedAnkiCard 派生的卡 ID 上——没有卡片缓存行（不进队列 / 浏览 / 任何卡的历史），有效复习
// 投影照常收（统计与日历读的就是投影）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../support/srs_stats_rows.dart';
import 'apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000001';
const int kDeck = 1700000000010;
const int kMid = 1700000000077;

/// 来源里已删除的卡（cards 表里没有它）。
const int kDeletedCid = 555;

/// 卡还在、但所属笔记已删的卡（cards 里有行、notes 里没有，旧集合损坏时会出现）。
const int kNoteLessCid = 556;

int ms(int y, int m, int d, [int h = 0]) =>
    DateTime.utc(y, m, d, h).millisecondsSinceEpoch;

final int crtSecs = ms(2026, 1, 1, 4) ~/ 1000;
final int day1 = ms(2026, 9, 6, 10);
const int kDayMs = 86400000;

Map<String, Object?> model() => <String, Object?>{
  '$kMid': <String, Object?>{
    'id': kMid,
    'name': 'Basic',
    'type': 0,
    'css': '',
    'flds': <Object?>[
      <String, Object?>{'name': 'Front', 'ord': 0, 'id': 9000},
      <String, Object?>{'name': 'Back', 'ord': 1, 'id': 9001},
    ],
    'tmpls': <Object?>[
      <String, Object?>{
        'name': 'Card 1',
        'ord': 0,
        'qfmt': '{{Front}}',
        'afmt': '{{Back}}',
        'id': 9100,
      },
    ],
  },
};

/// 一条笔记、一张活卡（两条 revlog）。
FxNote liveNote() => FxNote(
  id: ms(2026, 8, 1),
  guid: 'g0',
  mid: kMid,
  fields: <String>['語', 'word'],
  cards: <FxCard>[
    FxCard(
      id: 100,
      ord: 0,
      did: kDeck,
      type: 2,
      queue: 2,
      due: 300,
      ivl: 10,
      factor: 2500,
      reps: 2,
      revlog: <FxRevlog>[
        FxRevlog(day1 - kDayMs * 3, type: 0, ease: 3, ivl: 1),
        FxRevlog(day1, type: 1, ease: 3, ivl: 10),
      ],
    ),
  ],
);

/// 已删除的卡的三次复习（学习 → 复习 → 遗忘），分在三天；另一张没有笔记的卡一次复习。
final List<(int, FxRevlog)> deletedRevlogs = <(int, FxRevlog)>[
  (kDeletedCid, FxRevlog(day1 - kDayMs * 20, type: 0, ease: 3, ivl: 1)),
  (kDeletedCid, FxRevlog(day1 - kDayMs * 19, type: 1, ease: 3, ivl: 4)),
  (kDeletedCid, FxRevlog(day1 - kDayMs * 15, type: 1, ease: 1, ivl: -600)),
  (kNoteLessCid, FxRevlog(day1 - kDayMs * 10, type: 1, ease: 4, ivl: 9)),
];

Uint8List apkg({required bool withDeleted}) => zipOf(<String, List<int>>{
  'collection.anki21': buildSqlite((Database db) {
    db.execute(legacySchema);
    db.execute('INSERT INTO col VALUES (1,?,0,0,11,0,0,0,?,?,?,?,?)', <Object?>[
      crtSecs,
      jsonEncode(<String, Object?>{'rollover': 4, 'localOffset': 0}),
      jsonEncode(model()),
      jsonEncode(<String, Object?>{
        '1': <String, Object?>{'id': 1, 'name': 'Default', 'dyn': 0, 'conf': 1},
        '$kDeck': <String, Object?>{
          'id': kDeck,
          'name': '日本語',
          'dyn': 0,
          'conf': 1,
        },
      }),
      jsonEncode(<String, Object?>{
        '1': <String, Object?>{'id': 1, 'name': 'Default'},
      }),
      '{}',
    ]);
    insertNotes(db, <FxNote>[liveNote()]);
    if (!withDeleted) return;
    // 没有笔记的卡：cards 里有行，nid 指向不存在的笔记。
    db.execute(
      'INSERT INTO cards VALUES (?,?,?,0,0,0,2,2,300,9,2500,1,0,0,0,0,0,?)',
      <Object?>[kNoteLessCid, 999999, kDeck, ''],
    );
    for (final (int cid, FxRevlog r) in deletedRevlogs) {
      db.execute('INSERT INTO revlog VALUES (?,?,?,?,?,?,?,?,?)', <Object?>[
        r.id,
        cid,
        0,
        r.ease,
        r.ivl,
        0,
        r.factor,
        r.time,
        r.type,
      ]);
    }
  }),
  'media': utf8.encode('{}'),
});

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final int now = ms(2026, 10, 14, 12);

  Future<SrsDbStore> open() =>
      openTestStore(profileUid: kProfile, deviceId: 'a', now: () => now);

  Future<SrsImportReport> imp(SrsDbStore s, Uint8List bytes) =>
      importAnkiPackage(
        store: s,
        bytes: bytes,
        storeMedia: (String n, Uint8List b) async => 'h_$n',
        options: const SrsAnkiImportOptions(
          withScheduling: true,
          withDeckConfigs: true,
        ),
        zstdDecompress: (Uint8List b) => null,
      );

  Future<SrsStatsReport> report(SrsDbStore s) async =>
      (await loadSrsStats(s)).report(range: SrsStatsRange.all);

  Future<List<Map<String, Object?>>> cardRows(SrsDbStore s) async =>
      <Map<String, Object?>>[
        for (final SrsCardCacheRow c in await s.allCardRows()) c.toJson(),
      ];

  final String deletedCard = SrsIds.deletedAnkiCard(
    SrsKernelIds(kProfile).defaultDeck,
    kDeletedCid,
  );
  final String noteLessCard = SrsIds.deletedAnkiCard(
    SrsKernelIds(kProfile).defaultDeck,
    kNoteLessCid,
  );

  test('卡已删除的 revlog 进统计与日历，不生成卡、不碰活卡排期', () async {
    final SrsDbStore base = await open();
    final SrsImportReport baseRep = await imp(base, apkg(withDeleted: false));
    expect(baseRep.deletedCardRevlogsImported, 0);

    final SrsDbStore s = await open();
    final SrsImportReport rep = await imp(s, apkg(withDeleted: true));
    expect(rep.deletedCardRevlogsImported, deletedRevlogs.length);
    expect(rep.reviewLogsImported, 2 + deletedRevlogs.length);

    // 统计：有效复习投影里 6 条，删卡的 4 条归属到删卡 ID。
    final StatsRows rows = await statsRowsOf(s);
    expect(rows.reviews, hasLength(2 + deletedRevlogs.length));
    expect(
      rows.reviews.where((StatReviewRow r) => r.cardId == deletedCard),
      hasLength(3),
    );
    expect(
      rows.reviews.where((StatReviewRow r) => r.cardId == noteLessCard),
      hasLength(1),
    );
    // 删卡的遗忘那次按重学（relearn 之前的那条是复习）分类，与活卡同一套推算。
    expect(
      rows.reviews
          .where((StatReviewRow r) => r.cardId == deletedCard)
          .map((StatReviewRow r) => r.rating),
      <int>[3, 3, 1],
    );

    // 日历：删卡那几天都有复习计数，总数 = 全部复习。
    final SrsStatsReport withDel = await report(s);
    final SrsStatsReport without = await report(base);
    int sum(Map<int, int> m) => m.values.fold(0, (int a, int b) => a + b);
    expect(sum(without.countsByDay), 2);
    expect(sum(withDel.countsByDay), 2 + deletedRevlogs.length);
    final SrsDayContext day = await s.dayContext();
    for (final (int _, FxRevlog r) in deletedRevlogs) {
      expect(withDel.countsByDay[day.dayIndexOf(r.id)], 1, reason: '${r.id}');
    }

    // 排期：卡片缓存与不带删卡复习时逐行相同（只有那一张活卡），卡片计数与到期预测也相同。
    expect(await cardRows(s), await cardRows(base));
    expect(await cardRows(s), hasLength(1));
    expect(withDel.cardCounts.young + withDel.cardCounts.mature, 1);
    expect(withDel.future.perDay, without.future.perDay);
    expect(withDel.future.overdue, without.future.overdue);
    final String liveCard = (await cardRows(s)).single['id']! as String;
    expect(
      (await s.history(liveCard)).all.map((SrsReviewLog l) => l.id),
      (await base.history(liveCard)).all.map((SrsReviewLog l) => l.id),
    );
  });

  test('重复导入同一个包：删卡复习不再写一份', () async {
    final SrsDbStore s = await open();
    await imp(s, apkg(withDeleted: true));
    final SrsImportReport again = await imp(s, apkg(withDeleted: true));
    expect(again.deletedCardRevlogsImported, 0);
    expect(again.revlogsAlreadyPresent, greaterThanOrEqualTo(4));
    expect(
      (await statsRowsOf(s)).reviews,
      hasLength(2 + deletedRevlogs.length),
    );
  });

  test('之前导入时卡还在、之后在 Anki 删了卡再导：不重复计数', () async {
    final SrsDbStore s = await open();
    await imp(s, apkg(withDeleted: false));
    // 活卡 100 在 Anki 端被删：新包里它的两条 revlog 成了删卡复习。
    final Uint8List deleted = zipOf(<String, List<int>>{
      'collection.anki21': buildSqlite((Database db) {
        db.execute(legacySchema);
        db.execute(
          'INSERT INTO col VALUES (1,?,0,0,11,0,0,0,?,?,?,?,?)',
          <Object?>[
            crtSecs,
            jsonEncode(<String, Object?>{'rollover': 4, 'localOffset': 0}),
            jsonEncode(model()),
            jsonEncode(<String, Object?>{
              '1': <String, Object?>{
                'id': 1,
                'name': 'Default',
                'dyn': 0,
                'conf': 1,
              },
            }),
            jsonEncode(<String, Object?>{
              '1': <String, Object?>{'id': 1, 'name': 'Default'},
            }),
            '{}',
          ],
        );
        for (final FxRevlog r in liveNote().cards.single.revlog) {
          db.execute('INSERT INTO revlog VALUES (?,?,?,?,?,?,?,?,?)', <Object?>[
            r.id,
            100,
            0,
            r.ease,
            r.ivl,
            0,
            r.factor,
            r.time,
            r.type,
          ]);
        }
      }),
      'media': utf8.encode('{}'),
    });
    final SrsImportReport rep = await imp(s, deleted);
    expect(rep.deletedCardRevlogsImported, 0);
    expect(rep.revlogsAlreadyPresent, 2);
    expect((await statsRowsOf(s)).reviews, hasLength(2));
  });

  test('不带排程导入：删卡复习同样不导', () async {
    final SrsDbStore s = await open();
    final SrsImportReport rep = await importAnkiPackage(
      store: s,
      bytes: apkg(withDeleted: true),
      storeMedia: (String n, Uint8List b) async => 'h_$n',
      options: const SrsAnkiImportOptions(withScheduling: false),
      zstdDecompress: (Uint8List b) => null,
    );
    expect(rep.deletedCardRevlogsImported, 0);
    expect(rep.reviewLogsSkipped, 2 + deletedRevlogs.length);
    expect((await statsRowsOf(s)).reviews, isEmpty);
  });

  /// 只有 revlog、没有卡与笔记的包（来源卡都在 Anki 端删了）。
  Uint8List revlogOnly(List<(int, FxRevlog)> logs) => zipOf(<String, List<int>>{
    'collection.anki21': buildSqlite((Database db) {
      db.execute(legacySchema);
      db.execute(
        'INSERT INTO col VALUES (1,?,0,0,11,0,0,0,?,?,?,?,?)',
        <Object?>[
          crtSecs,
          jsonEncode(<String, Object?>{'rollover': 4, 'localOffset': 0}),
          jsonEncode(model()),
          jsonEncode(<String, Object?>{
            '1': <String, Object?>{
              'id': 1,
              'name': 'Default',
              'dyn': 0,
              'conf': 1,
            },
          }),
          jsonEncode(<String, Object?>{
            '1': <String, Object?>{'id': 1, 'name': 'Default'},
          }),
          '{}',
        ],
      );
      for (final (int cid, FxRevlog r) in logs) {
        db.execute('INSERT INTO revlog VALUES (?,?,?,?,?,?,?,?,?)', <Object?>[
          r.id,
          cid,
          0,
          r.ease,
          r.ivl,
          0,
          r.factor,
          r.time,
          r.type,
        ]);
      }
    }),
    'media': utf8.encode('{}'),
  });

  test('Fushi 复习 → 导出 → Anki 删卡 → 导回：原生那份已在，不再算一次', () async {
    final SrsDbStore s = await open();
    final String note = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '食べる',
      },
    );
    final SrsReviewLog review = await s.answer(
      (await s.cardsOfNote(note)).single.id,
      3,
      durationMs: 7000,
    );
    expect((await statsRowsOf(s)).reviews, hasLength(1));

    // 导出时 revlog id = 原生日志发生时刻、time = min(用时, 60000)；Anki 端删卡后再导出，只剩这条 revlog。
    final SrsImportReport rep = await imp(
      s,
      revlogOnly(<(int, FxRevlog)>[
        (
          4242,
          FxRevlog(review.occurredAt, type: 0, ease: 3, ivl: 1, time: 7000),
        ),
      ]),
    );
    expect(rep.deletedCardRevlogsImported, 0);
    expect(rep.revlogsAlreadyPresent, 1);
    expect((await statsRowsOf(s)).reviews, hasLength(1));
  });

  test('同一秒、同评分但用时不同的别的复习：删卡那条照常导入', () async {
    final SrsDbStore s = await open();
    final String note = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '食べる',
      },
    );
    final SrsReviewLog review = await s.answer(
      (await s.cardsOfNote(note)).single.id,
      3,
      durationMs: 7000,
    );
    final SrsImportReport rep = await imp(
      s,
      revlogOnly(<(int, FxRevlog)>[
        (
          4242,
          FxRevlog(
            review.occurredAt + 300,
            type: 0,
            ease: 3,
            ivl: 1,
            time: 2500,
          ),
        ),
      ]),
    );
    expect(rep.deletedCardRevlogsImported, 1);
    expect(rep.revlogsAlreadyPresent, 0);
    expect((await statsRowsOf(s)).reviews, hasLength(2));
  });
}
