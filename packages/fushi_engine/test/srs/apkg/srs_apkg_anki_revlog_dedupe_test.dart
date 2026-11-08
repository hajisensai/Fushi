// BUG-4242：从 Anki 迁移后复习数 ×2（Discord 用户：同一天 Anki 2082 次、Fushi 4164 次）。
//
// 导入的复习日志 ID 由本机卡 ID 派生（SrsIds.importedRevlogs），同一条 Anki revlog 落到另一张卡上就成了另一条日志：
// - B：Lapis 迁到 Fushi 卡片后（新卡经 historyFrom 继承旧卡历史），Anki 端笔记已是 Fushi 卡片、再迁一次——同一血统里两份；
// - C：先按一种笔记类型导入，删光后按另一种类型重导——旧卡隐藏、新卡可见，两张卡没有血统链接，各自投影进统计。
// 写侧：导入前按 revlog id 查本机已有的 Anki 日志，在血统里的不写、在已隐藏旧卡上的接 historyFrom。
// 读侧（已受害的库）：选取规则对 Anki 来源不比卡（history.rs EventKey），统计投影跨卡按 Anki 事件身份只留一份
// （caches.rs refresh_stats）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_legacy_lapis_migration.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000001';
const int kDeck = 1700000000010;
const int kLapisMid = 1700000000077;

int ms(int y, int m, int d, [int h = 0]) =>
    DateTime.utc(y, m, d, h).millisecondsSinceEpoch;

final int crtSecs = ms(2026, 1, 1, 4) ~/ 1000;
final int day1 = ms(2026, 9, 6, 10);

/// 两条笔记 × 每条一张卡 × 两条 revlog。
const int kSourceReviews = 4;

final int kFushiMid = SrsIds.builtinNoteTypeAnkiNum(kSrsBuiltinFushiCardKey);

/// Anki 端「Fushi Card」：mid = 内置 ankiNum（以前从 Fushi 导出过），字段 / 模板 id 与内置相同（[tmplId] 缺省），或
/// 模板 id 不同（另一个模板，导入时另建一份笔记类型 / 合并进内置）。
Map<String, Object?> fushiCardModel({int? tmplId}) {
  final SrsBuiltinNoteType b = srsBuiltinFushiCard(kProfile);
  return <String, Object?>{
    '$kFushiMid': <String, Object?>{
      'id': kFushiMid,
      'name': 'Fushi Card',
      'type': 0,
      'css': '',
      'flds': <Object?>[
        for (final SrsFieldDef f in b.fields)
          <String, Object?>{'name': f.name, 'ord': f.ord, 'id': f.ankiNum},
      ],
      'tmpls': <Object?>[
        <String, Object?>{
          'name': 'Card 1',
          'ord': 0,
          'qfmt': '{{Term}}',
          'afmt': '{{FrontSide}}<hr id=answer>{{MainDefinition}}',
          'id': tmplId ?? b.templates.single.ankiNum,
        },
      ],
    },
  };
}

/// Anki 端非内置「Lapis」（名字含 lapis → 迁移后转 Fushi 卡片）。
Map<String, Object?> lapisModel() => <String, Object?>{
  '$kLapisMid': <String, Object?>{
    'id': kLapisMid,
    'name': 'Lapis',
    'type': 0,
    'css': '',
    'flds': <Object?>[
      for (final (int i, String n) in <String>[
        'Expression',
        'ExpressionReading',
        'MainDefinition',
        'Sentence',
      ].indexed)
        <String, Object?>{'name': n, 'ord': i, 'id': 9000 + i},
    ],
    'tmpls': <Object?>[
      <String, Object?>{
        'name': 'Card 1',
        'ord': 0,
        'qfmt': '{{Expression}}',
        'afmt': '{{MainDefinition}}',
        'id': 9100,
      },
    ],
  },
};

List<FxNote> notesOf(int mid, int nFields) => <FxNote>[
  for (int i = 0; i < 2; i++)
    FxNote(
      id: ms(2026, 8, 1) + i,
      guid: 'g$i',
      mid: mid,
      fields: <String>['語$i', for (int k = 1; k < nFields; k++) 'f$k'],
      cards: <FxCard>[
        FxCard(
          id: 100 + i,
          ord: 0,
          did: kDeck,
          type: 2,
          queue: 2,
          due: 300,
          ivl: 10,
          factor: 2500,
          reps: 2,
          revlog: <FxRevlog>[
            FxRevlog(day1 - 86400000 * 3 + i, type: 0, ease: 3, ivl: 1),
            FxRevlog(day1 + i, type: 1, ease: 3, ivl: 10),
          ],
        ),
      ],
    ),
];

Uint8List apkg(Map<String, Object?> models, List<FxNote> notes) => zipOf(
  <String, List<int>>{
    'collection.anki21': buildLegacyCollection(
      crtSecs: crtSecs,
      conf: <String, Object?>{'rollover': 4, 'localOffset': 0},
      models: models,
      decks: <String, Object?>{
        '1': <String, Object?>{'id': 1, 'name': 'Default', 'dyn': 0, 'conf': 1},
        '$kDeck': <String, Object?>{
          'id': kDeck,
          'name': '日本語::Kaishi',
          'dyn': 0,
          'conf': 1,
        },
      },
      dconf: <String, Object?>{
        '1': <String, Object?>{'id': 1, 'name': 'Default'},
      },
      notes: notes,
    ),
    'media': utf8.encode('{}'),
  },
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = ms(2026, 10, 14, 12);

  setUp(() => t = ms(2026, 10, 14, 12));

  Future<SrsDbStore> open() =>
      openTestStore(profileUid: kProfile, deviceId: 'a', now: () => t);

  Future<SrsImportReport> imp(
    SrsDbStore s,
    Uint8List bytes, {
    bool merge = false,
  }) => importAnkiPackage(
    store: s,
    bytes: bytes,
    storeMedia: (String n, Uint8List b) async => 'h_$n',
    options: SrsAnkiImportOptions(
      withScheduling: true,
      withDeckConfigs: true,
      mergeNoteTypes: merge,
    ),
    zstdDecompress: (Uint8List b) => null,
  );

  // 与 runSrsAnkiMigration 的 convertLapis 同一段（srsConvertLegacyLapisAfterImport）。
  Future<void> convertLapis(SrsDbStore s) async {
    for (final SrsLegacyLapisSource src in await s.legacyLapisSources()) {
      await s.migrateLegacyLapis(src.type.id);
    }
    await s.applyLapisBackfill();
  }

  Future<void> deleteAll(SrsDbStore s) async {
    for (final SrsNoteCacheRow n in await s.listNotes(limit: 100000)) {
      await s.deleteNote(n.id);
    }
  }

  Future<int> reviews(SrsDbStore s) async =>
      (await loadSrsStats(s)).data.reviews.length;

  /// 笔记 g0 的可见卡（都应有完整进度）。
  Future<List<SrsCardCacheRow>> visibleCardsOfG0(SrsDbStore s) async =>
      (await s.cardsOfNote(
        SrsIds.note(kProfile, 'g0'),
      )).where((SrsCardCacheRow c) => !c.hidden).toList();

  /// 一张卡历史里有效的 Anki 评分复习数。
  Future<int> effectiveAnkiReviews(SrsDbStore s, String cardId) async =>
      (await s.history(cardId)).effective
          .where(
            (SrsReviewLog l) =>
                l.origin == SrsLogOrigin.anki && l.kind == SrsLogKind.review,
          )
          .length;

  group('写侧：再从 Anki 迁移不再写第二份', () {
    test('B1 Lapis 迁移后删光，Anki 端已换成 Fushi Card 再迁：复习不翻倍', () async {
      final SrsDbStore s = await open();
      await imp(s, apkg(lapisModel(), notesOf(kLapisMid, 4)));
      await convertLapis(s);
      expect(await reviews(s), kSourceReviews);
      await deleteAll(s);
      t += 3600000;
      final SrsImportReport rep = await imp(
        s,
        apkg(fushiCardModel(), notesOf(kFushiMid, 23)),
      );
      await convertLapis(s);
      expect(rep.revlogsAlreadyPresent, kSourceReviews);
      expect(rep.reviewLogsImported, 0);
      expect(await reviews(s), kSourceReviews);
      final SrsCardCacheRow card = (await visibleCardsOfG0(s)).single;
      expect(card.reps, 2);
      expect(await effectiveAnkiReviews(s, card.id), 2);
    });

    test('B2 不删：Lapis 迁移后再从 Anki 迁一次（已是 Fushi Card）：复习不翻倍', () async {
      final SrsDbStore s = await open();
      await imp(s, apkg(lapisModel(), notesOf(kLapisMid, 4)));
      await convertLapis(s);
      t += 3600000;
      final SrsImportReport rep = await imp(
        s,
        apkg(fushiCardModel(), notesOf(kFushiMid, 23)),
      );
      expect(rep.revlogsAlreadyPresent, kSourceReviews);
      expect(await reviews(s), kSourceReviews);
      final SrsCardCacheRow card = (await visibleCardsOfG0(s)).single;
      expect(await effectiveAnkiReviews(s, card.id), 2);
    });

    test('C1 不合并导入 → 删光 → 合并导入（换了卡）：新卡接上旧卡历史，复习不翻倍', () async {
      final SrsDbStore s = await open();
      final Uint8List pkg = apkg(
        fushiCardModel(tmplId: 4242),
        notesOf(kFushiMid, 23),
      );
      await imp(s, pkg);
      expect(await reviews(s), kSourceReviews);
      await deleteAll(s);
      t += 3600000;
      final SrsImportReport rep = await imp(s, pkg, merge: true);
      expect(rep.revlogsAlreadyPresent, kSourceReviews);
      expect(await reviews(s), kSourceReviews);
      // 带进度的那张卡：历史经 historyFrom 来自旧卡（自己没有再写一份）。
      final SrsCardCacheRow scheduled = (await visibleCardsOfG0(
        s,
      )).singleWhere((SrsCardCacheRow c) => c.reps > 0);
      expect(scheduled.reps, 2);
      expect(await effectiveAnkiReviews(s, scheduled.id), 2);
    });

    test('C2 对照：同一个包、同一组选项删光重导 → 复习数不变', () async {
      final SrsDbStore s = await open();
      final Uint8List pkg = apkg(lapisModel(), notesOf(kLapisMid, 4));
      await imp(s, pkg);
      await convertLapis(s);
      await deleteAll(s);
      t += 3600000;
      await imp(s, pkg);
      await convertLapis(s);
      expect(await reviews(s), kSourceReviews);
      expect((await visibleCardsOfG0(s)).single.reps, 2);
    });

    test('旧卡已由可见卡继承、再导入映射到另一张卡：不写也不接链（两张活卡不共享历史）', () async {
      final SrsDbStore s = await open();
      await imp(s, apkg(lapisModel(), notesOf(kLapisMid, 4)));
      final String lapisCard = (await s.cardsOfNote(
        SrsIds.note(kProfile, 'g0'),
      )).single.id;
      await convertLapis(s);
      final String heir = (await visibleCardsOfG0(s)).single.id;
      t += 3600000;
      // 换了模板的 Fushi Card 合并导入：g0 多出一张卡，同一批 revlog 在旧 Lapis 卡上（已被 [heir] 继承）。
      final SrsImportReport rep = await imp(
        s,
        apkg(fushiCardModel(tmplId: 4242), notesOf(kFushiMid, 23)),
        merge: true,
      );
      expect(rep.revlogsAlreadyPresent, kSourceReviews);
      expect(rep.reviewLogsImported, 0);
      final String other = (await visibleCardsOfG0(s))
          .map((SrsCardCacheRow c) => c.id)
          .singleWhere((String id) => id != heir);
      expect(
        (await s.history(
          other,
        )).all.where((SrsReviewLog l) => l.cardId == lapisCard),
        isEmpty,
      );
      expect(
        (await s.history(
          heir,
        )).all.where((SrsReviewLog l) => l.cardId == lapisCard),
        isNotEmpty,
      );
      expect(await effectiveAnkiReviews(s, heir), 2);
      expect(await effectiveAnkiReviews(s, other), 0);
      expect(await reviews(s), kSourceReviews);
    });

    test('不同笔记上同一毫秒的 Anki 复习不被当成已有', () async {
      final SrsDbStore s = await open();
      await imp(s, apkg(lapisModel(), notesOf(kLapisMid, 4)));
      // 另一条笔记（另一个集合），revlog 时刻 / 评分与 g0 的完全相同。
      final List<FxNote> other = <FxNote>[
        for (final FxNote n in notesOf(kLapisMid, 4).take(1))
          FxNote(
            id: n.id + 99,
            guid: 'other',
            mid: n.mid,
            fields: n.fields,
            cards: <FxCard>[
              for (final FxCard c in n.cards)
                FxCard(
                  id: 999,
                  ord: c.ord,
                  did: c.did,
                  type: c.type,
                  queue: c.queue,
                  due: c.due,
                  ivl: c.ivl,
                  factor: c.factor,
                  reps: c.reps,
                  revlog: c.revlog,
                ),
            ],
          ),
      ];
      final SrsImportReport rep = await imp(s, apkg(lapisModel(), other));
      expect(rep.revlogsAlreadyPresent, 0);
      expect(rep.reviewLogsImported, 2);
    });
  });

  group('读侧：旧版本已写出的重复日志', () {
    /// 旧版导入器写出的副本：同一条 revlog，日志 ID 按另一张卡派生、落在 [cardId] 上。
    Future<void> writeOldCopies(
      SrsDbStore s,
      String fromCard,
      String cardId,
    ) async {
      final List<SrsReviewLog> src = (await s.history(fromCard)).all
          .where(
            (SrsReviewLog l) =>
                l.origin == SrsLogOrigin.anki && l.ankiRevlogId != null,
          )
          .toList();
      await s.importEvents(<SrsEvent>[
        for (final SrsReviewLog l in src)
          SrsLogEvent(
            SrsReviewLog.fromJson(<String, Object?>{
              ...l.toJson(),
              'id': SrsIds.importedRevlogs(cardId, <int>[
                l.ankiRevlogId!,
              ]).single,
              'card': cardId,
            }),
          ),
      ]);
    }

    test('同一血统里的副本（B 形态）：选取只算一份，排程与统计一致', () async {
      final SrsDbStore s = await open();
      await imp(s, apkg(lapisModel(), notesOf(kLapisMid, 4)));
      final String lapisCard = (await s.cardsOfNote(
        SrsIds.note(kProfile, 'g0'),
      )).single.id;
      await convertLapis(s);
      final SrsCardCacheRow before = (await visibleCardsOfG0(s)).single;
      await writeOldCopies(s, lapisCard, before.id);
      expect((await s.history(before.id)).all.length, greaterThan(3));
      expect(await effectiveAnkiReviews(s, before.id), 2);
      expect(await reviews(s), kSourceReviews);
      final SrsCardCacheRow after = (await visibleCardsOfG0(s)).single;
      expect(after.reps, before.reps);
      expect(after.dueDay, before.dueDay);
      await s.rebuildCaches();
      expect(await reviews(s), kSourceReviews);
    });

    test('没有血统链接的隐藏旧卡 + 可见新卡（C 形态）：统计只算一份', () async {
      final SrsDbStore s = await open();
      await imp(s, apkg(lapisModel(), notesOf(kLapisMid, 4)));
      await convertLapis(s);
      final String visible = (await visibleCardsOfG0(s)).single.id;
      // 旧版导入器在一张已不属于任何笔记的旧卡上写过同一批 revlog（删光重导前那一次）。
      const String orphan = '0193a1b2-0000-7000-8000-00000000dead';
      await writeOldCopies(s, visible, orphan);
      expect(await reviews(s), kSourceReviews);
      await s.rebuildCaches();
      expect(await reviews(s), kSourceReviews);
      expect(await effectiveAnkiReviews(s, visible), 2);
    });
  });
}
