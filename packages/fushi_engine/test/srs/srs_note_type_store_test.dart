import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_anki_package.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_export.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_sync2_peers.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000001';
const String kProfile2 = '01928c3e-0000-7000-8000-000000000002';

void main() {
  int t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
  late SrsMemoryLocationStore dir;

  Future<SrsDbStore> device(String id, {String profile = kProfile}) =>
      openTestStore(profileUid: profile, deviceId: id, now: () => t);

  Future<void> syncAll(List<SrsDbStore> stores) async {
    for (int round = 0; round < 3; round++) {
      for (final SrsDbStore s in stores) {
        await srsSyncOnce(s, dir);
      }
    }
  }

  Future<SrsNoteTypeView> type(SrsDbStore s, String id) async =>
      (await s.noteType(id))!;

  /// 名字 → fieldId 的模板正文（页面里由编辑器做这一步）。
  String byName(SrsNoteTypeView v, String tpl) => templateNamesToIdsFor(v, tpl);

  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
    dir = SrsMemoryLocationStore();
  });

  group('笔记类型管理', () {
    test('新建基础类型 → 加笔记生成卡；加模板为已有笔记生成卡；删模板删掉那张卡的缓存行；对端一致', () async {
      final SrsDbStore a = await device('a');
      final SrsDbStore b = await device('b');
      final String nt = await a.createStockNoteType(
        SrsStockNoteType.basic,
        '问答',
      );
      SrsNoteTypeView v = await type(a, nt);
      expect(v.name, '问答');
      expect(v.fields.map((SrsFieldDef f) => f.name), <String>[
        'Front',
        'Back',
      ]);
      expect(v.templates.single.front, '{{fld:${v.fields[0].id}}}');
      final String note = await a.createNote(
        noteTypeId: nt,
        fieldsById: <String, String>{
          v.fields[0].id: '猫',
          v.fields[1].id: 'cat',
        },
      );
      expect(await a.cardsOfNote(note), hasLength(1));
      expect((await a.noteCountsByType())[nt], 1);

      final String tpl2 = await a.addTemplate(
        nt,
        name: 'Card 2',
        front: byName(v, '{{Back}}'),
        back: byName(v, '{{FrontSide}}<hr id=answer>{{Front}}'),
      );
      final List<SrsCardCacheRow> cards = await a.cardsOfNote(note);
      expect(cards, hasLength(2));
      final SrsCardCacheRow reversed = cards.firstWhere(
        (SrsCardCacheRow c) => c.templateId == tpl2,
      );
      expect(reversed.id, SrsIds.card(note, tpl2, 0), reason: '确定性生成');
      expect(reversed.hidden, isFalse);
      expect((await a.renderCard(reversed.id))!.question, contains('cat'));

      await syncAll(<SrsDbStore>[a, b]);
      expect(
        (await b.cardsOfNote(note)).map((SrsCardCacheRow c) => c.id).toSet(),
        cards.map((SrsCardCacheRow c) => c.id).toSet(),
      );

      expect(await a.visibleCardsOfTemplate(tpl2), 1);
      await a.deleteTemplate(nt, tpl2);
      expect(
        await a.cardRow(reversed.id),
        isNull,
        reason: '删模板：卡不再生成，删缓存行；增量与重建同一张表',
      );
      v = await type(a, nt);
      expect(v.templates, hasLength(1));
      await expectLater(
        a.deleteTemplate(nt, v.templates.single.id),
        throwsStateError,
        reason: '最后一个模板不能删',
      );
      await syncAll(<SrsDbStore>[a, b]);
      expect(await b.cardRow(reversed.id), isNull);
    });

    test('字段：加 / 改名（模板不动）/ 调序 / 删（模板引用一起去掉）；内置 Lapis 的保护', () async {
      final SrsDbStore a = await device('a');
      final String nt = await a.createStockNoteType(
        SrsStockNoteType.basic,
        'Basic',
      );
      SrsNoteTypeView v = await type(a, nt);
      final String front = v.fields[0].id;
      final String back = v.fields[1].id;
      final String before = v.templates.single.back;
      final String extra = await a.addField(nt, 'Extra');
      await a.renameField(nt, front, 'Question');
      v = await type(a, nt);
      expect(v.fields.map((SrsFieldDef f) => f.name), <String>[
        'Question',
        'Back',
        'Extra',
      ]);
      expect(v.templates.single.back, before, reason: '按 fieldId 引用，改名不动模板');
      await a.reorderFields(nt, <String>[extra, front, back]);
      v = await type(a, nt);
      expect(v.fields.map((SrsFieldDef f) => f.name), <String>[
        'Extra',
        'Question',
        'Back',
      ]);

      await a.deleteField(nt, back);
      v = await type(a, nt);
      expect(v.fields.map((SrsFieldDef f) => f.id), <String>[extra, front]);
      expect(v.templates.single.back, isNot(contains(back)));
      expect(v.templates.single.front, contains(front));

      final SrsNoteTypeView lapis = await type(a, a.lapisNoteTypeId);
      expect(a.canDeleteNoteType(lapis), isFalse);
      await expectLater(a.deleteNoteType(lapis.id), throwsStateError);
      await expectLater(
        a.deleteField(lapis.id, srsLapisFieldId(kProfile, 'Sentence')),
        throwsStateError,
      );
      // 内置项可以改：改过的那一项由修改记录决定，其余仍跟随代码。
      await a.renameNoteType(lapis.id, 'Lapis（我的）');
      final String mine = await a.addField(lapis.id, 'MyNote');
      final SrsNoteTypeView lapis2 = await type(a, lapis.id);
      expect(lapis2.name, 'Lapis（我的）');
      expect(lapis2.fields.last.id, mine);
      expect(
        lapis2.edits.keys.where((String k) => k.startsWith('fieldDef/')),
        <String>[SrsFieldKeys.fieldDef(mine)],
      );
    });

    test('删字段带模板改写（prepareTemplate）：成功时改写与删除同一次落库；删不掉时模板与字段都不变', () async {
      final SrsDbStore a = await device('a');
      final String nt = await a.createStockNoteType(
        SrsStockNoteType.basic,
        '问答',
      );
      SrsNoteTypeView v = await type(a, nt);
      final String front = v.fields[0].id;
      final String back = v.fields[1].id;
      final String tplId = v.templates.single.id;
      Set<String> liveEditIds(SrsNoteTypeView x) => <String>{
        for (final String k in x.edits.keys)
          for (final SrsFieldEdit e in x.edits[k]!.live) e.id,
      };
      int calls = 0;
      SrsTemplateDef rewrite(SrsNoteTypeView type, SrsTemplateDef tpl) {
        calls++;
        return tpl.copyWith(
          front: '<!--rewritten-->${tpl.front}',
          back: '<!--rewritten-->${tpl.back}',
        );
      }

      // 成功：改写结果再剥掉被删字段的引用，一起落库。
      final Set<String> editsBefore = liveEditIds(v);
      await a.deleteField(nt, back, prepareTemplate: rewrite);
      v = await type(a, nt);
      expect(calls, 1);
      expect(v.fieldById(back), isNull);
      expect(v.templates.single.front, startsWith('<!--rewritten-->'));
      expect(v.templates.single.back, startsWith('<!--rewritten-->'));
      expect(v.templates.single.back, isNot(contains(back)));
      expect(
        liveEditIds(v).difference(editsBefore).length,
        2,
        reason: '字段删除标记 + 模板定义，同一批写入',
      );

      // 失败：只剩一个字段 → 抛错，改写从没被调用，模板与字段都原样。
      final SrsTemplateDef tplBefore = v.templates.single;
      final Set<String> editsBeforeFail = liveEditIds(v);
      await expectLater(
        a.deleteField(nt, front, prepareTemplate: rewrite),
        throwsStateError,
      );
      v = await type(a, nt);
      expect(calls, 1, reason: '校验先于改写');
      expect(v.fieldById(front), isNotNull);
      expect(v.templates.single.id, tplId);
      expect(v.templates.single.front, tplBefore.front);
      expect(v.templates.single.back, tplBefore.back);
      expect(liveEditIds(v), editsBeforeFail, reason: '一条记录都不写');

      // 内置字段同理。
      final SrsNoteTypeView lapis = await type(a, a.lapisNoteTypeId);
      final List<SrsTemplateDef> lapisTpls = lapis.templates;
      await expectLater(
        a.deleteField(
          lapis.id,
          srsLapisFieldId(kProfile, 'Sentence'),
          prepareTemplate: rewrite,
        ),
        throwsStateError,
      );
      final SrsNoteTypeView lapisAfter = await type(a, lapis.id);
      expect(
        lapisAfter.templates.map((SrsTemplateDef x) => x.front),
        lapisTpls.map((SrsTemplateDef x) => x.front),
      );
      expect(calls, 1);
    });

    test('字段说明：独立键，一台改说明一台改名不冲突；克隆带上；说明没变不写记录；导出 .apkg 带上', () async {
      final SrsDbStore a = await device('a');
      final SrsDbStore b = await device('b');
      final String nt = await a.createStockNoteType(
        SrsStockNoteType.basic,
        '问答',
      );
      final SrsNoteTypeView v0 = await type(a, nt);
      final String front = v0.fields[0].id;
      final String back = v0.fields[1].id;
      await a.setFieldDescription(nt, back, '  中文释义  ');
      expect((await type(a, nt)).fieldById(back)!.description, '中文释义');
      final String key = SrsFieldKeys.fieldDescription(back);
      expect(
        ((await type(a, nt)).edits.value(SrsFieldKeys.fieldDef(back))! as Map)
            .containsKey('description'),
        isFalse,
        reason: '说明不写进字段定义',
      );
      final String before = (await type(
        a,
        nt,
      )).edits[key]!.live.map((SrsFieldEdit e) => e.id).join();
      await a.setFieldDescription(nt, back, '中文释义');
      expect(
        (await type(
          a,
          nt,
        )).edits[key]!.live.map((SrsFieldEdit e) => e.id).join(),
        before,
        reason: '没变不写',
      );
      await syncAll(<SrsDbStore>[a, b]);
      // 离线并发：a 改说明、b 改名 → 合并后两样都在，没有待裁决的冲突。
      await a.setFieldDescription(nt, back, '中文释义（新）');
      await b.renameField(nt, back, 'Meaning');
      await syncAll(<SrsDbStore>[a, b]);
      for (final SrsDbStore s in <SrsDbStore>[a, b]) {
        final SrsNoteTypeView v = await type(s, nt);
        expect(v.fieldById(back)!.name, 'Meaning');
        expect(v.fieldById(back)!.description, '中文释义（新）');
        expect(v.edits.conflicted, isEmpty);
      }

      final String clone = await a.cloneNoteType(nt, '问答 副本');
      expect(
        (await type(a, clone)).fields
            .firstWhere((SrsFieldDef f) => f.name == 'Meaning')
            .description,
        '中文释义（新）',
      );

      await a.createNote(
        noteTypeId: nt,
        fieldsById: <String, String>{front: 'Q', back: 'A'},
      );
      final SrsAnkiPackage p = SrsAnkiPackage.open(
        await exportAnkiPackage(store: a),
        zstd: (Uint8List b) => null,
      );
      final SrsAnkiCollection col = await SrsAnkiCollection.open(
        p.collectionBytes,
      );
      try {
        final SrsAnkiNoteType exported = col.noteTypes.values.firstWhere(
          (SrsAnkiNoteType x) => x.name == '问答',
        );
        expect(
          exported.fields
              .firstWhere((SrsAnkiField f) => f.name == 'Meaning')
              .description,
          '中文释义（新）',
          reason: '导出时写进 Anki 的字段说明，再读回来一致',
        );
      } finally {
        await col.close();
      }
    });

    test('两台设备离线各加一个字段，合并后两个都在（按项合并，铁律 D）', () async {
      final SrsDbStore a = await device('a');
      final SrsDbStore b = await device('b');
      final String nt = await a.createStockNoteType(
        SrsStockNoteType.basic,
        'Basic',
      );
      await syncAll(<SrsDbStore>[a, b]);
      await a.addField(nt, 'FromA');
      t += 1000;
      await b.addField(nt, 'FromB');
      await syncAll(<SrsDbStore>[a, b]);
      for (final SrsDbStore s in <SrsDbStore>[a, b]) {
        expect(
          (await type(s, nt)).fields.map((SrsFieldDef f) => f.name).toSet(),
          <String>{'Front', 'Back', 'FromA', 'FromB'},
        );
      }
    });

    test('删除笔记类型连同它的笔记；克隆得到独立的新类型', () async {
      final SrsDbStore a = await device('a');
      final String nt = await a.createStockNoteType(
        SrsStockNoteType.basicReversed,
        'Rev',
      );
      final SrsNoteTypeView v = await type(a, nt);
      final String copy = await a.cloneNoteType(nt, 'Rev copy');
      final SrsNoteTypeView c = await type(a, copy);
      expect(c.templates, hasLength(2));
      expect(
        c.fields.map((SrsFieldDef f) => f.id).toSet(),
        isNot(contains(v.fields.first.id)),
      );
      expect(c.templates[1].front, '{{fld:${c.fields[1].id}}}');

      final String note = await a.createNote(
        noteTypeId: nt,
        fieldsById: <String, String>{v.fields[0].id: 'x'},
      );
      await a.deleteNoteType(nt);
      expect((await a.note(note))!.deletedAt, isNotNull);
      expect(
        (await a.noteTypes()).map((SrsNoteTypeView x) => x.id),
        isNot(contains(nt)),
      );
      expect(
        (await a.noteTypes()).map((SrsNoteTypeView x) => x.id),
        contains(copy),
      );
    });
  });

  group('更改笔记类型', () {
    test('字段按映射搬值、新卡继承复习历史与标志、没映射的旧卡不再生成；同步后对端一致', () async {
      final SrsDbStore a = await device('a');
      final SrsDbStore b = await device('b');
      final String from = await a.createStockNoteType(
        SrsStockNoteType.basicReversed,
        'Rev',
      );
      final String to = await a.createStockNoteType(
        SrsStockNoteType.basic,
        'Basic',
      );
      final SrsNoteTypeView vf = await type(a, from);
      final SrsNoteTypeView vt = await type(a, to);
      final String note = await a.createNote(
        noteTypeId: from,
        fieldsById: <String, String>{
          vf.fields[0].id: '猫',
          vf.fields[1].id: 'cat',
        },
      );
      final String card1 = SrsIds.card(note, vf.templates[0].id, 0);
      final String card2 = SrsIds.card(note, vf.templates[1].id, 0);
      final SrsReviewLog l1 = await a.answer(card2, 3);
      t += 60000;
      final SrsReviewLog l2 = await a.answer(card2, 3);
      await a.setFlag(card2, 3);
      final SrsCardCacheRow before = (await a.cardRow(card2))!;
      await syncAll(<SrsDbStore>[a, b]);

      final Map<String, String?> fieldMap = <String, String?>{
        vt.fields[0].id: vf.fields[1].id,
        vt.fields[1].id: vf.fields[0].id,
      };
      final Map<String, String?> tplMap = <String, String?>{
        vt.templates[0].id: vf.templates[1].id,
      };
      final SrsNoteTypeChangePreview p = await a.previewNoteTypeChange(
        noteIds: <String>[note],
        targetTypeId: to,
        fieldMap: fieldMap,
        templateMap: tplMap,
      );
      expect(p.droppedCards, 1);
      expect(p.linkedCards, 1);
      await a.changeNoteType(
        noteIds: <String>[note],
        targetTypeId: to,
        fieldMap: fieldMap,
        templateMap: tplMap,
      );

      final String newCard = SrsIds.card(note, vt.templates[0].id, 0);
      Future<void> check(SrsDbStore s) async {
        final SrsNoteView n = (await s.note(note))!;
        expect(n.noteTypeId, to);
        expect(n.field(vt.fields[0].id), 'cat');
        expect(n.field(vt.fields[1].id), '猫');
        expect(
          await s.cardRow(card1),
          isNull,
          reason: '前身卡不再生成，删缓存行；增量与重建同一张表',
        );
        expect(await s.cardRow(card2), isNull);
        final SrsCardCacheRow c = (await s.cardRow(newCard))!;
        expect(c.hidden, isFalse);
        expect(c.lastLogId, l2.id, reason: '排程状态 = 继承历史里最后一条有效日志');
        expect(c.queue, before.queue);
        expect(c.dueAt, before.dueAt);
        expect(c.reps, before.reps);
        expect(c.flag, 3, reason: '旗标沿前身继承');
        expect(
          (await s.history(newCard)).all.map((SrsReviewLog l) => l.id).toSet(),
          <String>{l1.id, l2.id},
        );
        expect((await s.noteCountsByType())[to], 1);
        expect((await s.noteCountsByType())[from], isNull);
      }

      await check(a);
      await syncAll(<SrsDbStore>[a, b]);
      await check(b);

      // 在新卡上继续复习、撤销：起点是继承来的历史。
      t += 60000;
      final SrsReviewLog l3 = await b.answer(newCard, 4);
      expect(l3.cardId, newCard);
      expect(await b.undo(newCard, l3.id), isTrue);
      expect((await b.cardRow(newCard))!.lastLogId, l2.id);
    });

    test('对端并发复习旧卡（还没收到换类型）：那次复习同步后流到新卡上', () async {
      final SrsDbStore a = await device('a');
      final SrsDbStore b = await device('b');
      final String to = await a.createStockNoteType(
        SrsStockNoteType.basic,
        'Basic',
      );
      final SrsNoteTypeView lapis = await type(a, a.lapisNoteTypeId);
      final SrsNoteTypeView vt = await type(a, to);
      final String note = await a.createNote(
        noteTypeId: lapis.id,
        fieldsById: <String, String>{
          srsLapisFieldId(kProfile, 'Expression'): '犬',
        },
      );
      final String oldCard = (await a.cardsOfNote(note)).single.id;
      await syncAll(<SrsDbStore>[a, b]);

      await a.changeNoteType(
        noteIds: <String>[note],
        targetTypeId: to,
        fieldMap: srsDefaultFieldMap(lapis, vt)
          ..[vt.fields[0].id] = srsLapisFieldId(kProfile, 'Expression'),
        templateMap: <String, String?>{
          vt.templates[0].id: lapis.templates[0].id,
        },
      );
      t += 1000;
      final SrsReviewLog offline = await b.answer(oldCard, 3);
      await syncAll(<SrsDbStore>[a, b]);
      final String newCard = SrsIds.card(note, vt.templates[0].id, 0);
      for (final SrsDbStore s in <SrsDbStore>[a, b]) {
        expect((await s.cardRow(newCard))!.lastLogId, offline.id);
        expect((await s.note(note))!.field(vt.fields[0].id), '犬');
      }
    });

    test('两台设备并发换成不同类型：最后修改生效、进同步冲突记录；并发改同一字段定义 = 待裁决', () async {
      final SrsDbStore a = await device('a');
      final SrsDbStore b = await device('b');
      final String t1 = await a.createStockNoteType(
        SrsStockNoteType.basic,
        'T1',
      );
      final String t2 = await a.createStockNoteType(
        SrsStockNoteType.basic,
        'T2',
      );
      final SrsNoteTypeView lapis = await type(a, a.lapisNoteTypeId);
      final String note = await a.createNote(
        noteTypeId: lapis.id,
        fieldsById: <String, String>{
          srsLapisFieldId(kProfile, 'Expression'): '魚',
        },
      );
      await syncAll(<SrsDbStore>[a, b]);
      final SrsNoteTypeView v1 = await type(a, t1);
      final SrsNoteTypeView v2 = await type(a, t2);
      await a.changeNoteType(
        noteIds: <String>[note],
        targetTypeId: t1,
        fieldMap: srsDefaultFieldMap(lapis, v1),
        templateMap: srsDefaultTemplateMap(lapis, v1),
      );
      await a.renameField(t1, v1.fields[0].id, 'A 的名字');
      t += 1000;
      await b.changeNoteType(
        noteIds: <String>[note],
        targetTypeId: t2,
        fieldMap: srsDefaultFieldMap(lapis, v2),
        templateMap: srsDefaultTemplateMap(lapis, v2),
      );
      await b.renameField(t1, v1.fields[0].id, 'B 的名字');
      await syncAll(<SrsDbStore>[a, b]);
      for (final SrsDbStore s in <SrsDbStore>[a, b]) {
        expect((await s.note(note))!.noteTypeId, t2, reason: '较晚的修改生效');
        expect(
          (await s.syncConflicts()).any(
            ((SrsEntityKind, String, SrsRegister) c) =>
                c.$2 == note && c.$3.key == SrsFieldKeys.noteType,
          ),
          isTrue,
        );
        final SrsNoteTypeView nt1 = await type(s, t1);
        expect(nt1.edits.conflicted.map((SrsRegister r) => r.key), <String>[
          SrsFieldKeys.fieldDef(v1.fields[0].id),
        ]);
      }
    });

    test('多条笔记一次换；源类型不同时拒绝', () async {
      final SrsDbStore a = await device('a');
      final String to = await a.createStockNoteType(
        SrsStockNoteType.basic,
        'Basic',
      );
      final SrsNoteTypeView lapis = await type(a, a.lapisNoteTypeId);
      final SrsNoteTypeView vt = await type(a, to);
      final List<String> notes = <String>[
        for (final String w in <String>['一', '二', '三'])
          await a.createNote(
            noteTypeId: lapis.id,
            fieldsById: <String, String>{
              srsLapisFieldId(kProfile, 'Expression'): w,
            },
          ),
      ];
      await a.changeNoteType(
        noteIds: notes,
        targetTypeId: to,
        fieldMap: <String, String?>{
          vt.fields[0].id: srsLapisFieldId(kProfile, 'Expression'),
        },
        templateMap: srsDefaultTemplateMap(lapis, vt),
      );
      expect((await a.noteCountsByType())[to], 3);
      final String other = await a.createNote(
        noteTypeId: lapis.id,
        fieldsById: <String, String>{
          srsLapisFieldId(kProfile, 'Expression'): '四',
        },
      );
      await expectLater(
        a.sourceTypeOf(<String>[notes.first, other]),
        throwsArgumentError,
      );
    });

    test(
      '导出 .apkg：新类型 / 字段 / 模板带 Anki id；Fushi 回导（同 / 新 profile）继承历史不丢',
      () async {
        final SrsDbStore a = await device('a');
        final String to = await a.createStockNoteType(
          SrsStockNoteType.basicReversed,
          'Mine',
        );
        final SrsNoteTypeView lapis = await type(a, a.lapisNoteTypeId);
        final SrsNoteTypeView vt = await type(a, to);
        final String note = await a.createNote(
          noteTypeId: lapis.id,
          fieldsById: <String, String>{
            srsLapisFieldId(kProfile, 'Expression'): '鳥',
          },
        );
        final String oldCard = (await a.cardsOfNote(note)).single.id;
        final SrsReviewLog l = await a.answer(oldCard, 3);
        await a.changeNoteType(
          noteIds: <String>[note],
          targetTypeId: to,
          fieldMap: <String, String?>{
            vt.fields[0].id: srsLapisFieldId(kProfile, 'Expression'),
          },
          templateMap: <String, String?>{
            vt.templates[0].id: lapis.templates[0].id,
          },
        );
        final String newCard = SrsIds.card(note, vt.templates[0].id, 0);
        t += 86400000;
        final Uint8List pkg = await exportAnkiPackage(store: a);

        final SrsAnkiPackage p = SrsAnkiPackage.open(
          pkg,
          zstd: (Uint8List b) => null,
        );
        final SrsAnkiCollection col = await SrsAnkiCollection.open(
          p.collectionBytes,
        );
        try {
          final Map<String, Object?> models =
              (jsonDecode(
                        col.db.select('SELECT models FROM col').single['models']
                            as String,
                      )
                      as Map)
                  .cast<String, Object?>();
          final Map<Object?, Object?> m = models['${vt.ankiNum}']! as Map;
          expect(m['name'], 'Mine');
          final List<Object?> flds = m['flds']! as List<Object?>;
          expect(flds.map((Object? f) => (f! as Map)['name']), <String>[
            'Front',
            'Back',
          ]);
          expect((flds.first! as Map)['id'], vt.fields.first.ankiNum);
          final List<Object?> tmpls = m['tmpls']! as List<Object?>;
          expect((tmpls[0]! as Map)['qfmt'], '{{Front}}');
          expect((tmpls[1]! as Map)['qfmt'], '{{Back}}');
          expect((tmpls[1]! as Map)['id'], vt.templates[1].ankiNum);
          final List<Row> rev = col.db
              .select('SELECT cid FROM revlog')
              .toList();
          expect(
            rev.single['cid'],
            SrsIds.ankiNumericId(newCard),
            reason: '继承来的复习记录归到新卡',
          );
          expect(
            col.db.select('SELECT mid FROM notes').single['mid'],
            vt.ankiNum,
          );
        } finally {
          await col.close();
        }

        Future<String> sink(String name, Uint8List bytes) async => name;

        // 同 profile 的新设备（没同步过）：日志落回前身卡、补上前身链接。
        final SrsDbStore fresh = await device('c');
        await importAnkiPackage(
          store: fresh,
          bytes: pkg,
          storeMedia: sink,
          zstdDecompress: (Uint8List b) => null,
          // 继承历史随排程一起导入；导入默认（对齐 Anki）不带排程。
          options: const SrsAnkiImportOptions(withScheduling: true),
        );
        expect((await fresh.note(note))!.noteTypeId, to);
        expect((await fresh.cardRow(newCard))!.lastLogId, l.id);

        // 另一个 profile：日志重映射到新卡。
        final SrsDbStore other = await device('d', profile: kProfile2);
        await importAnkiPackage(
          store: other,
          bytes: pkg,
          storeMedia: sink,
          zstdDecompress: (Uint8List b) => null,
          // 继承历史随排程一起导入；导入默认（对齐 Anki）不带排程。
          options: const SrsAnkiImportOptions(withScheduling: true),
        );
        final String otherNote = SrsIds.note(
          kProfile2,
          (await a.note(note))!.guid,
        );
        final SrsNoteTypeView otherType = (await other.noteTypes()).firstWhere(
          (SrsNoteTypeView x) => x.name == 'Mine',
        );
        final String otherCard = SrsIds.card(
          otherNote,
          otherType.templates[0].id,
          0,
        );
        expect(
          (await other.history(
            otherCard,
          )).effective.map((SrsReviewLog x) => x.rating),
          <int?>[3],
        );
      },
    );
  });
}

/// 测试里把「名字写的模板」换成 fieldId 引用（与编辑器保存时同一个函数）。
String templateNamesToIdsFor(SrsNoteTypeView v, String tpl) =>
    templateNamesToIds(tpl, <String, String>{
      for (final SrsFieldDef f in v.fields) f.name: f.id,
    });
