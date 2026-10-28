import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_builtin_migration.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000001';

/// 内置「Fushi 卡片」：确定性播种、与 Lapis 互不相同的 ID、读音键、内置字段不可删，
/// 以及 Lapis → Fushi 卡片 一键迁移（按字段键直映、复习历史随迁、改过名的字段照样对上）。
void main() {
  int t = DateTime.utc(2026, 10, 16, 12).millisecondsSinceEpoch;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> device(String id) =>
      openTestStore(profileUid: kProfile, deviceId: id, now: () => t);

  setUp(() => t = DateTime.utc(2026, 10, 16, 12).millisecondsSinceEpoch);

  test(
    'two built-in note types are seeded with distinct deterministic ids',
    () async {
      final SrsDbStore a = await device('a');
      final SrsDbStore b = await device('b');
      expect(a.fushiCardNoteTypeId, b.fushiCardNoteTypeId);
      expect(a.fushiCardNoteTypeId, isNot(a.lapisNoteTypeId));
      final SrsNoteTypeView fushi = (await a.noteType(a.fushiCardNoteTypeId))!;
      expect(fushi.builtinKey, kSrsBuiltinFushiCardKey);
      expect(fushi.name, FushiCardNoteType.modelName);
      expect(
        fushi.fields.map((SrsFieldDef f) => f.name),
        FushiCardNoteType.fields,
      );
      expect(fushi.fields.last.name, 'SentenceTranslation');
      expect(fushi.css, FushiCardNoteType.template.css);
      expect(fushi.templates.single.name, FushiCardNoteType.cardName);
      // Lapis 的 ID 与改造前完全一致（存量数据不动）。
      expect(
        a.lapisNoteTypeId,
        SrsIds.noteType(kProfile, SrsIds.builtinNoteTypeAnkiNum('lapis')),
      );
      final Set<String> fushiFields = fushi.fields
          .map((SrsFieldDef f) => f.id)
          .toSet();
      final SrsNoteTypeView lapis = (await a.noteType(a.lapisNoteTypeId))!;
      expect(
        lapis.fields
            .map((SrsFieldDef f) => f.id)
            .toSet()
            .intersection(fushiFields),
        isEmpty,
      );
      expect(
        (await a.noteTypes()).map((SrsNoteTypeView v) => v.builtinKey),
        containsAll(<String>[kSrsBuiltinLapisKey, kSrsBuiltinFushiCardKey]),
      );
      expect(a.isBuiltinField(fushi, fushi.fields.first.id), isTrue);
      expect(a.canDeleteNoteType(fushi), isFalse);
    },
  );

  test('Fushi card notes get a reading key like Lapis', () async {
    final SrsDbStore a = await device('a');
    final String note = await a.createNote(
      noteTypeId: a.fushiCardNoteTypeId,
      fieldsById: <String, String>{
        srsFushiCardFieldId(kProfile, 'Expression'): '通う',
        srsFushiCardFieldId(kProfile, 'ExpressionReading'): 'かよう',
      },
    );
    final SrsNoteCacheRow row = await (a.db.select(
      a.db.srsNotesCache,
    )..where((r) => r.id.equals(note))).getSingle();
    expect(row.termKey, isNotEmpty);
    expect(row.readingKey, isNotEmpty);
    expect(await a.cardsOfNote(note), hasLength(1));
  });

  test(
    'Lapis → Fushi card: fields map by key (even renamed), history moves',
    () async {
      final SrsDbStore a = await device('a');
      final String lapisId = a.lapisNoteTypeId;
      final SrsNoteTypeView lapis = (await a.noteType(lapisId))!;
      // 用户把 Lapis 的 Sentence 字段改过名：按字段键仍对得上。
      final String sentenceId = srsLapisFieldId(kProfile, 'Sentence');
      await a.renameField(lapisId, sentenceId, 'Context');
      final String note = await a.createNote(
        noteTypeId: lapisId,
        fieldsById: <String, String>{
          srsLapisFieldId(kProfile, 'Expression'): '切磋琢磨',
          srsLapisFieldId(kProfile, 'ExpressionReading'): 'せっさたくま',
          sentenceId: '互いに<b>切磋琢磨</b>する',
          srsLapisFieldId(kProfile, 'Glossary'): '<ol><li>gloss</li></ol>',
        },
      );
      final String oldCard = SrsIds.card(note, lapis.templates.single.id, 0);
      final SrsReviewLog l1 = await a.answer(oldCard, 3);
      t += 86400000;
      final SrsReviewLog l2 = await a.answer(oldCard, 3);

      expect(await a.lapisNoteIds(), <String>[note]);
      final SrsNoteTypeChangePreview p = await a.previewMigrateToFushiCard(
        <String>[note],
      );
      expect(p.droppedCards, 0);
      expect(p.linkedCards, 1);
      expect(await a.migrateToFushiCard(<String>[note]), 1);

      final SrsNoteView n = (await a.note(note))!;
      expect(n.noteTypeId, a.fushiCardNoteTypeId);
      expect(n.field(srsFushiCardFieldId(kProfile, 'Expression')), '切磋琢磨');
      expect(
        n.field(srsFushiCardFieldId(kProfile, 'Sentence')),
        '互いに<b>切磋琢磨</b>する',
      );
      expect(
        n.field(srsFushiCardFieldId(kProfile, 'Glossary')),
        '<ol><li>gloss</li></ol>',
      );
      expect(n.field(srsFushiCardFieldId(kProfile, 'SentenceTranslation')), '');
      final SrsNoteTypeView fushi = (await a.noteType(a.fushiCardNoteTypeId))!;
      final String newCard = SrsIds.card(note, fushi.templates.single.id, 0);
      expect(await a.cardRow(oldCard), isNull, reason: '旧卡不再生成，删缓存行；增量与重建同一张表');
      final SrsCardCacheRow c = (await a.cardRow(newCard))!;
      expect(c.hidden, isFalse);
      expect(c.lastLogId, l2.id);
      expect(
        (await a.history(newCard)).all.map((SrsReviewLog l) => l.id).toSet(),
        <String>{l1.id, l2.id},
      );
      expect(await a.lapisNoteIds(), isEmpty);
      expect((await a.noteCountsByType())[a.fushiCardNoteTypeId], 1);
    },
  );

  test(
    'preset maps: built-in keys first, extra Lapis fields by name',
    () async {
      final SrsDbStore a = await device('a');
      final String lapisId = a.lapisNoteTypeId;
      await a.addField(lapisId, 'SentenceTranslation');
      await a.addField(lapisId, 'MyNotes');
      final SrsNoteTypeView from = (await a.noteType(lapisId))!;
      final SrsNoteTypeView to = (await a.noteType(a.fushiCardNoteTypeId))!;
      final SrsBuiltinMigrationMaps maps = srsBuiltinMigrationMaps(
        kProfile,
        from,
        to,
      );
      for (final String key in LapisNoteType.fields) {
        expect(
          maps.fieldMap[srsFushiCardFieldId(kProfile, key)],
          srsLapisFieldId(kProfile, key),
          reason: key,
        );
      }
      final String userTranslation = from.fields
          .firstWhere((SrsFieldDef f) => f.name == 'SentenceTranslation')
          .id;
      expect(
        maps.fieldMap[srsFushiCardFieldId(kProfile, 'SentenceTranslation')],
        userTranslation,
      );
      expect(
        maps.templateMap[to.templates.single.id],
        from.templates.single.id,
      );
    },
  );

  test(
    'renderCard gives the definitions-only back only for an unmodified Fushi card',
    () async {
      final SrsDbStore a = await device('a');
      Future<SrsRenderedCard> render(
        String typeId,
        String Function(String) field,
      ) async {
        final String note = await a.createNote(
          noteTypeId: typeId,
          fieldsById: <String, String>{
            field('Expression'): '通う',
            field('MainDefinition'): '<ol><li>to commute</li></ol>',
          },
        );
        final SrsCardCacheRow card = (await a.cardsOfNote(note)).first;
        return (await a.renderCard(card.id))!;
      }

      final SrsRenderedCard fushi = await render(
        a.fushiCardNoteTypeId,
        (String n) => srsFushiCardFieldId(kProfile, n),
      );
      expect(fushi.fields['Expression'], '通う');
      expect(fushi.fushiCardDefinitions, contains('fc-defs-only'));
      expect(fushi.fushiCardDefinitions, contains('to commute'));
      expect(fushi.fushiCardDefinitions, isNot(contains('通う')));

      final SrsNoteTypeView lapisType = (await a.noteType(a.lapisNoteTypeId))!;
      final SrsRenderedCard lapis = await render(
        a.lapisNoteTypeId,
        (String n) =>
            lapisType.fields.firstWhere((SrsFieldDef f) => f.name == n).id,
      );
      expect(lapis.fushiCardDefinitions, isNull);

      // 用户改过 Fushi 卡片的样式：回到整面 WebView（不再原生渲染）。
      await a.setCss(
        a.fushiCardNoteTypeId,
        '${FushiCardNoteType.template.css} .x{}',
      );
      final SrsRenderedCard edited = await render(
        a.fushiCardNoteTypeId,
        (String n) => srsFushiCardFieldId(kProfile, n),
      );
      expect(edited.fushiCardDefinitions, isNull);
    },
  );
}
