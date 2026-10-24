// BUG-3543：批量操作改成「分块预读 + 成批落库」后，与逐条做的结果逐字节相同。
//
// 每个用例开两份同样的库（同一设备 ID、时钟不走），一份用逐条的公开 API 按修前的算法做
// （每张卡 / 每条笔记一次 editField、resetCard……），一份用批量入口做，再逐表比较全部 SRS 行：
// 身份记录、修改记录（ID / dot / ctx / HLC / 值）、复习日志、发件箱与服务器时刻、本机状态
// （写入者序号、因果上下文、时钟、修订号）、笔记 / 卡片缓存。另核对缓存与「由事件整体重建」一致。
import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:fushi_engine/srs/srs_browse_ops.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_bulk_fixture.dart';

const int kNotes = 24;

/// 两份同样的库：[ref] 走逐条，[bulk] 走批量。
Future<(BulkFixture, BulkFixture)> twins({int notes = kNotes}) async => (
  await BulkFixture.open(notes: notes),
  await BulkFixture.open(notes: notes),
);

Future<void> expectSame(BulkFixture bulk, BulkFixture ref) async {
  final Map<String, List<String>> got = await dumpSrsState(bulk.db);
  expectSameState(got, await dumpSrsState(ref.db));
  // 缓存是事件的纯函数：增量刷新的结果与整体重建相同。重建只生成「应有」的卡，增量刷新把
  // 不再应有的旧卡（换类型前的卡）留成隐藏行——两者等价，只比可见的卡。
  await bulk.store.rebuildCaches();
  final Map<String, List<String>> rebuilt = await dumpSrsState(bulk.db);
  List<String> visible(List<String> rows) => <String>[
    for (final String r in rows)
      if (r.split('|')[8] == '0') r,
  ];
  expectSameState(
    <String, List<String>>{
      'notesCache': rebuilt['notesCache']!,
      'cardsCache': visible(rebuilt['cardsCache']!),
    },
    <String, List<String>>{
      'notesCache': got['notesCache']!,
      'cardsCache': visible(got['cardsCache']!),
    },
    label: 'rebuilt vs incremental: ',
  );
}

Future<List<String>> allCards(SrsDbStore s) async => <String>[
  for (final SrsCardCacheRow c in await s.allCardRows()) c.id,
];

Future<List<String>> allNotes(SrsDbStore s) async => <String>[
  for (final SrsNoteCacheRow n in await s.listNotes(limit: 100000)) n.id,
];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('删牌组（含子牌组）= 逐张 editField 移卡、再逐个标删除（修前算法）', () async {
    final (BulkFixture ref, BulkFixture bulk) = await twins();
    // 一部分卡先手动移到别的牌组、一部分已经在目标牌组：值没变的卡不写记录。
    for (final BulkFixture f in <BulkFixture>[ref, bulk]) {
      final List<String> cards = await allCards(f.store);
      await f.store.moveCard(cards[0], f.store.defaultDeckId);
      await f.store.moveCard(cards[1], await deckId(f.store, 'Lang'));
    }

    final SrsDbStore r = ref.store;
    final String lang = await deckId(r, 'Lang');
    final SrsDeckTree tree = await r.deckTree();
    final List<String> sub = tree.subtree(lang);
    final String target = tree.parentOf(lang) ?? r.defaultDeckId;
    final List<SrsCardCacheRow> cards = await (r.db.select(
      r.db.srsCardsCache,
    )..where((c) => c.deckId.isIn(sub))).get();
    for (final SrsCardCacheRow c in cards) {
      await r.editField(
        SrsEntityKind.card,
        c.id,
        SrsFieldKeys.cardDeck,
        target,
      );
    }
    final (int nowMs, _) = r.now();
    for (final String id in sub) {
      await r.editField(SrsEntityKind.deck, id, SrsFieldKeys.deleted, nowMs);
    }

    final List<(int, int)> progress = <(int, int)>[];
    await bulk.store.deleteDeck(
      await deckId(bulk.store, 'Lang'),
      onProgress: (int done, int total) => progress.add((done, total)),
    );
    await expectSame(bulk, ref);
    expect(progress.first, (0, cards.length));
    expect(progress.last, (cards.length, cards.length));
  });

  test('删大牌组跨多块：与逐张同结果', () async {
    // 每块 500 张卡：260 条笔记 = 520 张卡，跨两块。
    final (BulkFixture ref, BulkFixture bulk) = await twins(notes: 260);
    final SrsDbStore r = ref.store;
    final String lang = await deckId(r, 'Lang');
    final SrsDeckTree tree = await r.deckTree();
    final List<String> sub = tree.subtree(lang);
    for (final SrsCardCacheRow c in await (r.db.select(
      r.db.srsCardsCache,
    )..where((c) => c.deckId.isIn(sub))).get()) {
      await r.editField(
        SrsEntityKind.card,
        c.id,
        SrsFieldKeys.cardDeck,
        r.defaultDeckId,
      );
    }
    final (int nowMs, _) = r.now();
    for (final String id in sub) {
      await r.editField(SrsEntityKind.deck, id, SrsFieldKeys.deleted, nowMs);
    }
    await bulk.store.deleteDeck(await deckId(bulk.store, 'Lang'));
    await expectSame(bulk, ref);
    // 参照路径逐张 editField 约 1000 次提交；srs.db 是磁盘 WAL 文件，比旧内存库慢，默认 30s 太紧。
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('批量移动 / 暂停 / 旗标 = 逐张 editField（值没变的跳过）', () async {
    final (BulkFixture ref, BulkFixture bulk) = await twins();
    final SrsDbStore r = ref.store;
    final List<SrsCardCacheRow> rows = await r.cardRows(await allCards(r));
    for (final SrsCardCacheRow c in rows) {
      if (c.deckId != r.defaultDeckId) {
        await r.editField(
          SrsEntityKind.card,
          c.id,
          SrsFieldKeys.cardDeck,
          r.defaultDeckId,
        );
      }
    }
    for (final SrsCardCacheRow c in await r.cardRows(await allCards(r))) {
      if (!c.suspended) await r.setSuspended(c.id, true);
    }
    for (final SrsCardCacheRow c in await r.cardRows(await allCards(r))) {
      if (c.flag != 2) await r.setFlag(c.id, 2);
    }

    final SrsDbStore b = bulk.store;
    await srsBatchMoveCards(b, await allCards(b), b.defaultDeckId);
    await srsBatchSetSuspended(b, await allCards(b), suspended: true);
    await srsBatchSetFlag(b, await allCards(b), 2);
    await expectSame(bulk, ref);
  });

  test('批量改标签 / 删笔记 = 逐条读笔记、逐条写', () async {
    final (BulkFixture ref, BulkFixture bulk) = await twins();
    final SrsDbStore r = ref.store;
    for (final String id in await allNotes(r)) {
      final SrsNoteView n = (await r.note(id))!;
      await r.updateNote(id, tags: <String>[...n.tags, 'x']);
    }
    final (int nowMs, _) = r.now();
    for (final String id in await allNotes(r)) {
      await r.editField(SrsEntityKind.note, id, SrsFieldKeys.deleted, nowMs);
    }

    final SrsDbStore b = bulk.store;
    await srsBatchEditTags(b, await allNotes(b), add: <String>['x']);
    await srsBatchDeleteNotes(b, await allNotes(b));
    await expectSame(bulk, ref);
  });

  test('重置 / 设置到期 / 撤销 = 逐张 resetCard / setDueDay / undo', () async {
    final (BulkFixture ref, BulkFixture bulk) = await twins();
    final SrsDbStore r = ref.store;
    final List<SrsReviewLog> refResets = <SrsReviewLog>[];
    for (final SrsCardCacheRow c in await r.cardRows(await allCards(r))) {
      if (c.queue == SrsQueue.newCard.wire) continue;
      await r.resetCard(c.id);
      final String logId = (await r.cardRow(c.id))!.lastLogId!;
      refResets.add(
        (await r.history(
          c.id,
        )).all.firstWhere((SrsReviewLog l) => l.id == logId),
      );
    }
    for (final (String card, String log) in <(String, String)>[
      for (final SrsReviewLog l in refResets.take(5)) (l.cardId, l.id),
    ]) {
      await r.undo(card, log);
    }
    final SrsDayContext day = await r.dayContext();
    final int today = day.dayIndexOf(r.now().$1);
    for (final String id in await allCards(r)) {
      await r.setDueDay(id, today + 3);
    }

    final SrsDbStore b = bulk.store;
    final List<SrsReviewLog> resets = await b.resetCards(await allCards(b));
    expect(resets.length, refResets.length);
    await b.undoLogs(<(String, String)>[
      for (final SrsReviewLog l in resets.take(5)) (l.cardId, l.id),
    ]);
    await srsBatchSetDue(b, await allCards(b), from: 3, to: 3);
    await expectSame(bulk, ref);
  });

  test('立即重排整组 = 逐张读历史 + 读牌组设置算 reschedule', () async {
    final (BulkFixture ref, BulkFixture bulk) = await twins();
    final SrsDbStore r = ref.store;
    final String lang = await deckId(r, 'Lang');
    final SrsDeckTree tree = await r.deckTree();
    final List<SrsReviewLog> logs = <SrsReviewLog>[];
    for (final SrsCardCacheRow c
        in await (r.db.select(r.db.srsCardsCache)..where(
              (c) =>
                  c.deckId.isIn(tree.subtree(lang)) &
                  c.queue.equals(SrsQueue.review.wire),
            ))
            .get()) {
      final SrsReviewLog? l = SrsCardOps(engine: r.engine!).reschedule(
        cardId: c.id,
        history: await r.history(c.id),
        config: await r.schedulingConfigFor(c.deckId),
        ctx: await r.logContext(),
      );
      if (l != null) logs.add(l);
    }
    await r.appendLocalLogs(logs);

    final int n = await bulk.store.rescheduleDeck(
      await deckId(bulk.store, 'Lang'),
    );
    expect(n, logs.length);
    expect(n, greaterThan(0));
    await expectSame(bulk, ref);
  });

  test('更改笔记类型 = 逐条读笔记与卡、逐项 editField（修前算法）', () async {
    final (BulkFixture ref, BulkFixture bulk) = await twins();
    final SrsDbStore r = ref.store;
    final ChangeSpec c = await fushiCardChange(r);
    final SrsNoteTypeView from = (await r.noteType(basicTypeId(r)))!;
    final SrsNoteTypeView to = (await r.noteType(c.targetTypeId))!;
    final List<SrsNoteTypeChangePlan> plans = <SrsNoteTypeChangePlan>[];
    for (final String id in c.noteIds) {
      plans.add(
        srsPlanNoteTypeChange(
          note: (await r.note(id))!,
          from: from,
          to: to,
          fieldMap: c.fieldMap,
          templateMap: c.templateMap,
          existingCards: <SrsExistingCard>[
            for (final SrsCardCacheRow x in await r.cardsOfNote(id))
              SrsExistingCard(
                cardId: x.id,
                templateId: x.templateId,
                clozeOrd: x.clozeOrd,
                hidden: x.hidden,
              ),
          ],
        ),
      );
    }
    for (final SrsNoteTypeChangePlan plan in plans) {
      await r.editField(
        SrsEntityKind.note,
        plan.noteId,
        SrsFieldKeys.noteType,
        to.id,
      );
      for (final MapEntry<String, String> f in plan.fieldValues.entries) {
        await r.editField(
          SrsEntityKind.note,
          plan.noteId,
          SrsFieldKeys.noteField(f.key),
          f.value,
        );
      }
      for (final MapEntry<String, String> l in plan.cardLinks.entries) {
        await r.editField(
          SrsEntityKind.card,
          l.key,
          SrsFieldKeys.cardHistoryFrom(l.value),
          true,
        );
      }
    }

    final SrsDbStore b = bulk.store;
    final ChangeSpec bc = await fushiCardChange(b);
    await b.changeNoteType(
      noteIds: bc.noteIds,
      targetTypeId: bc.targetTypeId,
      fieldMap: bc.fieldMap,
      templateMap: bc.templateMap,
    );
    await expectSame(bulk, ref);
    // 换类型后新卡继承了旧卡的历史（前身链接经部分索引找到后继）。
    final SrsCardCacheRow linked = (await b.allCardRows()).firstWhere(
      (SrsCardCacheRow x) => x.templateId == to.templates.first.id,
    );
    expect(linked.reps, greaterThan(0));
    expect(linked.hidden, isFalse);
  });

  test('删笔记类型 = 逐条标笔记删除、最后标类型', () async {
    final (BulkFixture ref, BulkFixture bulk) = await twins();
    final SrsDbStore r = ref.store;
    final (int nowMs, _) = r.now();
    for (final String id in await r.noteIdsOfType(basicTypeId(r))) {
      await r.editField(SrsEntityKind.note, id, SrsFieldKeys.deleted, nowMs);
    }
    await r.editField(
      SrsEntityKind.noteType,
      basicTypeId(r),
      SrsFieldKeys.deleted,
      nowMs,
    );
    await bulk.store.deleteNoteType(basicTypeId(bulk.store));
    await expectSame(bulk, ref);
  });

  group('同步', () {
    /// 一组含批内重复、批内互相支配、同 ID 异内容的对端事件。
    Future<List<SrsEvent>> trickyRemote() async {
      final BulkFixture src = await BulkFixture.open(
        notes: 12,
        deviceId: 'peer',
      );
      final List<SrsEvent> base = await src.store.exportAll();
      final SrsEditWriter w = SrsEditWriter(writerId: 'peer2#1');
      final HlcClock clock = HlcClock('peer2#1');
      final String deck = await deckId(src.store, 'Lang');
      SrsFieldEdit edit(String key, Object? value) => w.create(
        profileUid: kBulkUid,
        entityKind: SrsEntityKind.deck,
        entityId: deck,
        fieldKey: key,
        value: value,
        hlc: clock.tick(kBulkNowMs),
        timeSource: SrsTimeSource.wall,
      );
      final SrsFieldEdit a = edit(SrsFieldKeys.name, 'A');
      final SrsFieldEdit b = edit(SrsFieldKeys.name, 'B'); // 支配 a
      return <SrsEvent>[
        ...base,
        SrsEditEvent(b),
        SrsEditEvent(a), // 被批内更早的 b 支配
        SrsEditEvent(b), // 批内重复
        base.first, // 重复的身份记录
      ];
    }

    test('应用一批对端事件 = 逐条应用（含批内重复 / 支配）', () async {
      final List<SrsEvent> events = await trickyRemote();
      final BulkFixture ref = await BulkFixture.open(notes: 0, deviceId: 'me');
      final BulkFixture bulk = await BulkFixture.open(notes: 0, deviceId: 'me');
      for (final SrsEvent e in events) {
        await ref.store.applyRemote(<SrsEvent>[e], serverTimeMs: 7);
      }
      await bulk.store.applyRemote(events, serverTimeMs: 7);
      await expectSame(bulk, ref);
    });

    test('服务器时刻 / 重新入队 / 取发件箱 = 逐条', () async {
      final (BulkFixture ref, BulkFixture bulk) = await twins(notes: 10);
      final List<String> ids = <String>[
        for (final SrsEvent e in await ref.store.exportAll()) e.id,
      ];
      final Map<String, int> times = <String, int>{
        for (int i = 0; i < ids.length; i += 3) ids[i]: 1000 + i,
      };
      for (final MapEntry<String, int> e in times.entries) {
        await ref.store.observeServerTimes(<String, int>{e.key: e.value});
      }
      for (final String id in ids.reversed) {
        await ref.store.requeue(<String>[id]);
      }
      await bulk.store.observeServerTimes(times);
      await bulk.store.requeue(ids.reversed.toList());
      await expectSame(bulk, ref);

      // 发件箱：按入箱顺序给出事件正文（与逐条按 ID 找同一结果）。
      final Map<String, SrsEvent> byId = <String, SrsEvent>{
        for (final SrsEvent e in await bulk.store.exportAll()) e.id: e,
      };
      final List<SrsEvent> out = await bulk.store.unpublishedEvents();
      expect(
        out.map((SrsEvent e) => e.id).toList(),
        ids.reversed.where(byId.containsKey).toList(),
      );
      expect(
        out.map((SrsEvent e) => e.canonical()).toList(),
        ids.reversed
            .where(byId.containsKey)
            .map((String id) => byId[id]!.canonical())
            .toList(),
      );
    });
  });

  test('AnkiConnect suspend / addTags：一个批次写，与逐条同结果（含重复项）', () async {
    final (BulkFixture ref, BulkFixture bulk) = await twins(notes: 10);
    final SrsDbStore r = ref.store;
    final List<String> cards = await allCards(r);
    for (final String id in <String>[...cards, cards.first]) {
      if (!(await r.cardRow(id))!.suspended) await r.setSuspended(id, true);
    }
    final List<String> notes = await allNotes(r);
    for (final String id in <String>[...notes, notes.first]) {
      final SrsNoteView n = (await r.note(id))!;
      if (!n.tags.contains('ac')) {
        await r.updateNote(id, tags: <String>[...n.tags, 'ac']);
      }
    }

    final SrsDbStore b = bulk.store;
    final SrsAnkiConnectHandler h = SrsAnkiConnectHandler(
      store: () async => b,
      instanceId: 'bulk',
    );
    Future<Object?> call(String action, Map<String, Object?> params) async {
      final Map<String, Object?> res =
          await h.handle(<String, Object?>{
                'action': action,
                'version': 6,
                'params': params,
              })
              as Map<String, Object?>;
      expect(res['error'], isNull, reason: '$action: ${res['error']}');
      return res['result'];
    }

    final List<String> bCards = await allCards(b);
    await call('suspend', <String, Object?>{
      'cards': <int>[
        for (final String id in <String>[...bCards, bCards.first])
          SrsIds.ankiNumericId(id),
      ],
    });
    final List<String> bNotes = await allNotes(b);
    await call('addTags', <String, Object?>{
      'notes': <int>[
        for (final String id in <String>[...bNotes, bNotes.first])
          SrsIds.ankiNumericId(id),
      ],
      'tags': 'ac',
    });
    await expectSame(bulk, ref);
  });
}
