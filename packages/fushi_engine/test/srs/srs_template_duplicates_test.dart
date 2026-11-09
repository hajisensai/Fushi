import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_template_duplicates.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_sync2_peers.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000001';

SrsTemplateDef _tpl(String id, int ord, String front) => SrsTemplateDef(
  id: id,
  name: 'Card ${ord + 1}',
  ord: ord,
  front: front,
  back: '{{FrontSide}}',
);

SrsNoteTypeView _type(List<SrsTemplateDef> templates, {bool cloze = false}) =>
    SrsNoteTypeView(
      id: 'nt',
      ankiNum: 1,
      name: 'T',
      kind: cloze ? SrsNoteTypeKind.cloze : SrsNoteTypeKind.standard,
      termFieldId: null,
      deletedAt: null,
      builtinKey: null,
      fields: const <SrsFieldDef>[
        SrsFieldDef(id: 'f1', name: 'Front', ord: 0),
        SrsFieldDef(id: 'f2', name: 'Back', ord: 1),
      ],
      templates: templates,
      css: '',
      edits: SrsEntityEdits(<String, SrsRegister>{}),
    );

void main() {
  group('判重（纯函数）', () {
    test('正面相同（注释 / 空白差异不算）成组；背面不同也算；不引用字段的正面不算', () {
      final SrsNoteTypeView t = _type(<SrsTemplateDef>[
        _tpl('a', 0, '<div> {{fld:f1}} </div>'),
        _tpl('b', 1, '<!--fushi-visual:v1:xyz-->\n<div>\n  {{fld:f1}}\n</div>'),
        _tpl('c', 2, '{{fld:f2}}'),
        _tpl('d', 3, '<div class="fc"></div>'),
        _tpl('e', 4, '<div class="fc"></div>'),
      ]);
      final List<List<SrsTemplateDef>> groups = srsDuplicateFrontGroups(t);
      expect(groups, hasLength(1));
      expect(groups.single.map((SrsTemplateDef x) => x.id), <String>['a', 'b']);
      expect(
        srsTemplatesWithSameFront(t, 'b').map((SrsTemplateDef x) => x.id),
        <String>['a'],
      );
      expect(srsTemplatesWithSameFront(t, 'c'), isEmpty);
      expect(srsTemplatesWithSameFront(t, 'd'), isEmpty, reason: '空卡不算重复');
      // 编辑器里还没保存的正面：按草稿判。
      expect(
        srsTemplatesWithSameFront(
          t,
          'c',
          front: '<div>  {{fld:f1}}\n</div>',
        ).map((SrsTemplateDef x) => x.id),
        <String>['a', 'b'],
      );
    });

    test('填空类型恒无重复', () {
      final SrsNoteTypeView t = _type(<SrsTemplateDef>[
        _tpl('a', 0, '{{cloze:fld:f1}}'),
        _tpl('b', 1, '{{cloze:fld:f1}}'),
      ], cloze: true);
      expect(srsDuplicateFrontGroups(t), isEmpty);
    });
  });

  group('删除重复模板', () {
    int t = DateTime.utc(2026, 11, 7, 12).millisecondsSinceEpoch;
    late SrsMemoryLocationStore dir;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

    Future<SrsDbStore> device(String id) =>
        openTestStore(profileUid: kProfile, deviceId: id, now: () => t);

    Future<void> syncAll(List<SrsDbStore> stores) async {
      for (int round = 0; round < 3; round++) {
        for (final SrsDbStore s in stores) {
          await srsSyncOnce(s, dir);
        }
      }
    }

    setUp(() {
      t = DateTime.utc(2026, 11, 7, 12).millisecondsSinceEpoch;
      dir = SrsMemoryLocationStore();
    });

    test('被删模板上有复习记录的卡并进同一笔记的保留卡；调过模板顺序也按模板 ID 对；同步后对端一致', () async {
      final SrsDbStore a = await device('a');
      final SrsDbStore b = await device('b');
      final String nt = await a.createStockNoteType(
        SrsStockNoteType.basic,
        'B',
      );
      SrsNoteTypeView v = (await a.noteType(nt))!;
      final String card1Tpl = v.templates.single.id;
      // 用户案例：加第二个模板、正文照抄第一个。
      final String card2Tpl = await a.addTemplate(
        nt,
        name: 'Card 2',
        front: v.templates.single.front,
        back: v.templates.single.back,
      );
      Future<String> note(String w) => a.createNote(
        noteTypeId: nt,
        fieldsById: <String, String>{v.fields[0].id: w, v.fields[1].id: 'x'},
      );
      final String onlyDup = await note('only-card2-reviewed');
      final String bothNote = await note('both-reviewed');
      final String fresh = await note('never-reviewed');
      String card(String n, String tpl) => SrsIds.card(n, tpl, 0);

      // onlyDup：只复习过 Card 2 那张；bothNote：两张都复习过。
      final SrsReviewLog d1 = await a.answer(card(onlyDup, card2Tpl), 3);
      t += 60000;
      final SrsReviewLog d2 = await a.answer(card(onlyDup, card2Tpl), 3);
      final SrsCardCacheRow dupBefore = (await a.cardRow(
        card(onlyDup, card2Tpl),
      ))!;
      t += 60000;
      final SrsReviewLog b1 = await a.answer(card(bothNote, card1Tpl), 3);
      t += 60000;
      final SrsReviewLog b2 = await a.answer(card(bothNote, card2Tpl), 4);

      // 把 Card 2 调到最前：复习记录跟着模板 ID 走，不跟位置走。
      await a.reorderTemplates(nt, <String>[card2Tpl, card1Tpl]);
      v = (await a.noteType(nt))!;
      expect(v.templates.first.id, card2Tpl);
      expect(srsDuplicateFrontGroups(v), hasLength(1));

      final SrsTemplateDedupePreview p = await a.previewTemplateDedupe(
        nt,
        keepTemplateId: card1Tpl,
        dropTemplateIds: <String>[card2Tpl],
      );
      expect(p.droppedCards, 3);
      expect(p.linkedCards, 2);
      expect(p.bothReviewed, 1);
      expect(p.unmatched, 0);
      expect(p.links[card(onlyDup, card1Tpl)], <String>[
        card(onlyDup, card2Tpl),
      ]);
      expect(p.links[card(fresh, card1Tpl)], isNull, reason: '没复习过的不挂链接');

      await a.dedupeTemplates(
        nt,
        keepTemplateId: card1Tpl,
        dropTemplateIds: <String>[card2Tpl],
      );

      Future<void> check(SrsDbStore s) async {
        final SrsNoteTypeView after = (await s.noteType(nt))!;
        expect(after.templates.map((SrsTemplateDef x) => x.id), <String>[
          card1Tpl,
        ]);
        for (final String n in <String>[onlyDup, bothNote, fresh]) {
          expect(await s.cardRow(card(n, card2Tpl)), isNull);
          expect(await s.cardRow(card(n, card1Tpl)), isNotNull);
        }
        // 只复习过被删那张：保留卡接过它的全部历史与排程。
        final SrsCardCacheRow kept = (await s.cardRow(
          card(onlyDup, card1Tpl),
        ))!;
        expect(kept.reps, dupBefore.reps);
        expect(kept.lastLogId, d2.id);
        expect(kept.dueAt, dupBefore.dueAt);
        expect(
          (await s.history(
            card(onlyDup, card1Tpl),
          )).all.map((SrsReviewLog l) => l.id).toSet(),
          <String>{d1.id, d2.id},
        );
        // 两张都复习过：按时间合在一起。
        expect(
          (await s.history(
            card(bothNote, card1Tpl),
          )).all.map((SrsReviewLog l) => l.id).toSet(),
          <String>{b1.id, b2.id},
        );
        expect((await s.cardRow(card(bothNote, card1Tpl)))!.lastLogId, b2.id);
        expect((await s.cardRow(card(fresh, card1Tpl)))!.reps, 0);
      }

      await check(a);
      await syncAll(<SrsDbStore>[a, b]);
      await check(b);
    });

    test('不是重复的模板不走这条路（抛错、什么都不写）', () async {
      final SrsDbStore a = await device('a');
      final String nt = await a.createStockNoteType(
        SrsStockNoteType.basicReversed,
        'R',
      );
      final SrsNoteTypeView v = (await a.noteType(nt))!;
      expect(srsDuplicateFrontGroups(v), isEmpty);
      await expectLater(
        a.dedupeTemplates(
          nt,
          keepTemplateId: v.templates[0].id,
          dropTemplateIds: <String>[v.templates[1].id],
        ),
        throwsStateError,
      );
      expect((await a.noteType(nt))!.templates, hasLength(2));
    });
  });
}
