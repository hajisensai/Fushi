// SRS 写入路径周边的读放大（H1 / H5 / M2 / L1 / L2）的行为测试：
// - 笔记类型只有影响缓存的键（字段 / 模板定义、词条字段、删除）才让整类笔记重算；
// - 内容指纹（同步冲突等整库角标的缓存键）不随复习日志、牌组收起 / 展开变；
// - 词状态成批查询与逐个查询同结果；
// - 模板编辑器保存合成一次写入；
// - 只取 id / 计数的查询与旧口径同结果。
import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'support/srs_sync2_peers.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000a1';

void main() {
  int t = DateTime.utc(2026, 10, 22, 12).millisecondsSinceEpoch;
  late SrsMemoryLocationStore dir;

  Future<SrsDbStore> device(String id) =>
      openTestStore(profileUid: kProfile, deviceId: id, now: () => t);

  Future<void> syncAll(List<SrsDbStore> stores) async {
    for (int round = 0; round < 3; round++) {
      for (final SrsDbStore s in stores) {
        await srsSyncOnce(s, dir);
      }
    }
  }

  Map<String, String> lapis(String expr, {String reading = ''}) =>
      <String, String>{
        srsLapisFieldId(kProfile, 'Expression'): expr,
        srsLapisFieldId(kProfile, 'ExpressionReading'): reading,
      };

  /// 把这些笔记的缓存行做个记号：之后还在 = 缓存没被重算。
  Future<void> tamper(SrsDbStore s, Iterable<String> noteIds) async {
    for (final String id in noteIds) {
      await s.db.customStatement(
        "UPDATE srs_notes_cache SET sort_field = 'TAMPERED' WHERE id = srs_id(?)",
        <Object>[id],
      );
    }
  }

  Future<Set<String>> tampered(SrsDbStore s) async => <String>{
    for (final r
        in await s.db
            .customSelect(
              "SELECT id FROM srs_notes_cache WHERE sort_field = 'TAMPERED'",
            )
            .get())
      r.read<String>('id'),
  };

  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    t = DateTime.utc(2026, 10, 22, 12).millisecondsSinceEpoch;
    dir = SrsMemoryLocationStore();
  });

  group('笔记类型改动的缓存影响面（H5）', () {
    test('名字 / CSS / 字段说明不重算该类型的笔记；模板 / 词条字段重算，且只重算该类型', () async {
      final SrsDbStore a = await device('a');
      final String nt = await a.createStockNoteType(
        SrsStockNoteType.basic,
        '问答',
      );
      final SrsNoteTypeView v = (await a.noteType(nt))!;
      final List<String> mine = <String>[
        for (final String w in <String>['猫', '犬', '鳥'])
          await a.createNote(
            noteTypeId: nt,
            fieldsById: <String, String>{v.fields[0].id: w},
          ),
      ];
      final String other = await a.createNote(
        noteTypeId: a.lapisNoteTypeId,
        fieldsById: lapis('魚'),
      );
      await tamper(a, <String>[...mine, other]);

      await a.setCss(nt, '.card { color: red; }');
      await a.renameNoteType(nt, '问答 2');
      await a.setFieldDescription(nt, v.fields[0].id, '说明');
      expect(await tampered(a), <String>{
        ...mine,
        other,
      }, reason: '这三类键不影响缓存行，不该把整类笔记重算');
      // 键确实写进去了。
      final SrsNoteTypeView after = (await a.noteType(nt))!;
      expect(after.css, '.card { color: red; }');
      expect(after.name, '问答 2');
      expect(after.fieldById(v.fields[0].id)!.description, '说明');

      await a.updateTemplate(
        nt,
        v.templates.single.id,
        back: '${v.templates.single.back}<hr>',
      );
      expect(await tampered(a), <String>{
        other,
      }, reason: '模板定义影响卡片生成：该类型笔记全部重算，别的类型不动');

      expect(v.termFieldId, v.fields[0].id, reason: '问答类型默认以第一个字段为词条');
      expect(
        (await a.lookupTermStatus(<SrsTermQuery>[
          const SrsTermQuery('犬'),
        ])).keys,
        <String>['犬'],
      );
      await tamper(a, mine);
      await a.setTermField(nt, v.fields[1].id);
      expect(await tampered(a), <String>{other});
      expect(
        await a.lookupTermStatus(<SrsTermQuery>[const SrsTermQuery('犬')]),
        isEmpty,
        reason: '词条字段改了，termKey 随缓存重算',
      );
    });

    test('换过类型的笔记按当前类型重算（成员查找走笔记缓存）', () async {
      final SrsDbStore a = await device('a');
      final String src = await a.createStockNoteType(
        SrsStockNoteType.basic,
        '源',
      );
      final SrsNoteTypeView sv = (await a.noteType(src))!;
      final String dst = await a.createStockNoteType(
        SrsStockNoteType.basic,
        '目标',
      );
      final SrsNoteTypeView dv = (await a.noteType(dst))!;
      final String note = await a.createNote(
        noteTypeId: src,
        fieldsById: <String, String>{sv.fields[0].id: '猫'},
      );
      await a.changeNoteType(
        noteIds: <String>[note],
        targetTypeId: dst,
        fieldMap: <String, String?>{
          for (int i = 0; i < dv.fields.length; i++)
            dv.fields[i].id: sv.fields[i].id,
        },
        templateMap: <String, String?>{
          dv.templates.single.id: sv.templates.single.id,
        },
      );
      await tamper(a, <String>[note]);
      // 改创建时的类型：笔记已不属于它，不重算。
      await a.updateTemplate(src, sv.templates.single.id, back: 'x');
      expect(await tampered(a), <String>{note});
      // 改当前类型：重算。
      await a.updateTemplate(dst, dv.templates.single.id, back: 'y');
      expect(await tampered(a), isEmpty);
    });

    test('对端先到笔记、后到笔记类型：类型到达时这些笔记照样重算', () async {
      final SrsDbStore a = await device('a');
      final SrsDbStore b = await device('b');
      final String nt = await a.createStockNoteType(
        SrsStockNoteType.basic,
        '问答',
      );
      final SrsNoteTypeView v = (await a.noteType(nt))!;
      final String note = await a.createNote(
        noteTypeId: nt,
        fieldsById: <String, String>{v.fields[0].id: '猫'},
      );
      // b 只收笔记的事件（类型缺失：卡片生成不出来），再收类型的事件。
      final List<SrsEvent> all = await a.exportAll();
      bool isType(SrsEvent e) => switch (e) {
        SrsEntityEvent(:final SrsEntityRecord record) =>
          record.kind == SrsEntityKind.noteType && record.id == nt,
        SrsEditEvent(:final SrsFieldEdit edit) =>
          edit.entityKind == SrsEntityKind.noteType && edit.entityId == nt,
        _ => false,
      };
      await b.importEvents(<SrsEvent>[
        for (final SrsEvent e in all)
          if (!isType(e)) e,
      ]);
      expect(
        (await b.cardsOfNote(note)).where((SrsCardCacheRow c) => !c.hidden),
        isEmpty,
      );
      await b.importEvents(<SrsEvent>[
        for (final SrsEvent e in all)
          if (isType(e)) e,
      ]);
      expect(
        (await b.cardsOfNote(note)).where((SrsCardCacheRow c) => !c.hidden),
        hasLength(1),
      );
    });
  });

  group('内容指纹（H1）', () {
    test('评分（只落日志）、牌组收起 / 展开不变；改卡片标志、改笔记会变；修订号都推进', () async {
      final SrsDbStore a = await device('a');
      final String note = await a.createNote(
        noteTypeId: a.lapisNoteTypeId,
        fieldsById: lapis('猫'),
      );
      final String card = (await a.cardsOfNote(note)).single.id;

      String fp = a.contentFingerprint;
      int rev = a.revision;
      await a.answer(card, 3);
      expect(a.contentFingerprint, fp, reason: '评分只落复习日志');
      expect(a.revision, greaterThan(rev));

      rev = a.revision;
      await a.setDeckCollapsed(a.defaultDeckId, true);
      expect(a.contentFingerprint, fp, reason: '收起 / 展开是界面状态');
      expect(a.revision, greaterThan(rev));

      await a.setSuspended(card, true);
      expect(a.contentFingerprint, isNot(fp), reason: '标志类修改可能产生同步冲突');

      fp = a.contentFingerprint;
      await a.updateNote(note, fieldsById: lapis('犬'));
      expect(a.contentFingerprint, isNot(fp));
    });

    test('待裁决计数与待裁决笔记列表同口径', () async {
      final SrsDbStore a = await device('a');
      final SrsDbStore b = await device('b');
      final String note = await a.createNote(
        noteTypeId: a.lapisNoteTypeId,
        fieldsById: lapis('魚'),
      );
      await syncAll(<SrsDbStore>[a, b]);
      expect(await a.pendingDecisionCount(), 0);
      // 两边并发改同一个内容字段 = 待裁决（删除与编辑并发走冲突中心，见设计 §5.3，不算待裁决）。
      await a.updateNote(note, fieldsById: lapis('魚1'));
      await b.updateNote(note, fieldsById: lapis('魚2'));
      final String fp = a.contentFingerprint;
      await syncAll(<SrsDbStore>[a, b]);
      expect(a.contentFingerprint, isNot(fp), reason: '对端事件落库');
      for (final SrsDbStore s in <SrsDbStore>[a, b]) {
        expect(
          await s.pendingDecisionCount(),
          (await s.notesPendingDecision()).length,
        );
        expect(await s.pendingDecisionCount(), 1);
      }
    });
  });

  group('词状态成批查询（M2）', () {
    test('一批与逐个同结果：读音过滤、同形异读、删除的笔记、暂停的卡、空词形', () async {
      final SrsDbStore a = await device('a');
      await a.createNote(
        noteTypeId: a.lapisNoteTypeId,
        fieldsById: lapis('上手', reading: 'じょうず'),
      );
      await a.createNote(
        noteTypeId: a.lapisNoteTypeId,
        fieldsById: lapis('上手', reading: 'うわて'),
      );
      final String noReading = await a.createNote(
        noteTypeId: a.lapisNoteTypeId,
        fieldsById: lapis('雪'),
      );
      final String gone = await a.createNote(
        noteTypeId: a.lapisNoteTypeId,
        fieldsById: lapis('雨'),
      );
      await a.deleteNote(gone);
      final String suspendedCard = (await a.cardsOfNote(noReading)).single.id;
      await a.setSuspended(suspendedCard, true);

      const List<SrsTermQuery> qs = <SrsTermQuery>[
        SrsTermQuery('上手', 'じょうず'),
        SrsTermQuery('<b>上手</b>'),
        SrsTermQuery('上手', 'へた'),
        SrsTermQuery('雪', 'ゆき'),
        SrsTermQuery('雨'),
        SrsTermQuery('未収録'),
        SrsTermQuery(''),
      ];
      final Map<String, SrsTermStatus> batch = await a.lookupTermStatus(qs);
      final Map<String, SrsTermStatus> single = <String, SrsTermStatus>{
        for (final SrsTermQuery q in qs)
          ...await a.lookupTermStatus(<SrsTermQuery>[q]),
      };
      String show(Map<String, SrsTermStatus> m) => <String>[
        for (final MapEntry<String, SrsTermStatus> e in m.entries)
          '${e.key}:${e.value.cardId}:${e.value.cardCount}:'
              '${e.value.queue}:${e.value.suspended}',
      ].join('|');
      expect(show(batch), show(single));
      expect(batch.keys.toSet(), <String>{'上手', '<b>上手</b>', '雪'});
      expect(batch['<b>上手</b>']!.cardCount, 2, reason: '不带读音：同形全算');
      expect(batch['上手']!.cardCount, 1, reason: '带读音：只算同读');
      expect(batch['雪']!.suspended, isTrue, reason: '笔记没写读音时任何读音都算');
    });
  });

  group('模板编辑器保存（H5）', () {
    test('模板 / CSS / 字段说明一次写入；没变的项不写', () async {
      final SrsDbStore a = await device('a');
      final String nt = await a.createStockNoteType(
        SrsStockNoteType.basic,
        '问答',
      );
      final SrsNoteTypeView v = (await a.noteType(nt))!;
      final SrsTemplateDef tpl = v.templates.single;
      final int before = a.revision;
      expect(
        await a.saveTemplateEdits(
          nt,
          tpl.id,
          front: '${tpl.front}!',
          back: tpl.back,
          css: '.x{}',
          fieldDescriptions: <String, String>{
            v.fields[0].id: ' 说明 ',
            v.fields[1].id: v.fields[1].description,
            'missing-field': '忽略',
          },
        ),
        isTrue,
      );
      expect(a.revision - before, 3, reason: '模板、CSS、一个字段说明');
      final SrsNoteTypeView after = (await a.noteType(nt))!;
      expect(after.templates.single.front, '${tpl.front}!');
      expect(after.css, '.x{}');
      expect(after.fieldById(v.fields[0].id)!.description, '说明');

      final int again = a.revision;
      expect(
        await a.saveTemplateEdits(
          nt,
          tpl.id,
          css: '.x{}',
          fieldDescriptions: <String, String>{v.fields[0].id: '说明'},
        ),
        isFalse,
      );
      expect(a.revision, again);
    });
  });

  group('只取所需列（L1 / L2）', () {
    test('noteIdsOfType / noteCountsByType / cardIdsInDecks 与整行口径一致', () async {
      final SrsDbStore a = await device('a');
      final List<String> notes = <String>[
        for (final String w in <String>['一', '二', '三'])
          await a.createNote(
            noteTypeId: a.lapisNoteTypeId,
            fieldsById: lapis(w),
          ),
      ];
      await a.deleteNote(notes[1]);
      expect(await a.noteIdsOfType(a.lapisNoteTypeId), <String>[
        notes[0],
        notes[2],
      ]);
      expect(await a.noteIdsOfType(a.lapisNoteTypeId, limit: 1), <String>[
        notes[0],
      ]);
      expect((await a.noteCountsByType())[a.lapisNoteTypeId], 2);
      final List<String> visible = <String>[
        for (final r
            in await a.db
                .customSelect(
                  'SELECT id FROM srs_cards_cache WHERE deck_id = ? AND hidden = 0',
                  variables: <Variable<Object>>[
                    Variable<String>(a.defaultDeckId, srsIdType),
                  ],
                )
                .get())
          r.read<String>('id'),
      ];
      expect(visible, hasLength(2));
      expect(
        (await a.cardIdsInDecks(<String>{a.defaultDeckId})).toSet(),
        visible.toSet(),
      );
    });
  });
}
