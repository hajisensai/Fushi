// 编辑类撤销（srs_edit_undo.dart / store/sync2/undo_check.rs）：做 A → 别的写入者（同步拉进来的另一台设备 /
// 本机 AI 等后来的写入）改同一实体 → 撤销 A —— 后来的改动不能被盖掉，没撤成的字段键要明确报给调用方。
//
// 修复前（复习页 / 浏览页的撤销是把旧值原样写回的闭包）第一组用例红：B 设的旗标被撤销写回 0。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_browse_ops.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_sync2_peers.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000ee';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  int t = DateTime.utc(2026, 11, 10, 12).millisecondsSinceEpoch;
  Future<SrsDbStore> device(String id) =>
      openTestStore(profileUid: kProfile, deviceId: id, now: () => t += 1000);

  Future<String> addNote(
    SrsDbStore s,
    String expression, {
    List<String> tags = const <String>[],
  }) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(kProfile, 'Expression'): expression,
    },
    tags: tags,
  );

  Future<String> cardOf(SrsDbStore s, String note) async =>
      (await s.cardsOfNote(note)).single.id;

  Future<int> flagOf(SrsDbStore s, String card) async =>
      (await s.cardRow(card))!.flag;

  String hint() => srsLapisFieldId(kProfile, 'Hint');

  group('撤销不盖掉别人后来的改动', () {
    test('浏览页批量旗标：B 同步拉进来的改动保留，撤销报「没撤成」', () async {
      final SrsLocationStore loc = SrsMemoryLocationStore();
      final SrsDbStore a = await device('A');
      final SrsDbStore b = await device('B');
      final String card = await cardOf(a, await addNote(a, '雪'));
      await srsSyncPeers(<SrsDbStore>[a, b], loc);

      final SrsBatchOutcome out = await srsBatchSetFlag(a, <String>[card], 1);
      await srsSyncPeers(<SrsDbStore>[a, b], loc);
      await b.setFlag(card, 3);
      await srsSyncPeers(<SrsDbStore>[b, a], loc);
      expect(await flagOf(a, card), 3);

      final SrsBatchRevertResult r = await out.revert!(a);
      expect(await flagOf(a, card), 3, reason: 'B 的改动不能被撤销盖掉');
      expect(r.complete, isFalse);
      expect(r.edits.reverted, 0);
      expect(r.edits.kept.single.entityId, card);
      expect(r.edits.kept.single.key, SrsFieldKeys.flag);
      expect(r.edits.kept.single.current, 3);

      // 撤销没有写任何东西：同步后 B 也仍是 3。
      await srsSyncPeers(<SrsDbStore>[a, b], loc);
      expect(await flagOf(b, card), 3);
    });

    test('本机后来的写入（AI / 别处改了同一字段）保留，别的字段照撤', () async {
      final SrsDbStore s = await device('A');
      final String note = await addNote(s, '雨');
      final String card = await cardOf(s, note);
      final SrsEditUndo undo = await s.editFieldsUndoable(<SrsFieldChange>[
        SrsFieldChange(
          SrsEntityKind.note,
          note,
          SrsFieldKeys.noteField(hint()),
          'h',
        ),
        SrsFieldChange(SrsEntityKind.card, card, SrsFieldKeys.suspended, true),
      ]);
      expect(undo.items, hasLength(2));
      expect(undo.items.every((SrsEditUndoItem i) => i.seq != null), isTrue);
      await s.updateNote(note, fieldsById: <String, String>{hint(): 'AI 改的'});

      final SrsEditUndoResult r = await s.revertEdits(undo);
      expect(r.reverted, 1);
      expect(r.kept.single.key, SrsFieldKeys.noteField(hint()));
      expect(r.kept.single.current, 'AI 改的');
      expect((await s.note(note))!.field(hint()), 'AI 改的');
      expect((await s.cardRow(card))!.suspended, isFalse, reason: '没被动过的照撤');
    });

    test('并发候选（两台各改、谁也没看见谁）：不撤', () async {
      final SrsLocationStore loc = SrsMemoryLocationStore();
      final SrsDbStore a = await device('A');
      final SrsDbStore b = await device('B');
      final String card = await cardOf(a, await addNote(a, '風'));
      await srsSyncPeers(<SrsDbStore>[a, b], loc);
      final SrsEditUndo undo = await a.editFieldsUndoable(<SrsFieldChange>[
        SrsFieldChange(SrsEntityKind.card, card, SrsFieldKeys.flag, 2),
      ]);
      await b.setFlag(card, 5);
      await srsSyncPeers(<SrsDbStore>[a, b], loc);
      final SrsEditUndoResult r = await a.revertEdits(undo);
      expect(r.complete, isFalse);
      expect(await flagOf(a, card), isNot(0));
    });
  });

  group('没被动过就照常撤', () {
    test('暂停 / 删除笔记 → 撤销还原，撤销是普通操作、同步到另一台', () async {
      final SrsLocationStore loc = SrsMemoryLocationStore();
      final SrsDbStore a = await device('A');
      final SrsDbStore b = await device('B');
      final String note = await addNote(a, '花');
      final String card = await cardOf(a, note);
      final SrsEditUndo suspend = await a.editFieldsUndoable(<SrsFieldChange>[
        SrsFieldChange(SrsEntityKind.card, card, SrsFieldKeys.suspended, true),
      ]);
      final SrsEditUndo delete = await a.editFieldsUndoable(<SrsFieldChange>[
        SrsFieldChange(
          SrsEntityKind.note,
          note,
          SrsFieldKeys.deleted,
          a.now().$1,
        ),
      ]);
      await srsSyncPeers(<SrsDbStore>[a, b], loc);
      expect((await b.note(note))!.deletedAt, isNotNull);

      expect((await a.revertEdits(delete)).complete, isTrue);
      expect((await a.revertEdits(suspend)).complete, isTrue);
      expect((await a.note(note))!.deletedAt, isNull);
      expect((await a.cardRow(card))!.suspended, isFalse);
      await srsSyncPeers(<SrsDbStore>[a, b], loc);
      expect((await b.note(note))!.deletedAt, isNull);
      expect((await b.cardRow(card))!.suspended, isFalse);
    });

    test('连续两步倒序撤：撤完后一步，前一步仍可撤（值被还原成它写下的值）', () async {
      final SrsDbStore s = await device('A');
      final String card = await cardOf(s, await addNote(s, '空'));
      final SrsBatchOutcome one = await srsBatchSetFlag(s, <String>[card], 1);
      final SrsBatchOutcome two = await srsBatchSetFlag(s, <String>[card], 2);
      expect((await two.revert!(s)).complete, isTrue);
      expect(await flagOf(s, card), 1);
      expect((await one.revert!(s)).complete, isTrue);
      expect(await flagOf(s, card), 0);
    });

    test('同一操作里同一键写两次：撤回第一次之前', () async {
      final SrsDbStore s = await device('A');
      final String card = await cardOf(s, await addNote(s, '海'));
      final (void _, SrsEditUndo undo) = await s.undoable(() async {
        await s.setFlag(card, 1);
        await s.setFlag(card, 2);
      });
      expect(undo.items, hasLength(1));
      expect(undo.items.single.before, 0);
      expect(undo.items.single.after, 2);
      expect((await s.revertEdits(undo)).complete, isTrue);
      expect(await flagOf(s, card), 0);
    });
  });

  group('标签按差量撤（OR-Set）', () {
    test('撤掉这次加的标签，别人之后加的留着', () async {
      final SrsLocationStore loc = SrsMemoryLocationStore();
      final SrsDbStore a = await device('A');
      final SrsDbStore b = await device('B');
      final String note = await addNote(a, '山', tags: <String>['n5']);
      await srsSyncPeers(<SrsDbStore>[a, b], loc);
      final SrsBatchOutcome out = await srsBatchEditTags(
        a,
        <String>[note],
        add: <String>['mine'],
      );
      await srsSyncPeers(<SrsDbStore>[a, b], loc);
      await b.updateNote(note, tags: <String>['n5', 'mine', 'theirs']);
      await srsSyncPeers(<SrsDbStore>[b, a], loc);

      expect((await out.revert!(a)).complete, isTrue);
      expect((await a.note(note))!.tags, <String>['n5', 'theirs']);
    });

    test('差量函数：去掉加的、补回删的，顺序跟改前', () {
      expect(
        srsRevertTagDelta(
          current: <String>['b', 'X', 'c'],
          before: <String>['a', 'b'],
          after: <String>['b', 'x'],
        ),
        <String>['a', 'b', 'c'],
      );
    });
  });

  test('旧载荷（没有 dot）按值核对', () async {
    final SrsDbStore s = await device('A');
    final String card = await cardOf(s, await addNote(s, '川'));
    await s.setFlag(card, 4);
    SrsEditUndo legacy(Object? after) => SrsEditUndo(<SrsEditUndoItem>[
      SrsEditUndoItem(
        kind: SrsEntityKind.card,
        entityId: card,
        key: SrsFieldKeys.flag,
        before: 0,
        after: after,
      ),
    ]);
    expect((await s.revertEdits(legacy(7))).complete, isFalse);
    expect(await flagOf(s, card), 4);
    expect((await s.revertEdits(legacy(4))).complete, isTrue);
    expect(await flagOf(s, card), 0);
  });

  test('凭据 JSON 往返', () async {
    final SrsDbStore s = await device('A');
    final String card = await cardOf(s, await addNote(s, '木'));
    final SrsEditUndo undo = await s.editFieldsUndoable(<SrsFieldChange>[
      SrsFieldChange(SrsEntityKind.card, card, SrsFieldKeys.flag, 6),
    ]);
    final SrsEditUndo back = SrsEditUndo.fromJson(undo.toJson());
    expect(back.items.single.writer, undo.items.single.writer);
    expect(back.items.single.seq, undo.items.single.seq);
    expect((await s.revertEdits(back)).complete, isTrue);
    expect(await flagOf(s, card), 0);
  });
}
