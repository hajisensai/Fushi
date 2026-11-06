import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_builtin_migration.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_legacy_lapis_migration.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000a1';

/// 旧 Lapis 变体 → Fushi 卡片：变体识别、按语义的字段映射、迁移时逐条兜底、对已迁移笔记的
/// 遗漏字段补迁（只补空字段、幂等、迁移前的类型被删了也能补）。
void main() {
  int t = DateTime.utc(2026, 10, 18, 12).millisecondsSinceEpoch;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> device() =>
      openTestStore(profileUid: kProfile, deviceId: 'a', now: () => t);

  setUp(() => t = DateTime.utc(2026, 10, 18, 12).millisecondsSinceEpoch);

  String fushi(String key) => srsFushiCardFieldId(kProfile, key);
  String lapis(String key) => srsLapisFieldId(kProfile, key);

  Future<SrsNoteTypeView> type(SrsDbStore s, String id) async =>
      (await s.noteType(id))!;

  /// 按名字找字段；Fushi 卡片的 9 个字段改过名（FushiCardFields），旧名作别名也认。
  String fieldNamed(SrsNoteTypeView v, String name) {
    final String alias = FushiCardFields.canonical(name);
    return v.fields
        .firstWhere((SrsFieldDef f) => f.name == name || f.name == alias)
        .id;
  }

  /// 「从 Anki 导入的 Lapis」形状：非内置、字段名同 Lapis、ID 全新。
  Future<String> importedLapis(SrsDbStore s, String name) =>
      s.cloneNoteType(s.lapisNoteTypeId, name);

  /// 旧版迁移的形状：只按同名映射（用户自加的「来源」等字段整列丢失）。
  Future<void> oldStyleMigrate(SrsDbStore s, List<String> notes) async {
    final SrsNoteTypeView from = await s.sourceTypeOf(notes);
    final SrsNoteTypeView to = await type(s, s.fushiCardNoteTypeId);
    await s.changeNoteType(
      noteIds: notes,
      targetTypeId: to.id,
      fieldMap: <String, String?>{
        for (final SrsFieldDef f in to.fields)
          f.id: from.fields
              .where(
                // 旧实现只认同名；Fushi 卡片 9 个字段改名前与 Lapis 同名，这里按旧名模拟。
                (SrsFieldDef x) =>
                    x.name.toLowerCase() ==
                    FushiCardFields.legacyNameOf(f.name).toLowerCase(),
              )
              .firstOrNull
              ?.id,
      },
      templateMap: <String, String?>{
        to.templates.single.id: from.templates.single.id,
      },
    );
  }

  group('variant detection', () {
    test(
      'built-in Lapis, named and fingerprinted imports; not others',
      () async {
        final SrsDbStore s = await device();
        expect(
          srsDetectLapisVariant(await type(s, s.lapisNoteTypeId)),
          SrsLapisVariantKind.builtinLapis,
        );
        expect(
          srsDetectLapisVariant(await type(s, s.fushiCardNoteTypeId)),
          isNull,
        );
        final String named = await importedLapis(s, 'Lapis (Hibiki)');
        expect(
          srsDetectLapisVariant(await type(s, named)),
          SrsLapisVariantKind.namedLapis,
        );
        // 导入后被用户改了名：字段指纹仍认得（字段名大小写 / 分隔符不敏感）。
        final String renamed = await importedLapis(s, '日语生词');
        final SrsNoteTypeView rv = await type(s, renamed);
        await s.renameField(
          renamed,
          fieldNamed(rv, 'MainDefinition'),
          'main_definition',
        );
        expect(
          srsDetectLapisVariant(await type(s, renamed)),
          SrsLapisVariantKind.lapisFields,
        );
        final String basic = await s.createStockNoteType(
          SrsStockNoteType.basic,
          'Basic',
        );
        expect(srsDetectLapisVariant(await type(s, basic)), isNull);
        final String cloze = await s.createStockNoteType(
          SrsStockNoteType.cloze,
          'Lapis Cloze',
        );
        expect(srsDetectLapisVariant(await type(s, cloze)), isNull);
      },
    );
  });

  group('semantic field plan', () {
    test('renamed / synonym fields land on their Fushi card slot', () async {
      final SrsDbStore s = await device();
      final String id = await importedLapis(s, 'My Lapis');
      SrsNoteTypeView v = await type(s, id);
      await s.renameField(id, fieldNamed(v, 'Expression'), 'Word');
      await s.renameField(id, fieldNamed(v, 'ExpressionReading'), 'Reading');
      await s.renameField(id, fieldNamed(v, 'MiscInfo'), 'Source');
      await s.addField(id, '例句翻译');
      await s.addField(id, 'Comment');
      v = await type(s, id);
      final SrsNoteTypeView to = await type(s, s.fushiCardNoteTypeId);
      final SrsLapisFieldPlan plan = srsLapisFieldPlan(kProfile, v, to);
      expect(plan.fieldMap[fushi('Expression')], fieldNamed(v, 'Word'));
      expect(
        plan.fieldMap[fushi('ExpressionReading')],
        fieldNamed(v, 'Reading'),
      );
      expect(plan.fieldMap[fushi('MiscInfo')], fieldNamed(v, 'Source'));
      expect(
        plan.fieldMap[fushi('SentenceTranslation')],
        fieldNamed(v, '例句翻译'),
      );
      expect(plan.fieldMap[fushi('Sentence')], fieldNamed(v, 'Sentence'));
      expect(plan.unmappedSources.map((SrsFieldDef f) => f.name), <String>[
        'Comment',
      ]);
    });

    test(
      'built-in Lapis: built-in field beats a same-slot custom field',
      () async {
        final SrsDbStore s = await device();
        await s.addField(s.lapisNoteTypeId, '来源');
        final SrsNoteTypeView from = await type(s, s.lapisNoteTypeId);
        final SrsNoteTypeView to = await type(s, s.fushiCardNoteTypeId);
        final SrsBuiltinMigrationMaps maps = srsBuiltinMigrationMaps(
          kProfile,
          from,
          to,
        );
        expect(maps.fieldMap[fushi('MiscInfo')], lapis('MiscInfo'));
        expect(
          srsLapisFieldPlan(kProfile, from, to).unmappedSources.single.name,
          '来源',
        );
      },
    );
  });

  test(
    'built-in Lapis migration fills an empty slot from a custom field per note',
    () async {
      final SrsDbStore s = await device();
      final String src = await s.addField(s.lapisNoteTypeId, '来源');
      final String tr = await s.addField(s.lapisNoteTypeId, '例句翻译');
      final String withSrc = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          lapis('Expression'): '切磋琢磨',
          src: '《三月のライオン》',
          tr: 'They push each other.',
        },
      );
      final String withMisc = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          lapis('Expression'): '通う',
          lapis('MiscInfo'): 'fushi://source?x',
          src: '别的来源',
        },
      );
      expect(await s.migrateToFushiCard(<String>[withSrc, withMisc]), 2);
      final SrsNoteView a = (await s.note(withSrc))!;
      expect(a.field(fushi('MiscInfo')), '《三月のライオン》');
      expect(a.field(fushi('SentenceTranslation')), 'They push each other.');
      // 主映射有内容的不被同槽的其它字段覆盖。
      final SrsNoteView b = (await s.note(withMisc))!;
      expect(b.field(fushi('MiscInfo')), 'fushi://source?x');
    },
  );

  test(
    'imported Lapis variant: one-click migration keeps history and previews losses',
    () async {
      final SrsDbStore s = await device();
      final String id = await importedLapis(s, 'Lapis');
      SrsNoteTypeView v = await type(s, id);
      await s.renameField(id, fieldNamed(v, 'MiscInfo'), 'Source');
      final String comment = await s.addField(id, 'Comment');
      v = await type(s, id);
      final String n = await s.createNote(
        noteTypeId: id,
        fieldsById: <String, String>{
          fieldNamed(v, 'Expression'): '琢磨',
          fieldNamed(v, 'Source'): 'Book A',
          fieldNamed(v, 'PitchPosition'): '[0]',
          comment: 'my note',
        },
      );
      final String oldCard = SrsIds.card(n, v.templates.single.id, 0);
      final SrsReviewLog l1 = await s.answer(oldCard, 3);

      final List<SrsLegacyLapisSource> sources = await s.legacyLapisSources();
      expect(sources.map((SrsLegacyLapisSource x) => x.type.id), <String>[id]);
      final SrsLegacyLapisMigrationPreview p = await s
          .previewLegacyLapisMigration(id);
      expect(p.change.linkedCards, 1);
      expect(p.change.droppedCards, 0);
      expect(
        p.lostFieldNotes.map(
          (SrsFieldDef f, int c) => MapEntry<String, int>(f.name, c),
        ),
        <String, int>{'Comment': 1},
      );

      expect(await s.migrateLegacyLapis(id), 1);
      final SrsNoteView after = (await s.note(n))!;
      expect(after.noteTypeId, s.fushiCardNoteTypeId);
      expect(after.field(fushi('Expression')), '琢磨');
      expect(after.field(fushi('MiscInfo')), 'Book A');
      expect(after.field(fushi('PitchPosition')), '[0]');
      final SrsNoteTypeView fc = await type(s, s.fushiCardNoteTypeId);
      final String newCard = SrsIds.card(n, fc.templates.single.id, 0);
      expect(
        (await s.history(newCard)).all.map((SrsReviewLog l) => l.id),
        contains(l1.id),
      );
      expect(await s.legacyLapisSources(), isEmpty);
    },
  );

  test(
    'migration with a target deck moves the notes and their cards there',
    () async {
      final SrsDbStore s = await device();
      final String id = await importedLapis(s, 'Lapis');
      final SrsNoteTypeView v = await type(s, id);
      final String lapisDeck = await s.createDeck('Lapis');
      final String fushiDeck = await s.createDeck('Fushi');
      final String n = await s.createNote(
        noteTypeId: id,
        deckId: lapisDeck,
        fieldsById: <String, String>{fieldNamed(v, 'Expression'): '琢磨'},
      );
      final SrsReviewLog l1 = await s.answer(
        SrsIds.card(n, v.templates.single.id, 0),
        3,
      );

      // 不存在的牌组：整个迁移不发生。
      await expectLater(
        s.migrateLegacyLapis(id, targetDeckId: 'no-such-deck'),
        throwsArgumentError,
      );
      expect((await s.note(n))!.noteTypeId, id);

      expect(await s.migrateLegacyLapis(id, targetDeckId: fushiDeck), 1);
      final SrsNoteView after = (await s.note(n))!;
      expect(after.noteTypeId, s.fushiCardNoteTypeId);
      expect(after.deckId, fushiDeck);
      final SrsNoteTypeView fc = await type(s, s.fushiCardNoteTypeId);
      final String newCard = SrsIds.card(n, fc.templates.single.id, 0);
      expect((await s.cardRows(<String>[newCard])).single.deckId, fushiDeck);
      expect(
        (await s.history(newCard)).all.map((SrsReviewLog l) => l.id),
        contains(l1.id),
      );
    },
  );

  for (final String stage in <String>['noteType', 'backfill']) {
    test(
      'a failure after the $stage step rolls the whole migration back; retry works',
      () async {
        final SrsDbStore s = await device();
        final String id = await importedLapis(s, 'Lapis');
        final SrsNoteTypeView v = await type(s, id);
        final String lapisDeck = await s.createDeck('Lapis');
        final String fushiDeck = await s.createDeck('Fushi');
        final String n = await s.createNote(
          noteTypeId: id,
          deckId: lapisDeck,
          fieldsById: <String, String>{fieldNamed(v, 'Expression'): '琢磨'},
        );
        final String oldCard = SrsIds.card(n, v.templates.single.id, 0);
        final String fingerprint = await s.changeFingerprint();

        await expectLater(
          s.migrateLegacyLapis(
            id,
            targetDeckId: fushiDeck,
            debugOnStage: (String at) async {
              if (at == stage) throw StateError('injected at $at');
            },
          ),
          throwsStateError,
        );
        // 什么都没落库：仍是旧 Lapis、仍在原牌组、仍是迁移源。
        expect(await s.changeFingerprint(), fingerprint);
        final SrsNoteView before = (await s.note(n))!;
        expect(before.noteTypeId, id);
        expect(before.deckId, lapisDeck);
        expect((await s.cardRows(<String>[oldCard])).single.deckId, lapisDeck);
        expect(
          (await s.legacyLapisSources()).map(
            (SrsLegacyLapisSource x) => x.type.id,
          ),
          <String>[id],
        );

        // 原样重试成功。
        expect(await s.migrateLegacyLapis(id, targetDeckId: fushiDeck), 1);
        final SrsNoteView after = (await s.note(n))!;
        expect(after.noteTypeId, s.fushiCardNoteTypeId);
        expect(after.deckId, fushiDeck);
        final SrsNoteTypeView fc = await type(s, s.fushiCardNoteTypeId);
        expect(
          (await s.cardRows(<String>[
            SrsIds.card(n, fc.templates.single.id, 0),
          ])).single.deckId,
          fushiDeck,
        );
        expect(await s.legacyLapisSources(), isEmpty);
      },
    );
  }

  test('migration without a target deck leaves decks alone', () async {
    final SrsDbStore s = await device();
    final String id = await importedLapis(s, 'Lapis');
    final SrsNoteTypeView v = await type(s, id);
    final String lapisDeck = await s.createDeck('Lapis');
    final String n = await s.createNote(
      noteTypeId: id,
      deckId: lapisDeck,
      fieldsById: <String, String>{fieldNamed(v, 'Expression'): '琢磨'},
    );
    expect(await s.migrateLegacyLapis(id), 1);
    final SrsNoteTypeView fc = await type(s, s.fushiCardNoteTypeId);
    expect((await s.note(n))!.deckId, lapisDeck);
    expect(
      (await s.cardRows(<String>[
        SrsIds.card(n, fc.templates.single.id, 0),
      ])).single.deckId,
      lapisDeck,
    );
  });

  group('backfill of already-migrated notes', () {
    test(
      'fills only empty fields from the pre-migration note, idempotently',
      () async {
        final SrsDbStore s = await device();
        final String src = await s.addField(s.lapisNoteTypeId, 'SourceInfo');
        final String lost = await s.createNote(
          noteTypeId: s.lapisNoteTypeId,
          fieldsById: <String, String>{lapis('Expression'): '一', src: 'Book A'},
        );
        final String kept = await s.createNote(
          noteTypeId: s.lapisNoteTypeId,
          fieldsById: <String, String>{lapis('Expression'): '二', src: 'Book B'},
        );
        await oldStyleMigrate(s, <String>[lost, kept]);
        expect((await s.note(lost))!.field(fushi('MiscInfo')), '');
        // 迁移后用户自己写过来源：绝不覆盖。
        await s.editFields(SrsEntityKind.note, kept, <String, Object?>{
          SrsFieldKeys.noteField(fushi('MiscInfo')): 'mine',
        });

        final SrsLapisBackfillPreview p = await s.previewLapisBackfill();
        expect(p.fills.keys, <String>[lost]);
        expect(p.fieldCounts, <String, int>{fushi('MiscInfo'): 1});
        expect(await s.applyLapisBackfill(), 1);
        expect((await s.note(lost))!.field(fushi('MiscInfo')), 'Book A');
        expect((await s.note(kept))!.field(fushi('MiscInfo')), 'mine');
        expect(await s.applyLapisBackfill(), 0);
        expect((await s.previewLapisBackfill()).notes, 0);
      },
    );

    test(
      'a field the user cleared after migrating is never filled back',
      () async {
        final SrsDbStore s = await device();
        final String src = await s.addField(s.lapisNoteTypeId, 'SourceInfo');
        final String n = await s.createNote(
          noteTypeId: s.lapisNoteTypeId,
          fieldsById: <String, String>{lapis('Expression'): '四', src: 'Book D'},
        );
        await oldStyleMigrate(s, <String>[n]);
        expect(await s.applyLapisBackfill(), 1);
        expect((await s.note(n))!.field(fushi('MiscInfo')), 'Book D');

        // 用户特意清空：修改记录还在，值是空串。
        await s.editFields(SrsEntityKind.note, n, <String, Object?>{
          SrsFieldKeys.noteField(fushi('MiscInfo')): '',
        });
        expect((await s.note(n))!.field(fushi('MiscInfo')), '');
        expect((await s.previewLapisBackfill()).notes, 0);
        expect((await s.legacyLapisPendingCounts()).backfill, 0);
        expect(await s.applyLapisBackfill(), 0);
        expect((await s.note(n))!.field(fushi('MiscInfo')), '');
      },
    );

    test('works after the old note type was deleted', () async {
      final SrsDbStore s = await device();
      final String id = await importedLapis(s, 'Lapis import');
      final String extra = await s.addField(id, '出典');
      final SrsNoteTypeView v = await type(s, id);
      final String n = await s.createNote(
        noteTypeId: id,
        fieldsById: <String, String>{
          fieldNamed(v, 'Expression'): '三',
          extra: 'Show C',
        },
      );
      await oldStyleMigrate(s, <String>[n]);
      await s.deleteNoteType(id);
      expect((await s.note(n))!.deletedAt, isNull);
      expect(await s.applyLapisBackfill(), 1);
      expect((await s.note(n))!.field(fushi('MiscInfo')), 'Show C');
    });

    test('ignores notes whose history has no Lapis variant', () async {
      final SrsDbStore s = await device();
      final String basic = await s.createStockNoteType(
        SrsStockNoteType.basic,
        'Basic',
      );
      final SrsNoteTypeView b = await type(s, basic);
      final String n = await s.createNote(
        noteTypeId: basic,
        fieldsById: <String, String>{
          fieldNamed(b, 'Front'): 'word',
          fieldNamed(b, 'Back'): 'meaning',
        },
      );
      await oldStyleMigrate(s, <String>[n]);
      expect((await s.previewLapisBackfill()).notes, 0);
      final ({int migratable, int backfill}) c = await s
          .legacyLapisPendingCounts();
      expect(c.migratable, 0);
      expect(c.backfill, 0);
    });
  });

  group('Lapis deck rename', () {
    test('name mapping: whole word, case-insensitive, null without lapis', () {
      expect(srsLapisDeckRenamed('Lapis'), 'Fushi Card');
      expect(srsLapisDeckRenamed('lapis mining'), 'Fushi Card mining');
      expect(srsLapisDeckRenamed('日语 LAPIS'), '日语 Fushi Card');
      // 只是含这几个字母的名字不动（按子串替换会改成「Fushi Cardlazuli」）。
      expect(srsLapisDeckRenamed('Lapislazuli'), isNull);
      expect(srsLapisDeckRenamed('Mining'), isNull);
    });

    test(
      'renames own level only, skips sibling collisions, idempotent',
      () async {
        final SrsDbStore s = await device();
        final String lapisTop = await s.createDeck('Lapis');
        final String child = await s.createDeck('lapis', parentId: lapisTop);
        final String plain = await s.createDeck('Words', parentId: lapisTop);
        final String lazuli = await s.createDeck('Lapislazuli');
        final String mining = await s.createDeck('Lapis Mining');
        final String miningTarget = await s.createDeck('Fushi Card Mining');
        // 「Old::Lapis」改名会撞同级已有的「Old::Fushi Card」：保持原名。
        final String old = await s.createDeck('Old');
        final String clash = await s.createDeck('Fushi Card', parentId: old);
        final String clashSrc = await s.createDeck('Lapis', parentId: old);
        expect(await s.renameLapisDecks(), 2);
        final SrsDeckTree tree = await s.deckTree();
        expect(tree.fullName(lapisTop), 'Fushi Card');
        expect(tree.fullName(child), 'Fushi Card::Fushi Card');
        expect(tree.fullName(plain), 'Fushi Card::Words');
        expect(tree.fullName(lazuli), 'Lapislazuli');
        // 「Lapis Mining」改名会撞同级已有的「Fushi Card Mining」：保持原名。
        expect(tree.fullName(mining), 'Lapis Mining');
        expect(tree.fullName(miningTarget), 'Fushi Card Mining');
        expect(tree.fullName(clash), 'Old::Fushi Card');
        expect(tree.fullName(clashSrc), 'Old::Lapis');
        expect(await s.renameLapisDecks(), 0);
      },
    );
  });
}
