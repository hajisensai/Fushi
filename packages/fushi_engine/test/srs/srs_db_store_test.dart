import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';
import 'support/srs_test_storage.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

/// 协议测试用的确定性假引擎（真实数值见 packages/fushi_srs 的 FFI 测试）。
class _FakeEngine implements FsrsEngine {
  const _FakeEngine();

  @override
  String get fsrsRev => 'fake';
  @override
  List<double> defaultParams(SrsAlgorithm a) =>
      List<double>.filled(a.paramCount, 1);
  @override
  String? validateParams(SrsAlgorithm a, List<double> p) => null;
  SrsMemory _step(SrsMemory? m, int r) => SrsMemory(
    stability: switch (r) {
      1 => 0.3,
      2 => 1.5 + (m?.stability ?? 0),
      3 => 3 + (m?.stability ?? 0) * 2,
      _ => 6 + (m?.stability ?? 0) * 3,
    },
    difficulty: 5,
  );
  @override
  SrsNextStates nextStates({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double desiredRetention,
    required SrsMemory? memory,
    required double elapsedDays,
  }) {
    SrsItemState st(int r) {
      final SrsMemory m = _step(memory, r);
      return SrsItemState(memory: m, interval: m.stability);
    }

    return SrsNextStates(again: st(1), hard: st(2), good: st(3), easy: st(4));
  }

  @override
  SrsMemory? memoryState({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<SrsFsrsReview> reviews,
    SrsMemory? starting,
  }) {
    SrsMemory? m = starting;
    for (final SrsFsrsReview r in reviews) {
      m = _step(m, r.rating);
    }
    return m;
  }

  @override
  SrsMemory memoryStateFromSm2({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double easeFactor,
    required double intervalDays,
    required double sm2Retention,
  }) => SrsMemory(stability: intervalDays, difficulty: 5);
  @override
  double retrievability({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsMemory memory,
    required double elapsedDays,
  }) => 0.9;
  @override
  List<double> computeParameters({
    required SrsAlgorithm algorithm,
    required SrsFsrsTrainingSet items,
    SrsOptimizerControl? control,
  }) => defaultParams(algorithm);
  @override
  SrsEvaluation evaluateTimeSeries({
    required SrsAlgorithm algorithm,
    required SrsFsrsTrainingSet items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
  @override
  SrsEvaluation evaluate({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsFsrsTrainingSet items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
}

const String kProfile = '01928c3e-0000-7000-8000-000000000001';

void main() {
  int t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
  late SrsMemoryLocationStore loc;

  Future<SrsDbStore> device(String id) async {
    final SrsStorage srsStorage = await openTestSrsStorage();
    final SrsTrustedClock clock = SrsTrustedClock(
      wallClockMs: () => t,
      bootId: 'boot-$id',
    );
    return SrsDbStore.open(
      db: srsStorage.db,
      core: srsStorage.core,
      profileUid: kProfile,
      deviceId: id,
      engine: const _FakeEngine(),
      trustedClock: clock,
    );
  }

  Future<void> syncAll(List<SrsDbStore> stores) async {
    for (int round = 0; round < 3; round++) {
      for (final SrsDbStore s in stores) {
        await srsSync2Round(
          host: s,
          location: loc,
          locationId: 'test',
          nowMs: () => t,
        );
      }
    }
  }

  Map<String, String> lapis(
    String expr, {
    String sentence = '',
    String reading = '',
  }) => <String, String>{
    srsLapisFieldId(kProfile, 'Expression'): expr,
    srsLapisFieldId(kProfile, 'Sentence'): sentence,
    srsLapisFieldId(kProfile, 'ExpressionReading'): reading,
  };

  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
    loc = SrsMemoryLocationStore();
  });

  test('内置牌组与 Lapis 由每台设备确定性生成，同步后不重复', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    await syncAll(<SrsDbStore>[a, b]);
    final List<SrsDeckSummary> decks = await b.deckSummaries();
    expect(decks, hasLength(1));
    expect(decks.single.deck.id, b.defaultDeckId);
    final List<SrsNoteTypeView> types = await a.noteTypes();
    // 两种内置类型：Lapis 与 Fushi 卡片。
    expect(types, hasLength(2));
    final SrsNoteTypeView lapis = types.singleWhere(
      (SrsNoteTypeView v) => v.id == a.lapisNoteTypeId,
    );
    expect(lapis.name, 'Lapis');
    expect(lapis.fields.first.name, 'Expression');
    expect(lapis.templates.single.front, contains('{{fld:'));
    expect(
      (await b.noteTypes()).map((SrsNoteTypeView v) => v.id).toSet(),
      types.map((SrsNoteTypeView v) => v.id).toSet(),
    );
  });

  test('加笔记生成卡片；复习 → 同步 → 另一台设备状态一致', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final String noteId = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: lapis('食べる', sentence: 'ご飯を食べる。', reading: 'たべる'),
    );
    final List<SrsCardCacheRow> cards = await a.cardsOfNote(noteId);
    expect(cards, hasLength(1));
    expect(cards.single.hidden, isFalse);
    final String? next = await a.nextCard(a.defaultDeckId);
    expect(next, cards.single.id);
    final SrsRenderedCard? r = await a.renderCard(next!);
    expect(r!.question, contains('食べる'));

    final SrsReviewLog l = await a.answer(next, 3);
    expect(l.reviewType, SrsReviewType.learn);
    await syncAll(<SrsDbStore>[a, b]);
    final SrsCardCacheRow? bc = await b.cardRow(next);
    final SrsCardCacheRow? ac = await a.cardRow(next);
    expect(bc!.queue, ac!.queue);
    expect(bc.lastLogId, l.id);
    expect(bc.dueAt, ac.dueAt);

    // 撤销后回到新卡；同步到对端。
    expect(await a.undo(next, l.id), isTrue);
    await syncAll(<SrsDbStore>[a, b]);
    expect((await b.cardRow(next))!.queue, SrsQueue.newCard.wire);
  });

  test('条件模板为空的卡不进队列（生成门），字段填上后带着同一 cardId 回来', () async {
    final SrsDbStore a = await device('a');
    final String noteId = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: lapis(''),
    );
    final List<SrsCardCacheRow> cards = await a.cardsOfNote(noteId);
    final String cardId = cards.single.id;
    expect(cards.single.hidden, isTrue, reason: 'Lapis 正面引用 Expression，空 = 空卡');
    expect(await a.nextCard(a.defaultDeckId), isNull);
    await a.updateNote(noteId, fieldsById: lapis('猫'));
    final SrsCardCacheRow? c = await a.cardRow(cardId);
    expect(c!.hidden, isFalse);
  });

  test('并发改同一字段：内容类待裁决；裁决后冲突消失', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final String noteId = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: lapis('犬'),
    );
    await syncAll(<SrsDbStore>[a, b]);
    final String sentence = srsLapisFieldId(kProfile, 'Sentence');
    await a.updateNote(noteId, fieldsById: <String, String>{sentence: 'A の例文'});
    t += 1000;
    await b.updateNote(noteId, fieldsById: <String, String>{sentence: 'B の例文'});
    await syncAll(<SrsDbStore>[a, b]);
    expect((await a.notesPendingDecision()).single.id, noteId);
    expect((await b.notesPendingDecision()).single.id, noteId);
    final SrsNoteView? na = await a.note(noteId);
    final SrsNoteView? nb = await b.note(noteId);
    expect(na!.field(sentence), nb!.field(sentence), reason: '生效值确定性相同');
    await a.updateNote(
      noteId,
      fieldsById: <String, String>{sentence: '合并后的例文'},
    );
    await syncAll(<SrsDbStore>[a, b]);
    expect(await a.notesPendingDecision(), isEmpty);
    expect(await b.notesPendingDecision(), isEmpty);
    expect((await b.note(noteId))!.field(sentence), '合并后的例文');
  });

  test('标志类并发：最后修改生效，被覆盖的进同步冲突记录，确认后消失', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final String noteId = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: lapis('鳥'),
    );
    await syncAll(<SrsDbStore>[a, b]);
    final String cardId = (await a.cardsOfNote(noteId)).single.id;
    await a.setSuspended(cardId, true);
    t += 1000;
    await b.setSuspended(cardId, false);
    await syncAll(<SrsDbStore>[a, b]);
    expect((await a.cardRow(cardId))!.suspended, isFalse);
    final List<(SrsEntityKind, String, SrsRegister)> c = await a
        .syncConflicts();
    expect(c, hasLength(1));
    await a.resolveConflict(
      SrsEntityKind.card,
      cardId,
      SrsFieldKeys.suspended,
      true,
    );
    await syncAll(<SrsDbStore>[a, b]);
    expect(await b.syncConflicts(), isEmpty);
    expect((await b.cardRow(cardId))!.suspended, isTrue);
  });

  test('词状态：按词形 + 读音，同形异读不合并（第六轮审查第 20 条）', () async {
    final SrsDbStore a = await device('a');
    await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: lapis('上手', reading: 'じょうず'),
    );
    final Map<String, SrsTermStatus> m = await a
        .lookupTermStatus(<SrsTermQuery>[
          const SrsTermQuery('上手', 'じょうず'),
          const SrsTermQuery('上手', 'うわて'),
          const SrsTermQuery('未収録'),
        ]);
    expect(m.keys, <String>['上手']);
    final Map<String, SrsTermStatus> any = await a.lookupTermStatus(
      <SrsTermQuery>[const SrsTermQuery('<b>上手</b>')],
    );
    expect(any['<b>上手</b>']!.cardCount, 1);
  });

  test('删除笔记：删除与对端并发修改 → 进冲突中心、笔记保持可见；选「删除」后两端都删', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final String noteId = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: lapis('魚'),
    );
    await syncAll(<SrsDbStore>[a, b]);
    await a.deleteNote(noteId);
    await b.updateNote(
      noteId,
      fieldsById: <String, String>{
        srsLapisFieldId(kProfile, 'Sentence'): '離線編集',
      },
    );
    await syncAll(<SrsDbStore>[a, b]);
    // 设计 §5.3（2026-10-25 拍板）：破坏性并发不自动判输赢，保守保留、进冲突中心。
    for (final SrsDbStore s in <SrsDbStore>[a, b]) {
      expect((await s.cardsOfNote(noteId)).single.hidden, isFalse);
      final List<Map<String, Object?>> c = await s.sync2Conflicts();
      expect(c.single['kind'], 'delete_edit');
      expect(c.single['entity'], noteId);
    }
    await b.sync2Resolve(
      (await b.sync2Conflicts()).single['id']! as String,
      delete: true,
    );
    await syncAll(<SrsDbStore>[a, b]);
    for (final SrsDbStore s in <SrsDbStore>[a, b]) {
      expect((await s.cardsOfNote(noteId)).single.hidden, isTrue);
      expect(await s.sync2Conflicts(), isEmpty);
    }
  });

  test('牌组：按全名建树；删除牌组把卡片移到父牌组', () async {
    final SrsDbStore a = await device('a');
    final String child = await a.ensureDeckPath('日本語::N3');
    final SrsDeckTree tree = await a.deckTree();
    expect(tree.fullName(child), '日本語::N3');
    final String noteId = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: lapis('空'),
      deckId: child,
    );
    final String cardId = (await a.cardsOfNote(noteId)).single.id;
    expect((await a.cardRow(cardId))!.deckId, child);
    await a.deleteDeck(child);
    expect((await a.cardRow(cardId))!.deckId, tree.parentOf(child));
  });

  test('删除牌组可连卡片一起删：子树里的笔记删除，别处的笔记不动', () async {
    final SrsDbStore a = await device('a');
    final String child = await a.ensureDeckPath('Lapis::N3');
    final String parent = (await a.deckTree()).parentOf(child)!;
    final String inside = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: lapis('海'),
      deckId: child,
    );
    final String outside = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: lapis('空'),
      deckId: parent,
    );
    final List<(int, int)> progress = <(int, int)>[];
    await a.deleteDeck(
      parent,
      deleteCards: true,
      onProgress: (int done, int total) => progress.add((done, total)),
    );
    final SrsDeckTree tree = await a.deckTree();
    expect(tree[parent], isNull);
    expect(tree[child], isNull);
    for (final String noteId in <String>[inside, outside]) {
      final SrsCardCacheRow card = (await a.cardsOfNote(noteId)).single;
      expect(card.hidden, isTrue, reason: '笔记已删，卡不再显示');
      expect(card.deckId, a.defaultDeckId, reason: '恢复笔记后卡不落在已删除的牌组里');
    }
    expect(progress.last, (4, 4), reason: '两条笔记 + 两张卡');

    final String keep = await a.ensureDeckPath('Keep');
    final String other = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: lapis('川'),
      deckId: keep,
    );
    await a.deleteDeck(await a.ensureDeckPath('Empty'), deleteCards: true);
    expect((await a.cardsOfNote(other)).single.hidden, isFalse);
  });

  test('缓存可由事件完整重建', () async {
    final SrsDbStore a = await device('a');
    final String noteId = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: lapis('山'),
    );
    final String cardId = (await a.cardsOfNote(noteId)).single.id;
    await a.answer(cardId, 4);
    final SrsCardCacheRow before = (await a.cardRow(cardId))!;
    await a.rebuildCaches();
    final SrsCardCacheRow after = (await a.cardRow(cardId))!;
    expect(after.queue, before.queue);
    expect(after.dueDay, before.dueDay);
    expect(after.lastLogId, before.lastLogId);
  });

  test('覆盖恢复备份后：换新化身、全部重新发布、缓存重建', () async {
    final SrsStorage srsStorage = await openTestSrsStorage();
    SrsTrustedClock clock() =>
        SrsTrustedClock(wallClockMs: () => t, bootId: 'boot');
    final SrsDbStore a = await SrsDbStore.open(
      db: srsStorage.db,
      core: srsStorage.core,
      profileUid: kProfile,
      deviceId: 'a',
      engine: const _FakeEngine(),
      trustedClock: clock(),
    );
    final String noteId = await a.createNote(
      noteTypeId: a.lapisNoteTypeId,
      fieldsById: lapis('川'),
    );
    final String cardId = (await a.cardsOfNote(noteId)).single.id;
    await a.answer(cardId, 3);
    await srsSync2Round(
      host: a,
      location: loc,
      locationId: 'test',
      nowMs: () => t,
    );
    final String? oldDevice = a.sync2Device;
    // 恢复备份：本机状态、缓存表与同步 v2 的本机身份被清空（备份快照剥掉设备本地表，见 SrsCore.snapshotInto）。
    await srsStorage.db.delete(srsStorage.db.srsLocalState).go();
    await srsStorage.db.delete(srsStorage.db.srsEventLocal).go();
    await srsStorage.db.delete(srsStorage.db.srsCardsCache).go();
    await srsStorage.db.delete(srsStorage.db.srsNotesCache).go();
    await srsStorage.db.customStatement('DELETE FROM sync2_self');
    final SrsDbStore restored = await SrsDbStore.open(
      db: srsStorage.db,
      core: srsStorage.core,
      profileUid: kProfile,
      deviceId: 'a',
      engine: const _FakeEngine(),
      trustedClock: clock(),
    );
    // 恢复出来的库是一台新设备（新身份，设计 §7.3 的预防），旧身份按普通远端设备续收，不会分叉。
    expect(restored.sync2Device, isNot(oldDevice));
    expect((await restored.cardRow(cardId))!.reps, 1);
    final SrsSync2Report r = await srsSync2Round(
      host: restored,
      location: loc,
      locationId: 'test',
      nowMs: () => t,
    );
    expect(r.fork, isFalse);
  });

  test('首次同步分批拉段、分批收：进度逐批上报，中途收手已收的保留、下一轮补齐', () async {
    final List<String> notes = <String>[];
    // 四台设备离线各建一条、再依次同步：位置上有多个段（同一台设备的小段会被分层合并成一个），彼此没有因果
    // 依赖，任意分批都能各自应用。
    final List<SrsDbStore> writers = <SrsDbStore>[];
    for (final (String id, String w) in <(String, String)>[
      ('a', '川'),
      ('c', '山'),
      ('d', '海'),
      ('e', '空'),
    ]) {
      final SrsDbStore s = await device(id);
      notes.add(
        await s.createNote(noteTypeId: s.lapisNoteTypeId, fieldsById: lapis(w)),
      );
      writers.add(s);
    }
    for (final SrsDbStore s in writers) {
      await srsSync2Round(
        host: s,
        location: loc,
        locationId: 'test',
        nowMs: () => t,
      );
    }
    final SrsDbStore b = await device('b');
    final List<(int, int)> progress = <(int, int)>[];
    final SrsSync2Report stopped = await srsSync2Round(
      host: b,
      location: loc,
      locationId: 'test',
      nowMs: () => t,
      ingestBudgetBytes: 1,
      fetchConcurrency: 1,
      onFetchProgress: (int done, int total) => progress.add((done, total)),
      shouldStop: () => progress.length >= 2,
    );
    expect(stopped.error, kSrsSync2Stopped);
    final int total = progress.first.$2;
    expect(total, greaterThan(1), reason: '要有多个段才能验证分批');
    expect(progress, <(int, int)>[(0, total), (1, total)]);
    expect(stopped.applied, greaterThan(0), reason: '第一批已经提交');

    progress.clear();
    final SrsSync2Report rest = await srsSync2Round(
      host: b,
      location: loc,
      locationId: 'test',
      nowMs: () => t,
      ingestBudgetBytes: 1,
      fetchConcurrency: 1,
      onFetchProgress: (int done, int total) => progress.add((done, total)),
    );
    expect(rest.error, isNull);
    expect(progress.first.$2, total - 1, reason: '已收的段 plan 不再要');
    expect(progress.last, (total - 1, total - 1));
    for (final String n in notes) {
      expect(await b.cardsOfNote(n), isNotEmpty);
    }
  });

  test('两台设备离线各建同名牌组，同步后只有一个（确定性牌组 ID）', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final String da = await a.ensureDeckPath('日本語::N2');
    final String db = await b.ensureDeckPath('日本語 :: N2');
    expect(da, db);
    await syncAll(<SrsDbStore>[a, b]);
    final List<SrsDeckSummary> decks = await b.deckSummaries();
    expect(decks.map((SrsDeckSummary d) => d.fullName), <String>[
      'Default',
      '日本語',
      '日本語::N2',
    ]);
    await a.deleteDeck(da);
    expect(await a.ensureDeckPath('日本語::N2'), da, reason: '删除后按同名再建 = 复活同一行');
    expect((await a.deckTree())[da], isNotNull);
  });

  test('牌组折叠随同步到另一台设备；并发开合按最后修改生效、不进冲突记录', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final String child = await a.ensureDeckPath('日本語::N1');
    final String parent = (await a.deckTree()).parentOf(child)!;
    await syncAll(<SrsDbStore>[a, b]);
    expect((await b.deckTree())[parent]!.collapsed, isFalse, reason: '缺省展开');
    await a.setDeckCollapsed(parent, true);
    await syncAll(<SrsDbStore>[a, b]);
    expect((await b.deckTree())[parent]!.collapsed, isTrue);
    // 并发：a 展开、b 稍后又收起。
    await a.setDeckCollapsed(parent, false);
    t += 1000;
    await b.setDeckCollapsed(parent, false);
    await b.setDeckCollapsed(parent, true);
    await syncAll(<SrsDbStore>[a, b]);
    expect((await a.deckTree())[parent]!.collapsed, isTrue);
    expect((await b.deckTree())[parent]!.collapsed, isTrue);
    expect(await a.syncConflicts(), isEmpty);
    expect(await b.syncConflicts(), isEmpty);
  });
}
