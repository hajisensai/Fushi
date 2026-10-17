import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_anki_package.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_common.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_export.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/apkg/srs_protobuf.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000001';
const String kProfile2 = '01928c3e-0000-7000-8000-000000000002';

const int kBasic = 1700000000001;
const int kCloze = 1700000000002;
const int kDeckLang = 1700000000011;
const int kDeckJp = 1700000000010;

int ms(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime.utc(y, m, d, h, min).millisecondsSinceEpoch;

final int crtSecs = ms(2026, 1, 1, 4) ~/ 1000;
final int crtDay = srsDateToDay(2026, 1, 1);

final List<double> fsrs6Params = <double>[
  0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, //
  0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425,
  0.0912, 0.0658, 0.1542,
];

// 来源卡与 revlog 时刻。
final int r1 = ms(2026, 3, 1, 10);
final int r2 = ms(2026, 3, 1, 10, 10);
final int r3 = ms(2026, 3, 2, 10);
final int r4 = ms(2026, 3, 5, 10);
final int c21a = ms(2026, 2, 1, 9);
final int c21reset = ms(2026, 2, 10, 9);

Map<String, Object?> legacyModels() => <String, Object?>{
  '$kBasic': <String, Object?>{
    'id': kBasic,
    'name': 'Basic (and reversed)',
    'type': 0,
    'css': '@font-face { src: url("_font.woff"); }',
    'flds': <Object?>[
      <String, Object?>{'name': 'Front', 'ord': 0, 'id': 111},
      <String, Object?>{'name': 'Back', 'ord': 1, 'id': 222},
    ],
    'tmpls': <Object?>[
      <String, Object?>{
        'name': 'Card 1',
        'ord': 0,
        'qfmt': '{{Front}}<img src="a.png">',
        'afmt': '{{FrontSide}}<hr id=answer>{{Back}}',
        'id': 333,
      },
      <String, Object?>{
        'name': 'Card 2',
        'ord': 1,
        'qfmt': '{{Back}}',
        'afmt': '{{FrontSide}}<hr id=answer>{{Front}}',
      },
    ],
  },
  '$kCloze': <String, Object?>{
    'id': kCloze,
    'name': 'Cloze',
    'type': 1,
    'css': '',
    'flds': <Object?>[
      <String, Object?>{'name': 'Text', 'ord': 0},
      <String, Object?>{'name': 'Extra', 'ord': 1},
    ],
    'tmpls': <Object?>[
      <String, Object?>{
        'name': 'Cloze',
        'ord': 0,
        'qfmt': '{{cloze:Text}}',
        'afmt': '{{cloze:Text}}<br>{{Extra}}',
      },
    ],
  },
};

Map<String, Object?> legacyDecks() => <String, Object?>{
  '1': <String, Object?>{'id': 1, 'name': 'Default', 'dyn': 0, 'conf': 1},
  '$kDeckLang': <String, Object?>{
    'id': kDeckLang,
    'name': 'Lang',
    'dyn': 0,
    'conf': 2,
    // 在 Anki 里收起了子牌组：导入后同样收起。
    'collapsed': true,
  },
  '$kDeckJp': <String, Object?>{
    'id': kDeckJp,
    'name': 'Lang::JP',
    'dyn': 0,
    'conf': 2,
  },
};

Map<String, Object?> legacyDconf() => <String, Object?>{
  '1': <String, Object?>{
    'id': 1,
    'name': 'Default',
    'new': <String, Object?>{
      'delays': <double>[1, 10],
      'perDay': 20,
    },
    'lapse': <String, Object?>{
      'delays': <double>[10],
    },
    'rev': <String, Object?>{'perDay': 200, 'maxIvl': 36500},
  },
  '2': <String, Object?>{
    'id': 2,
    'name': 'JP preset',
    'new': <String, Object?>{
      'delays': <double>[1, 10, 1440],
      'perDay': 15,
    },
    'lapse': <String, Object?>{
      'delays': <double>[10],
    },
    'rev': <String, Object?>{'perDay': 150, 'maxIvl': 3650},
    'desiredRetention': 0.85,
    'fsrsParams6': fsrs6Params,
  },
};

List<FxNote> fixtureNotes(int nowMs) => <FxNote>[
  FxNote(
    id: ms(2026, 2, 28),
    guid: 'g1',
    mid: kBasic,
    fields: <String>['猫<img src="a.png">', 'cat'],
    tags: <String>['animal', 'n5'],
    cards: <FxCard>[
      FxCard(
        id: 11,
        ord: 0,
        did: kDeckJp,
        type: 2,
        queue: 2,
        due: 70,
        ivl: 10,
        factor: 2500,
        reps: 3,
        data: '{"s":12.5,"d":5.1}',
        revlog: <FxRevlog>[
          FxRevlog(r1, type: 0, ease: 3, ivl: -600, factor: 0),
          FxRevlog(r2, type: 0, ease: 3, ivl: 1, factor: 2500),
          FxRevlog(r3, type: 1, ease: 3, ivl: 10, factor: 2500),
          FxRevlog(r4, type: 3, ease: 3, ivl: 10, factor: 2500),
        ],
      ),
      FxCard(id: 12, ord: 1, did: kDeckLang, due: 1),
    ],
  ),
  FxNote(
    id: ms(2026, 1, 20),
    guid: 'g2',
    mid: kCloze,
    fields: <String>['{{c1::東京}}は{{c2::首都}}', ''],
    cards: <FxCard>[
      FxCard(
        id: 21,
        ord: 0,
        did: 1,
        due: 5,
        revlog: <FxRevlog>[
          FxRevlog(c21a, type: 0, ease: 3, ivl: 1, factor: 2500),
          FxRevlog(c21reset, type: 4, ease: 0, ivl: 0, factor: 0),
        ],
      ),
      FxCard(id: 22, ord: 1, did: 1, queue: -1, due: 6),
    ],
  ),
  FxNote(
    id: ms(2026, 3, 3),
    guid: 'g3',
    mid: kBasic,
    fields: <String>['未来', 'future'],
    cards: <FxCard>[
      FxCard(
        id: 31,
        ord: 0,
        did: 1,
        type: 2,
        queue: 2,
        due: 3,
        ivl: 3,
        factor: 2500,
        revlog: <FxRevlog>[
          FxRevlog(nowMs + 86400000, type: 0, ease: 3, ivl: 3),
        ],
      ),
    ],
  ),
];

Uint8List legacyApkg(int nowMs) => zipOf(<String, List<int>>{
  'collection.anki21': buildLegacyCollection(
    crtSecs: crtSecs,
    conf: <String, Object?>{'rollover': 4, 'localOffset': 0, 'fsrs': true},
    models: legacyModels(),
    decks: legacyDecks(),
    dconf: legacyDconf(),
    notes: fixtureNotes(nowMs),
  ),
  'media': utf8.encode(
    jsonEncode(<String, String>{
      '0': 'a.png',
      '1': '_font.woff',
      '2': 'unused.png',
    }),
  ),
  '0': <int>[1, 2, 3],
  '1': <int>[4, 5],
  '2': <int>[6],
});

/// 旧行为（选项加入前）：全部导入排程与预设、合并笔记类型、从不覆盖已有内容。
const SrsAnkiImportOptions kFullOptions = SrsAnkiImportOptions(
  mergeNoteTypes: true,
  updateNotes: SrsImportUpdateCondition.never,
  updateNoteTypes: SrsImportUpdateCondition.never,
  withScheduling: true,
  withDeckConfigs: true,
);

/// 旧格式包：[models] 换笔记类型、[patch] 再改集合（例如笔记 mod / 字段）。
Uint8List customApkg(
  int nowMs, {
  Map<String, Object?>? models,
  void Function(Database db)? patch,
}) {
  Uint8List col = buildLegacyCollection(
    crtSecs: crtSecs,
    conf: <String, Object?>{'rollover': 4, 'localOffset': 0, 'fsrs': true},
    models: models ?? legacyModels(),
    decks: legacyDecks(),
    dconf: legacyDconf(),
    notes: fixtureNotes(nowMs),
  );
  if (patch != null) col = patchSqlite(col, patch);
  return zipOf(<String, List<int>>{
    'collection.anki21': col,
    'media': utf8.encode(
      jsonEncode(<String, String>{'0': 'a.png', '1': '_font.woff'}),
    ),
    '0': <int>[1, 2, 3],
    '1': <int>[4, 5],
  });
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = ms(2026, 10, 14, 12);
  late MemoryDir dir;
  late List<String> stored;

  Future<String> storeMedia(String name, Uint8List bytes) async {
    stored.add(name);
    return 'h_$name';
  }

  setUp(() {
    t = ms(2026, 10, 14, 12);
    dir = MemoryDir(() => t);
    stored = <String>[];
  });

  Future<SrsImportReport> importInto(
    SrsDbStore s,
    Uint8List bytes, {
    SrsAnkiImportOptions options = kFullOptions,
  }) => importAnkiPackage(
    store: s,
    bytes: bytes,
    storeMedia: storeMedia,
    options: options,
    zstdDecompress: (Uint8List b) => null,
  );

  Future<void> syncAll(List<SrsDbStore> stores) async {
    for (int round = 0; round < 3; round++) {
      for (final SrsDbStore s in stores) {
        await SrsSyncEngine(directory: dir, replica: s).syncOnce();
      }
    }
  }

  String basicNt(String profile) => SrsIds.noteType(profile, kBasic);
  String clozeNt(String profile) => SrsIds.noteType(profile, kCloze);

  test('① 导入：笔记 / 卡片 / 日志数正确，ID 按 SrsIds 规则；⑤ 遗忘卡写锚点为新卡；⑥ 1d 步长被截掉', () async {
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    final SrsImportReport rep = await importInto(s, legacyApkg(t));
    expect(rep.notesAdded, 3);
    expect(rep.cardsAdded, 5);
    expect(rep.latestFormat, isFalse);

    // 笔记类型 / 字段 / 模板身份。
    final String nt = basicNt(kProfile);
    final SrsNoteTypeView? v = await s.noteType(nt);
    expect(v, isNotNull);
    expect(v!.name, 'Basic (and reversed)');
    final String front = SrsIds.field(nt, 111);
    final String back = SrsIds.field(nt, 222);
    expect(v.fields.map((SrsFieldDef f) => f.id), <String>[front, back]);
    expect(v.fields.first.ankiNum, 111);
    final String t1 = SrsIds.template(nt, 333);
    final String t2 = SrsIds.templateByName(nt, 'Card 2');
    expect(v.templates.map((SrsTemplateDef x) => x.id), <String>[t1, t2]);
    expect(v.templates.first.front, '{{fld:$front}}<img src="h_a.png">');
    expect(v.css, contains('h__font.woff'));
    final SrsNoteTypeView? cv = await s.noteType(clozeNt(kProfile));
    expect(cv!.isCloze, isTrue);
    expect(cv.fields.first.id, SrsIds.fieldByName(clozeNt(kProfile), 'Text'));

    // 笔记：guid 原样，createdAt = 来源笔记 id，媒体引用改写。
    final String n1 = SrsIds.note(kProfile, 'g1');
    final SrsNoteView? note = await s.note(n1);
    expect(note!.guid, 'g1');
    expect(note.createdAt, ms(2026, 2, 28));
    expect(note.field(front), '猫<img src="h_a.png">');
    expect(note.tags, <String>['animal', 'n5']);
    expect(stored.toSet(), <String>{'a.png', '_font.woff'});

    // 卡片 ID 与牌组：首选牌组 = 第一张卡的牌组，其它卡单独记。
    final SrsDeckTree tree = await s.deckTree();
    String deckNamed(String full) => tree.decks
        .firstWhere((SrsDeckView d) => tree.fullName(d.id) == full)
        .id;
    final String c11 = SrsIds.card(n1, t1, 0);
    final String c12 = SrsIds.card(n1, t2, 0);
    expect(
      (await s.cardsOfNote(n1)).map((SrsCardCacheRow c) => c.id).toSet(),
      <String>{c11, c12},
    );
    expect(note.deckId, deckNamed('Lang::JP'));
    expect((await s.cardRow(c11))!.deckId, deckNamed('Lang::JP'));
    expect((await s.cardRow(c12))!.deckId, deckNamed('Lang'));
    // Anki 旧格式 decks JSON 的 collapsed → 牌组折叠；没写的缺省展开。
    expect(tree[deckNamed('Lang')]!.collapsed, isTrue);
    expect(tree[deckNamed('Lang::JP')]!.collapsed, isFalse);

    // revlog 日志 + 锚点（Filtered 也导入，但不是评分类）。
    final SrsCardHistory h11 = await s.history(c11);
    expect(h11.all.map((SrsReviewLog l) => l.id).toSet(), <String>{
      SrsIds.importedRevlog(c11, r1),
      SrsIds.importedRevlog(c11, r2),
      SrsIds.importedRevlog(c11, r3),
      SrsIds.importedRevlog(c11, r4),
      SrsIds.importAnchor(c11, r3),
    });
    final SrsReviewLog filtered = h11.all.firstWhere(
      (SrsReviewLog l) => l.ankiRevlogId == r4,
    );
    expect(filtered.reviewType, SrsReviewType.filtered);
    expect(filtered.isRatingReview, isFalse);
    final SrsReviewLog anchor = h11.all.firstWhere(
      (SrsReviewLog l) => l.kind == SrsLogKind.importAnchor,
    );
    expect(anchor.hlc, srsImportAnchorHlc(r3));
    expect(anchor.result!.dueDay, crtDay + 70);
    expect(anchor.result!.lastReviewedAt, r3);
    expect(anchor.result!.memory!.stability, 12.5);
    expect(anchor.extra['memAlg'], 'fsrs6');
    final SrsCardCacheRow row11 = (await s.cardRow(c11))!;
    expect(row11.queue, SrsQueue.review.wire);
    expect(row11.dueDay, crtDay + 70);
    expect(h11.effectiveRatings, hasLength(3));

    // 新卡：没有历史 → 无日志无锚点。
    expect((await s.history(c12)).all, isEmpty);

    // ⑤ 遗忘过的卡：最后一条是 Manual 重置 → 写锚点，结果是新卡。
    final String n2 = SrsIds.note(kProfile, 'g2');
    final String ct = cv.templates.single.id;
    final String c21 = SrsIds.card(n2, ct, 1);
    final String c22 = SrsIds.card(n2, ct, 2);
    final SrsCardHistory h21 = await s.history(c21);
    expect(h21.all, hasLength(3));
    final SrsReviewLog a21 = h21.all.firstWhere(
      (SrsReviewLog l) => l.kind == SrsLogKind.importAnchor,
    );
    expect(a21.id, SrsIds.importAnchor(c21, c21reset));
    expect(a21.result!.queue, SrsQueue.newCard);
    expect((await s.cardRow(c21))!.queue, SrsQueue.newCard.wire);
    expect((await s.cardRow(c22))!.suspended, isTrue);
    expect(rep.anchorsWritten, 2);
    expect(rep.reviewLogsImported, 6);

    // 未来时刻的卡：不导入排程，进报告。
    expect(rep.futureCards, <int>[31]);

    // ⑥ 步长 ≥ 1 天被截掉并进报告；同一预设：父牌组 own、子牌组 inherit。
    expect(rep.truncatedSteps, hasLength(1));
    expect(rep.truncatedSteps.single.preset, 'JP preset');
    expect(rep.truncatedSteps.single.removed, <double>[1440]);
    final SrsDeckView jp = tree[deckNamed('Lang::JP')]!;
    final SrsDeckView lang = tree[deckNamed('Lang')]!;
    expect(jp.learnSteps, <double>[1, 10]);
    expect(jp.ownParams, isFalse);
    expect(jp.newPerDay, 15);
    expect(lang.ownParams, isTrue);
    expect(lang.algorithmWire, 'fsrs6');
    expect(lang.fsrs6!.params, fsrs6Params);
    expect(lang.desiredRetention, 0.85);
    expect(tree.paramsOwner(jp.id).id, lang.id);
    expect(jsonEncode(rep.toJson()), contains('JP preset'));
  });

  test('② 两台设备各导入同一个包，同步后不出重复', () async {
    final SrsDbStore a = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    final SrsDbStore b = await openTestStore(
      profileUid: kProfile,
      deviceId: 'b',
      now: () => t,
    );
    await importInto(a, legacyApkg(t));
    t += 1000;
    await importInto(b, legacyApkg(t - 1000));
    await syncAll(<SrsDbStore>[a, b]);
    for (final SrsDbStore s in <SrsDbStore>[a, b]) {
      expect(await s.listNotes(), hasLength(3));
      expect(await s.noteTypes(), hasLength(4)); // Lapis + Fushi 卡片 + 2
      final List<String> names = <String>[
        for (final SrsDeckSummary d in await s.deckSummaries()) d.fullName,
      ];
      expect(names, <String>['Default', 'Lang', 'Lang::JP']);
      expect(await s.notesPendingDecision(), isEmpty);
      expect(await s.syncConflicts(), isEmpty);
      final String n1 = SrsIds.note(kProfile, 'g1');
      final String c11 = SrsIds.card(
        n1,
        SrsIds.template(basicNt(kProfile), 333),
        0,
      );
      expect((await s.history(c11)).all, hasLength(5));
    }
  });

  test('③ 重复导入不重复、不覆盖本地字段；「更新笔记：总是」才写新值', () async {
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    await importInto(s, legacyApkg(t));
    final String n1 = SrsIds.note(kProfile, 'g1');
    final String back = SrsIds.field(basicNt(kProfile), 222);
    await s.updateNote(n1, fieldsById: <String, String>{back: 'local edit'});
    final int logsBefore = (await s.exportAll())
        .whereType<SrsLogEvent>()
        .length;

    final SrsImportReport rep = await importInto(s, legacyApkg(t));
    expect(rep.notesAdded, 0);
    expect(rep.notesSkipped, 3);
    expect(await s.listNotes(), hasLength(3));
    expect((await s.note(n1))!.field(back), 'local edit');
    expect((await s.exportAll()).whereType<SrsLogEvent>().length, logsBefore);
    expect(await s.noteTypes(), hasLength(4));
    expect(await s.deckSummaries(), hasLength(3));

    final SrsImportReport upd = await importInto(
      s,
      legacyApkg(t),
      options: kFullOptions.copyWith(
        updateNotes: SrsImportUpdateCondition.always,
      ),
    );
    // 只有本机改过的那条内容不同；另两条内容一致，不写修改记录。
    expect(upd.notesUpdated, 1);
    expect(upd.notesSkipped, 2);
    expect((await s.note(n1))!.field(back), 'cat');
  });

  test('笔记类型 kind 不一致（普通 ↔ 填空）：不更新，笔记进冲突报告', () async {
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    await importInto(s, legacyApkg(t));
    final Map<String, Object?> models = legacyModels();
    (models['$kBasic']! as Map<String, Object?>)['type'] = 1;
    final Uint8List bytes = zipOf(<String, List<int>>{
      'collection.anki2': buildLegacyCollection(
        crtSecs: crtSecs,
        conf: <String, Object?>{},
        models: models,
        decks: legacyDecks(),
        dconf: legacyDconf(),
        notes: fixtureNotes(t),
      ),
    });
    final SrsImportReport rep = await importInto(s, bytes);
    expect(
      rep.conflictNotes.map((SrsImportNoteIssue i) => i.guid).toSet(),
      <String>{'g1', 'g3'},
    );
    expect(
      rep.conflictNotes.first.reason,
      SrsImportIssueReason.noteTypeKindMismatch,
    );
    expect((await s.noteType(basicNt(kProfile)))!.isCloze, isFalse);
  });

  test('④ 往返：新建 + 复习 → 导出 → 回导同 profile：不重复、ID 不变、不写锚点', () async {
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    final String noteId = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '食べる',
        srsLapisFieldId(kProfile, 'ExpressionReading'): 'たべる',
      },
    );
    final String cardId = (await s.cardsOfNote(noteId)).single.id;
    t += 60000;
    final SrsReviewLog review = await s.answer(cardId, 3);
    t += 86400000;
    final Map<String, String> fieldsBefore = (await s.note(noteId))!.fields;
    final SrsCardCacheRow before = (await s.cardRow(cardId))!;

    final Uint8List pkg = await exportAnkiPackage(store: s);

    // 导出的集合本身：笔记类型 id = ankiNum，revlog id = occurredAt。
    final SrsAnkiPackage p = SrsAnkiPackage.open(
      pkg,
      zstd: (Uint8List b) => null,
    );
    expect(p.fushiExt!['format'], 'fushi-ext');
    final SrsAnkiCollection col = await SrsAnkiCollection.open(
      p.collectionBytes,
    );
    try {
      expect(
        col.noteTypes.keys.single,
        SrsIds.builtinNoteTypeAnkiNum(kSrsBuiltinLapisKey),
      );
      final List<Object?> rev = col.db
          .select('SELECT id FROM revlog')
          .map((Row r) => r['id'])
          .toList();
      expect(rev, <Object?>[review.occurredAt]);
      expect(
        col.db.select('SELECT guid FROM notes').single['guid'],
        (await s.note(noteId))!.guid,
      );
    } finally {
      await col.close();
    }

    final SrsImportReport rep = await importInto(s, pkg);
    expect(rep.notesAdded, 0);
    expect(rep.notesSkipped, 1);
    expect(rep.anchorsWritten, 0);
    expect(rep.reviewLogsImported, 0);
    expect(rep.revlogsVerifiedByExt, 1);
    expect(await s.listNotes(), hasLength(1));
    expect(await s.noteTypes(), hasLength(2));
    expect((await s.note(noteId))!.fields, fieldsBefore);
    expect((await s.cardsOfNote(noteId)).single.id, cardId);
    final SrsCardHistory h = await s.history(cardId);
    expect(h.all.map((SrsReviewLog l) => l.id), <String>[review.id]);
    final SrsCardCacheRow after = (await s.cardRow(cardId))!;
    expect(after.queue, before.queue);
    expect(after.dueAt, before.dueAt);

    // 另一个 profile：日志 ID 用 remappedLog 重映射，同样不写锚点。
    final SrsDbStore other = await openTestStore(
      profileUid: kProfile2,
      deviceId: 'b',
      now: () => t,
    );
    final SrsImportReport rep2 = await importInto(other, pkg);
    expect(rep2.notesAdded, 1);
    expect(rep2.anchorsWritten, 0);
    expect(rep2.fushiLogsRestored, 1);
    final String noteId2 = SrsIds.note(kProfile2, (await s.note(noteId))!.guid);
    final String cardId2 = (await other.cardsOfNote(noteId2)).single.id;
    expect((await other.note(noteId2))!.noteTypeId, other.lapisNoteTypeId);
    final SrsCardHistory h2 = await other.history(cardId2);
    expect(h2.all.single.id, SrsIds.remappedLog(cardId2, review.id));
    expect((await other.cardRow(cardId2))!.queue, before.queue);
  });

  test('Anki 端在导出之后又复习：新 revlog 照常导入并写锚点', () async {
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    final String noteId = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '見る',
      },
    );
    final String cardId = (await s.cardsOfNote(noteId)).single.id;
    await s.answer(cardId, 3);
    t += 86400000;
    final Uint8List pkg = await exportAnkiPackage(store: s);
    // 在导出的集合里追加一条 Anki 端复习，重新打包（保留 fushi-ext）。
    final SrsAnkiPackage p = SrsAnkiPackage.open(
      pkg,
      zstd: (Uint8List b) => null,
    );
    final int cid = SrsIds.ankiNumericId(cardId);
    final int ankiReview = t - 3600000;
    final Uint8List patched = patchSqlite(p.collectionBytes, (Database db) {
      db.execute('INSERT INTO revlog VALUES (?,?,?,?,?,?,?,?,?)', <Object?>[
        ankiReview,
        cid,
        -1,
        3,
        5,
        1,
        2500,
        4000,
        1,
      ]);
    });
    final Uint8List repacked = zipOf(<String, List<int>>{
      'collection.anki21': patched,
      'media': utf8.encode('{}'),
      'fushi-ext': utf8.encode(jsonEncode(p.fushiExt)),
    });
    final SrsImportReport rep = await importInto(s, repacked);
    expect(rep.revlogsVerifiedByExt, 1);
    expect(rep.revlogsNotInExt, 1);
    expect(rep.reviewLogsImported, 1);
    expect(rep.anchorsWritten, 1);
    final SrsCardHistory h = await s.history(cardId);
    expect(h.lastEffective!.kind, SrsLogKind.importAnchor);
    expect(h.lastEffective!.occurredAt, ankiReview);
  });

  test('牌组折叠：新格式读 Deck.Common.study_collapsed；导出写回 collapsed，往返不丢', () async {
    final Uint8List collection = buildSqlite((Database db) {
      db.execute(legacySchema);
      db.execute(schema18Extra);
      db.execute(
        "INSERT INTO col VALUES (1,?,0,0,18,0,0,0,'','','','','')",
        <Object?>[crtSecs],
      );
      final Uint8List normal =
          (PbWriter()..message(1, PbWriter()..varint(1, 1))).toBytes();
      db.execute('INSERT INTO decks VALUES (1,?,0,0,?,?)', <Object?>[
        'Default',
        Uint8List(0),
        normal,
      ]);
      // study_collapsed = 1、browser_collapsed = 2（只认前者）。
      db.execute('INSERT INTO decks VALUES (78,?,0,0,?,?)', <Object?>[
        'Vocab',
        (PbWriter()..varint(1, 1)).toBytes(),
        normal,
      ]);
      db.execute('INSERT INTO decks VALUES (79,?,0,0,?,?)', <Object?>[
        'Other',
        (PbWriter()..varint(2, 1)).toBytes(),
        normal,
      ]);
    });
    final SrsAnkiCollection col = await SrsAnkiCollection.open(collection);
    try {
      expect(col.decks[78]!.collapsed, isTrue);
      expect(col.decks[79]!.collapsed, isFalse);
      expect(col.decks[1]!.collapsed, isFalse);
    } finally {
      await col.close();
    }

    // 往返：Fushi 里收起 → 导出 .apkg（decks JSON collapsed）→ 导入另一个 profile 仍收起。
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    final String child = await s.ensureDeckPath('Book::Ch1');
    final String parent = (await s.deckTree()).parentOf(child)!;
    await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): '本',
      },
      deckId: child,
    );
    await s.setDeckCollapsed(parent, true);
    final Uint8List pkg = await exportAnkiPackage(store: s);
    final SrsAnkiPackage p = SrsAnkiPackage.open(
      pkg,
      zstd: (Uint8List b) => null,
    );
    final SrsAnkiCollection exported = await SrsAnkiCollection.open(
      p.collectionBytes,
    );
    try {
      final Map<String, bool> byName = <String, bool>{
        for (final SrsAnkiDeck d in exported.decks.values) d.name: d.collapsed,
      };
      expect(byName['Book'], isTrue);
      expect(byName['Book::Ch1'], isFalse);
    } finally {
      await exported.close();
    }
    final SrsDbStore other = await openTestStore(
      profileUid: kProfile2,
      deviceId: 'b',
      now: () => t,
    );
    await importInto(other, pkg);
    final SrsDeckTree tree = await other.deckTree();
    bool collapsedOf(String full) => tree.decks
        .firstWhere((SrsDeckView d) => tree.fullName(d.id) == full)
        .collapsed;
    expect(collapsedOf('Book'), isTrue);
    expect(collapsedOf('Book::Ch1'), isFalse);
  });

  test('protobuf 读取器：varint / string / float / packed / 嵌套 / 损坏', () {
    final Uint8List bytes = Uint8List.fromList(<int>[
      0x08, 0x96, 0x01, // 1: varint 150
      0x12, 0x02, 0x68, 0x69, // 2: "hi"
      0x1d, 0x00, 0x00, 0xc0, 0x3f, // 3: fixed32 1.5
      0x22, 0x08, 0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x20, 0x41, // 4: [1,10]
      0x52, 0x02, 0x08, 0x07, // 10: {1: 7}
      0x48, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, // 9: -1
    ]);
    final SrsProtoMessage m = SrsProtoMessage.parse(bytes);
    expect(m.intOf(1), 150);
    expect(m.stringOf(2), 'hi');
    expect(m.floatOf(3), 1.5);
    expect(m.floatsOf(4), <double>[1, 10]);
    expect(m.messageOf(10).intOf(1), 7);
    expect(m.optInt(9), -1);
    expect(m.optInt(11), isNull);
    expect(m.has(10), isTrue);
    expect(
      () => SrsProtoMessage.parse(Uint8List.fromList(<int>[0x12, 0x05, 0x68])),
      throwsA(isA<SrsProtoFormatException>()),
    );
    expect(
      () => SrsProtoMessage.parse(Uint8List.fromList(<int>[0x0b])),
      throwsA(isA<SrsProtoFormatException>()),
    );
  });

  test('新格式没有排程内核：明确报 needsKernel', () async {
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    final Uint8List bytes = zipOf(<String, List<int>>{
      'collection.anki21b': <int>[0x28, 0xB5, 0x2F, 0xFD, 0, 0, 0],
    });
    await expectLater(
      importInto(s, bytes),
      throwsA(
        isA<SrsImportException>().having(
          (SrsImportException e) => e.code,
          'code',
          SrsImportException.needsKernel,
        ),
      ),
    );
  });

  test('⑦ 新格式（anki21b + protobuf 配置 + zstd 媒体）端到端', () async {
    final FushiFsrs? lib = FushiFsrs.tryLoad(
      libraryPath: fushiFsrsPrebuiltPath(),
    );
    final Uint8List? probe = await pythonZstd(<int>[1, 2, 3]);
    if (lib == null || probe == null) {
      markTestSkipped(
        'new-format e2e skipped: fushi_fsrs native library '
        '${lib == null ? 'not found' : 'ok'}, python zstandard '
        '${probe == null ? 'not found' : 'ok'}',
      );
      return;
    }
    final Uint8List collection = buildSqlite((Database db) {
      db.execute(legacySchema);
      db.execute(schema18Extra);
      db.execute(
        "INSERT INTO col VALUES (1,?,0,0,18,0,0,0,'','','','','')",
        <Object?>[crtSecs],
      );
      void cfg(String k, Object v) => db.execute(
        'INSERT INTO config VALUES (?,0,0,?)',
        <Object?>[k, utf8.encode(jsonEncode(v))],
      );
      cfg('fsrs', true);
      cfg('rollover', 4);
      // 笔记类型：id 5000，original_id 4242（→ ankiNum 4242）。
      db.execute("INSERT INTO notetypes VALUES (5000,'Vocab',0,0,?)", <Object?>[
        (PbWriter()
              ..varint(1, 0)
              ..string(3, '.card{}')
              ..varint(10, 4242))
            .toBytes(),
      ]);
      db.execute("INSERT INTO fields VALUES (5000,0,'Word',?)", <Object?>[
        (PbWriter()..varint(9, 9001)).toBytes(),
      ]);
      db.execute("INSERT INTO fields VALUES (5000,1,'Meaning',?)", <Object?>[
        (PbWriter()..varint(9, 9002)).toBytes(),
      ]);
      db.execute(
        "INSERT INTO templates VALUES (5000,0,'Recognition',0,0,?)",
        <Object?>[
          (PbWriter()
                ..string(1, '{{Word}}<img src="pic.jpg">')
                ..string(2, '{{Meaning}}')
                ..varint(8, 7001))
              .toBytes(),
        ],
      );
      db.execute("INSERT INTO decks VALUES (1,'Default',0,0,x'',?)", <Object?>[
        (PbWriter()..message(1, PbWriter()..varint(1, 1))).toBytes(),
      ]);
      db.execute('INSERT INTO decks VALUES (77,?,0,0,x\'\',?)', <Object?>[
        'Vocab\x1fCore',
        (PbWriter()..message(1, PbWriter()..varint(1, 3))).toBytes(),
      ]);
      db.execute('INSERT INTO decks VALUES (78,?,0,0,x\'\',?)', <Object?>[
        'Vocab',
        (PbWriter()..message(1, PbWriter()..varint(1, 1))).toBytes(),
      ]);
      db.execute(
        "INSERT INTO deck_config VALUES (1,'Default',0,0,?)",
        <Object?>[
          (PbWriter()..packedFloats(1, <double>[1, 10])).toBytes(),
        ],
      );
      db.execute(
        "INSERT INTO deck_config VALUES (3,'Core preset',0,0,?)",
        <Object?>[
          (PbWriter()
                ..packedFloats(1, <double>[2, 20])
                ..packedFloats(2, <double>[15])
                ..packedFloats(6, fsrs6Params)
                ..varint(9, 30)
                ..float(37, 0.9))
              .toBytes(),
        ],
      );
      insertNotes(db, <FxNote>[
        FxNote(
          id: ms(2026, 5, 1),
          guid: 'nf1',
          mid: 5000,
          fields: <String>['犬<img src="pic.jpg">', 'dog'],
          cards: <FxCard>[
            FxCard(
              id: 501,
              ord: 0,
              did: 77,
              type: 2,
              queue: 2,
              due: 200,
              ivl: 20,
              factor: 2300,
              reps: 4,
              revlog: <FxRevlog>[
                FxRevlog(ms(2026, 5, 2), type: 0, ease: 3, ivl: 1),
                FxRevlog(ms(2026, 5, 10), type: 1, ease: 3, ivl: 20),
              ],
            ),
          ],
        ),
      ]);
    });
    final PbWriter manifest = PbWriter()
      ..message(
        1,
        PbWriter()
          ..string(1, 'pic.jpg')
          ..varint(2, 3),
      );
    final Uint8List pkg = zipOf(<String, List<int>>{
      'collection.anki21b': (await pythonZstd(collection))!,
      'media': (await pythonZstd(manifest.toBytes()))!,
      '0': (await pythonZstd(<int>[9, 8, 7]))!,
    });

    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    final List<int> mediaBytes = <int>[];
    final SrsImportReport rep = await importAnkiPackage(
      store: s,
      bytes: pkg,
      options: kFullOptions,
      storeMedia: (String name, Uint8List b) async {
        mediaBytes.addAll(b);
        return 'h_$name';
      },
      zstdDecompress: (Uint8List b) =>
          FfiFsrsEngine.zstdDecompress(b, library: lib),
    );
    expect(rep.latestFormat, isTrue);
    expect(rep.notesAdded, 1);
    expect(mediaBytes, <int>[9, 8, 7]);
    final String nt = SrsIds.noteType(kProfile, 4242);
    final SrsNoteTypeView v = (await s.noteType(nt))!;
    expect(v.fields.map((SrsFieldDef f) => f.id), <String>[
      SrsIds.field(nt, 9001),
      SrsIds.field(nt, 9002),
    ]);
    expect(v.css, '.card{}');
    final String tpl = SrsIds.template(nt, 7001);
    expect(v.templates.single.id, tpl);
    expect(
      v.templates.single.front,
      '{{fld:${SrsIds.field(nt, 9001)}}}<img src="h_pic.jpg">',
    );
    final String noteId = SrsIds.note(kProfile, 'nf1');
    expect(
      (await s.note(noteId))!.field(SrsIds.field(nt, 9001)),
      '犬<img src="h_pic.jpg">',
    );
    final String cardId = SrsIds.card(noteId, tpl, 0);
    final SrsCardCacheRow row = (await s.cardRow(cardId))!;
    expect(row.dueDay, crtDay + 200);
    expect((await s.history(cardId)).all, hasLength(3));
    final SrsDeckTree tree = await s.deckTree();
    final SrsDeckView core = tree.decks.firstWhere(
      (SrsDeckView d) => tree.fullName(d.id) == 'Vocab::Core',
    );
    expect(row.deckId, core.id);
    expect(core.ownParams, isTrue);
    expect(core.learnSteps, <double>[2, 20]);
    expect(core.newPerDay, 30);
    expect(core.algorithmWire, 'fsrs6');
    expect(core.desiredRetention, closeTo(0.9, 1e-6));
    expect(core.fsrs6!.params.first, closeTo(fsrs6Params.first, 1e-6));
  });

  group('导入选项（对齐 Anki ImportAnkiPackageOptions）', () {
    test('默认值与 Anki 相同；JSON 往返、缺项 / 坏值回落默认', () {
      const SrsAnkiImportOptions d = SrsAnkiImportOptions();
      expect(d.mergeNoteTypes, isFalse);
      expect(d.updateNotes, SrsImportUpdateCondition.ifNewer);
      expect(d.updateNoteTypes, SrsImportUpdateCondition.ifNewer);
      expect(d.withScheduling, isFalse);
      expect(d.withDeckConfigs, isFalse);
      expect(SrsAnkiImportOptions.fromJson(const <String, Object?>{}), d);
      expect(
        SrsAnkiImportOptions.fromJson(<String, Object?>{
          'updateNotes': 'bogus',
          'withScheduling': 'yes',
        }),
        d,
      );
      expect(
        SrsAnkiImportOptions.fromJson(kFullOptions.toJson()),
        kFullOptions,
      );
    });

    Future<SrsDbStore> seeded() async {
      final SrsDbStore s = await openTestStore(
        profileUid: kProfile,
        deviceId: 'a',
        now: () => t,
      );
      await importInto(s, legacyApkg(t));
      return s;
    }

    test('更新笔记：较新时按来源 mod 与本机最后修改比；总是 / 从不', () async {
      final String n1 = SrsIds.note(kProfile, 'g1');
      final String back = SrsIds.field(basicNt(kProfile), 222);
      final int localEditAt = t + 60000;
      // 来源 g1 的背面改成 neko，mod 分别早于 / 晚于本机修改。
      Uint8List withMod(int modMs) => customApkg(
        t,
        patch: (Database db) => db.execute(
          "UPDATE notes SET mod = ?, flds = ? WHERE guid = 'g1'",
          <Object?>[modMs ~/ 1000, '猫<img src="a.png">\x1fneko'],
        ),
      );
      final Uint8List older = withMod(localEditAt - 30000);
      final Uint8List newer = withMod(localEditAt + 3600000);

      Future<String> run(Uint8List pkg, SrsImportUpdateCondition c) async {
        t = ms(2026, 10, 14, 12);
        final SrsDbStore s = await seeded();
        t = localEditAt;
        await s.updateNote(
          n1,
          fieldsById: <String, String>{back: 'local edit'},
        );
        t += 7200000;
        await importInto(
          s,
          pkg,
          options: kFullOptions.copyWith(updateNotes: c),
        );
        return (await s.note(n1))!.field(back);
      }

      expect(await run(older, SrsImportUpdateCondition.ifNewer), 'local edit');
      expect(await run(newer, SrsImportUpdateCondition.ifNewer), 'neko');
      expect(await run(older, SrsImportUpdateCondition.always), 'neko');
      expect(await run(newer, SrsImportUpdateCondition.never), 'local edit');
    });

    test('更新笔记模板：较新时按来源 mod 比；总是 / 从不', () async {
      final String nt = basicNt(kProfile);
      final String tpl = SrsIds.template(nt, 333);
      Uint8List withMod(int modMs) {
        final Map<String, Object?> models = legacyModels();
        final Map<String, Object?> basic =
            models['$kBasic']! as Map<String, Object?>;
        basic['mod'] = modMs ~/ 1000;
        basic['css'] = '.new{}';
        ((basic['tmpls']! as List<Object?>).first!
                as Map<String, Object?>)['qfmt'] =
            'NEW {{Front}}';
        return customApkg(t, models: models);
      }

      Future<SrsNoteTypeView> run(
        int Function(int importedAt) modOf,
        SrsImportUpdateCondition c,
      ) async {
        t = ms(2026, 10, 14, 12);
        final SrsDbStore s = await seeded();
        final int importedAt = t;
        t += 3600000;
        await importInto(
          s,
          withMod(modOf(importedAt)),
          options: kFullOptions.copyWith(updateNoteTypes: c),
        );
        return (await s.noteType(nt))!;
      }

      int older(int at) => at - 86400000;
      int newer(int at) => at + 1800000;

      SrsTemplateDef card1(SrsNoteTypeView v) =>
          v.templates.firstWhere((SrsTemplateDef x) => x.id == tpl);
      final SrsNoteTypeView a = await run(
        older,
        SrsImportUpdateCondition.ifNewer,
      );
      expect(card1(a).front, isNot(startsWith('NEW')));
      expect(a.css, isNot('.new{}'));
      final SrsNoteTypeView b = await run(
        newer,
        SrsImportUpdateCondition.ifNewer,
      );
      expect(card1(b).front, startsWith('NEW'));
      expect(b.css, '.new{}');
      final SrsNoteTypeView c = await run(
        older,
        SrsImportUpdateCondition.always,
      );
      expect(card1(c).front, startsWith('NEW'));
      final SrsNoteTypeView d = await run(
        newer,
        SrsImportUpdateCondition.never,
      );
      expect(card1(d).front, isNot(startsWith('NEW')));
    });

    test('合并笔记模板：开 = 并进本机那一个；关 = 结构不同另建确定性副本，已有笔记记冲突', () async {
      Uint8List withExtraField() {
        final Map<String, Object?> models = legacyModels();
        final Map<String, Object?> basic =
            models['$kBasic']! as Map<String, Object?>;
        (basic['flds']! as List<Object?>).add(<String, Object?>{
          'name': 'Notes',
          'ord': 2,
          'id': 444,
        });
        return customApkg(
          t,
          models: models,
          patch: (Database db) {
            db.execute(
              'UPDATE notes SET flds = flds || ? WHERE mid = ?',
              <Object?>['\x1fmemo', kBasic],
            );
            db.execute(
              'INSERT INTO notes VALUES (?,?,?,?,?,?,?,?,?,?,?)',
              <Object?>[
                ms(2026, 3, 4),
                'g4',
                kBasic,
                0,
                0,
                '',
                '新\x1fnew\x1fm',
                '新',
                0,
                0,
                '',
              ],
            );
            db.execute(
              'INSERT INTO cards VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
              <Object?>[
                41,
                ms(2026, 3, 4),
                1,
                0,
                0,
                0,
                0,
                0,
                9,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                '',
              ],
            );
          },
        );
      }

      final String nt = basicNt(kProfile);
      final String g1 = SrsIds.note(kProfile, 'g1');
      final String g4 = SrsIds.note(kProfile, 'g4');

      // 合并。
      final SrsDbStore m = await seeded();
      final SrsImportReport mr = await importInto(
        m,
        withExtraField(),
        options: kFullOptions.copyWith(mergeNoteTypes: true),
      );
      expect(mr.noteTypesDuplicated, isEmpty);
      expect((await m.noteType(nt))!.fields, hasLength(3));
      expect((await m.note(g4))!.noteTypeId, nt);
      expect(await m.noteTypes(), hasLength(4));

      // 不合并。
      final SrsDbStore s = await seeded();
      final SrsImportReport r = await importInto(
        s,
        withExtraField(),
        options: kFullOptions.copyWith(mergeNoteTypes: false),
      );
      expect(r.noteTypesDuplicated, <String>['Basic (and reversed)']);
      expect((await s.noteType(nt))!.fields, hasLength(2));
      final String dup = (await s.note(g4))!.noteTypeId;
      expect(dup, isNot(nt));
      expect((await s.noteType(dup))!.fields, hasLength(3));
      expect((await s.noteType(dup))!.name, 'Basic (and reversed)');
      expect((await s.note(g1))!.noteTypeId, nt);
      expect(
        r.conflictNotes
            .where(
              (SrsImportNoteIssue i) =>
                  i.reason == SrsImportIssueReason.noteTypeChanged,
            )
            .map((SrsImportNoteIssue i) => i.guid)
            .toSet(),
        <String>{'g1', 'g3'},
      );
      expect(await s.noteTypes(), hasLength(5));
      // 同一份包再导入：回到同一个副本，不再新建。
      final SrsImportReport again = await importInto(
        s,
        withExtraField(),
        options: kFullOptions.copyWith(mergeNoteTypes: false),
      );
      expect(again.noteTypesDuplicated, isEmpty);
      expect(await s.noteTypes(), hasLength(5));
      // 结构相同的包（原包）不合并时照常进本机那一个。
      final SrsImportReport same = await importInto(
        s,
        legacyApkg(t),
        options: kFullOptions.copyWith(mergeNoteTypes: false),
      );
      expect(same.noteTypesDuplicated, isEmpty);
      expect(same.conflictNotes, isEmpty);

      // 两台设备不合并导入同一个包：副本 ID 相同（铁律 C）。
      final SrsDbStore other = await openTestStore(
        profileUid: kProfile,
        deviceId: 'b',
        now: () => t,
      );
      await importInto(other, legacyApkg(t));
      await importInto(
        other,
        withExtraField(),
        options: kFullOptions.copyWith(mergeNoteTypes: false),
      );
      expect((await other.note(g4))!.noteTypeId, dup);
    });

    test('不含排程：全部作为新卡、无复习日志、无锚点、不暂停、去掉 leech 标签', () async {
      final SrsDbStore s = await openTestStore(
        profileUid: kProfile,
        deviceId: 'a',
        now: () => t,
      );
      final SrsImportReport rep = await importInto(
        s,
        customApkg(
          t,
          patch: (Database db) => db.execute(
            "UPDATE notes SET tags = ' animal leech Marked n5 ' WHERE guid = 'g1'",
          ),
        ),
        options: const SrsAnkiImportOptions(withDeckConfigs: true),
      );
      expect(rep.notesAdded, 3);
      expect(rep.cardsAdded, 5);
      expect((await s.exportAll()).whereType<SrsLogEvent>(), isEmpty);
      expect(rep.reviewLogsImported, 0);
      expect(rep.anchorsWritten, 0);
      expect(rep.futureCards, isEmpty);
      // 11（复习卡）、22（暂停）、31（复习卡）。
      expect(rep.cardsResetToNew, 3);
      expect(rep.reviewLogsSkipped, 7);
      for (final SrsNoteCacheRow n in await s.listNotes()) {
        for (final SrsCardCacheRow c in await s.cardsOfNote(n.id)) {
          expect(c.queue, SrsQueue.newCard.wire);
          expect(c.suspended, isFalse);
        }
      }
      expect((await s.note(SrsIds.note(kProfile, 'g1')))!.tags, <String>[
        'animal',
        'n5',
      ]);
      expect(jsonEncode(rep.toJson()), contains('"cardsResetToNew":3'));
    });

    test('不含牌组预设：新建牌组用本机默认设置', () async {
      final SrsDbStore s = await openTestStore(
        profileUid: kProfile,
        deviceId: 'a',
        now: () => t,
      );
      final SrsImportReport rep = await importInto(
        s,
        legacyApkg(t),
        options: kFullOptions.copyWith(withDeckConfigs: false),
      );
      expect(rep.deckPresetsSkipped, 1);
      expect(rep.truncatedSteps, isEmpty);
      final SrsDeckTree tree = await s.deckTree();
      final SrsDeckView lang = tree.decks.firstWhere(
        (SrsDeckView d) => tree.fullName(d.id) == 'Lang',
      );
      final SrsDeckView jp = tree.decks.firstWhere(
        (SrsDeckView d) => tree.fullName(d.id) == 'Lang::JP',
      );
      expect(lang.learnSteps, SrsDeckView.defaultLearnSteps);
      expect(lang.newPerDay, 20);
      expect(lang.fsrs6, isNull);
      expect(lang.desiredRetention, 0.8);
      expect(jp.ownParams, isFalse);
      // 排程照常导入。
      expect(rep.anchorsWritten, 2);
    });
  });

  test('BUG-3455：新格式预设的 proto3 零值（上限 0 / 开关 false）导入后保持 0 / false', () async {
    // schema 18 的表放进 collection.anki21（不走 zstd）：解码路径与 anki21b 相同。
    final Uint8List collection = buildSqlite((Database db) {
      db.execute(legacySchema);
      db.execute(schema18Extra);
      db.execute(
        "INSERT INTO col VALUES (1,?,0,0,18,0,0,0,'','','','','')",
        <Object?>[crtSecs],
      );
      db.execute('INSERT INTO config VALUES (?,0,0,?)', <Object?>[
        'fsrs',
        utf8.encode(jsonEncode(true)),
      ]);
      db.execute("INSERT INTO notetypes VALUES (6000,'Z',0,0,?)", <Object?>[
        (PbWriter()..varint(10, 6060)).toBytes(),
      ]);
      db.execute("INSERT INTO fields VALUES (6000,0,'F',?)", <Object?>[
        (PbWriter()..varint(9, 6001)).toBytes(),
      ]);
      db.execute("INSERT INTO templates VALUES (6000,0,'C',0,0,?)", <Object?>[
        (PbWriter()
              ..string(1, '{{F}}')
              ..string(2, '{{F}}')
              ..varint(8, 6002))
            .toBytes(),
      ]);
      // 牌组 90 用预设 4；牌组 91 的 Normal 没写 config_id（proto3 零值）。
      db.execute("INSERT INTO decks VALUES (90,'Zero',0,0,x'',?)", <Object?>[
        (PbWriter()..message(1, PbWriter()..varint(1, 4))).toBytes(),
      ]);
      db.execute("INSERT INTO decks VALUES (91,'NoConf',0,0,x'',?)", <Object?>[
        (PbWriter()..message(1, PbWriter())).toBytes(),
      ]);
      db.execute(
        "INSERT INTO deck_config VALUES (1,'Default',0,0,?)",
        <Object?>[
          (PbWriter()
                ..packedFloats(1, <double>[1, 10])
                ..varint(9, 25)
                ..varint(10, 250))
              .toBytes(),
        ],
      );
      // 预设 4：new_per_day / reviews_per_day = 0、rwkv 关、无最大间隔 / 保留率——
      // proto3 一个都不写。
      db.execute(
        "INSERT INTO deck_config VALUES (4,'Zero preset',0,0,?)",
        <Object?>[
          (PbWriter()..packedFloats(1, <double>[3])).toBytes(),
        ],
      );
      insertNotes(db, <FxNote>[
        FxNote(
          id: ms(2026, 5, 1),
          guid: 'z1',
          mid: 6000,
          fields: <String>['a'],
          cards: <FxCard>[FxCard(id: 901, ord: 0, did: 90)],
        ),
        FxNote(
          id: ms(2026, 5, 2),
          guid: 'z2',
          mid: 6000,
          fields: <String>['b'],
          cards: <FxCard>[FxCard(id: 902, ord: 0, did: 91)],
        ),
      ]);
    });

    final SrsAnkiCollection col = await SrsAnkiCollection.open(collection);
    try {
      final SrsAnkiPreset zero = col.presets[4]!;
      expect(zero.newPerDay, 0);
      expect(zero.reviewsPerDay, 0);
      expect(zero.rwkvEnabled, isFalse);
      expect(zero.maxIntervalDays, 0);
      expect(zero.desiredRetention, 0);
      expect(zero.fsrsVersion, isNull);
      expect(zero.fsrs6Params, isEmpty);
      // config_id 缺失 = 0 → 按 Anki 回落默认预设 1。
      expect(col.decks[91]!.configId, 1);
      expect(col.decks[90]!.configId, 4);
    } finally {
      await col.close();
    }

    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    await importInto(
      s,
      zipOf(<String, List<int>>{
        'collection.anki21': collection,
        'media': utf8.encode('{}'),
      }),
    );
    final SrsDeckTree tree = await s.deckTree();
    SrsDeckView deck(String name) =>
        tree.decks.firstWhere((SrsDeckView d) => tree.fullName(d.id) == name);
    expect(deck('Zero').newPerDay, 0);
    expect(deck('Zero').reviewsPerDay, 0);
    expect(deck('Zero').learnSteps, <double>[3]);
    expect(deck('Zero').maxIntervalDays, 36500); // 0 = 无效，不写，走默认。
    expect(deck('NoConf').newPerDay, 25);
    expect(deck('NoConf').reviewsPerDay, 250);
  });

  group('牌组音频设置（Anki autoplay / replayq）', () {
    test('旧格式 JSON：预设的 autoplay / replayq 写到 own 牌组，子牌组随继承', () async {
      final Map<String, Object?> dconf = legacyDconf();
      (dconf['2']! as Map<String, Object?>)
        ..['autoplay'] = false
        ..['replayq'] = false;
      final Uint8List pkg = zipOf(<String, List<int>>{
        'collection.anki21': buildLegacyCollection(
          crtSecs: crtSecs,
          conf: <String, Object?>{'rollover': 4, 'localOffset': 0},
          models: legacyModels(),
          decks: legacyDecks(),
          dconf: dconf,
          notes: fixtureNotes(t),
        ),
        'media': utf8.encode('{}'),
      });
      final SrsDbStore s = await openTestStore(
        profileUid: kProfile,
        deviceId: 'a',
        now: () => t,
      );
      await importInto(s, pkg);
      final SrsDeckTree tree = await s.deckTree();
      final String lang = srsImportedDeckId(kProfile, 'Lang');
      final String jp = srsImportedDeckId(kProfile, 'Lang::JP');
      expect(tree[lang]!.autoplayAudio, isFalse);
      expect(tree[lang]!.replayQuestionAudio, isFalse);
      expect(tree[jp]!.ownParams, isFalse, reason: '同一预设 → 继承');
      expect(tree.paramsOwner(jp).autoplayAudio, isFalse);
      // 预设 1（没写这两项）= Anki 缺省：开。
      expect(tree[s.defaultDeckId]!.autoplayAudio, isTrue);
      expect(tree[s.defaultDeckId]!.replayQuestionAudio, isTrue);
    });

    test(
      '新格式 protobuf：disable_autoplay = 23、skip_question_when_replaying_answer = 26',
      () async {
        final Uint8List bytes = buildSqlite((Database db) {
          db.execute(legacySchema);
          db.execute(schema18Extra);
          db.execute(
            "INSERT INTO col VALUES (1,?,0,0,18,0,0,0,'','','','','')",
            <Object?>[crtSecs],
          );
          db.execute(
            "INSERT INTO deck_config VALUES (1,'Default',0,0,?)",
            <Object?>[
              (PbWriter()..packedFloats(1, <double>[1, 10])).toBytes(),
            ],
          );
          db.execute(
            "INSERT INTO deck_config VALUES (3,'Quiet',0,0,?)",
            <Object?>[
              (PbWriter()
                    ..varint(23, 1)
                    ..varint(26, 1))
                  .toBytes(),
            ],
          );
        });
        final SrsAnkiCollection col = await SrsAnkiCollection.open(bytes);
        try {
          expect(col.presets[1]!.autoplay, isTrue);
          expect(col.presets[1]!.replayQuestion, isTrue);
          expect(col.presets[3]!.autoplay, isFalse);
          expect(col.presets[3]!.replayQuestion, isFalse);
        } finally {
          await col.close();
        }
      },
    );

    test('往返：导出写真实值（dconf autoplay / replayq），回导到另一 profile 还原', () async {
      final SrsDbStore s = await openTestStore(
        profileUid: kProfile,
        deviceId: 'a',
        now: () => t,
      );
      final String deck = await s.createDeck('Listening');
      await s.editFields(SrsEntityKind.deck, deck, <String, Object?>{
        SrsFieldKeys.deckAutoplay: false,
        SrsFieldKeys.deckReplayQuestion: false,
      });
      await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        deckId: deck,
        fieldsById: <String, String>{
          srsLapisFieldId(kProfile, 'Expression'): '聞く',
        },
      );
      final Uint8List pkg = await exportAnkiPackage(store: s);
      final SrsAnkiPackage p = SrsAnkiPackage.open(
        pkg,
        zstd: (Uint8List b) => null,
      );
      final SrsAnkiCollection col = await SrsAnkiCollection.open(
        p.collectionBytes,
      );
      try {
        final SrsAnkiDeck exported = col.decks.values.singleWhere(
          (SrsAnkiDeck d) => d.name == 'Listening',
        );
        final SrsAnkiPreset preset = col.presets[exported.configId]!;
        expect(preset.autoplay, isFalse);
        expect(preset.replayQuestion, isFalse);
        final SrsAnkiPreset def = col.presets[1]!;
        expect(def.autoplay, isTrue, reason: '没改过的牌组照 Anki 缺省写 true');
      } finally {
        await col.close();
      }

      final SrsDbStore other = await openTestStore(
        profileUid: kProfile2,
        deviceId: 'b',
        now: () => t,
      );
      await importInto(other, pkg);
      final SrsDeckView back = (await other
          .deckTree())[srsImportedDeckId(kProfile2, 'Listening')]!;
      expect(back.autoplayAudio, isFalse);
      expect(back.replayQuestionAudio, isFalse);
    });
  });
}
