import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_builtin_template_restore.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000001';

/// 「恢复内置模板」：内置 Fushi 卡片的模板 / CSS 被改过（回滚笔记带回旧版）后原生卡面停用；恢复写回代码定义，
/// 原生卡面回来；撤销把改过的值放回去。
void main() {
  int t = DateTime.utc(2026, 11, 2, 12).millisecondsSinceEpoch;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> device(String id) =>
      openTestStore(profileUid: kProfile, deviceId: id, now: () => t++);

  Future<SrsRenderedCard> render(SrsDbStore s) async {
    final String note = await s.createNote(
      noteTypeId: s.fushiCardNoteTypeId,
      fieldsById: <String, String>{
        srsFushiCardFieldId(kProfile, 'Expression'): '通う',
        srsFushiCardFieldId(kProfile, 'MainDefinition'):
            '<ol><li>to commute</li></ol>',
      },
    );
    final SrsCardCacheRow card = (await s.cardsOfNote(note)).first;
    return (await s.renderCard(card.id))!;
  }

  test('restore brings back native rendering and can be undone', () async {
    final SrsDbStore a = await device('a');
    final String nt = a.fushiCardNoteTypeId;
    SrsNoteTypeView type = (await a.noteType(nt))!;
    expect(a.builtinTemplatesModified(type), isFalse);
    expect(await a.restoreBuiltinTemplates(nt), isNull, reason: '一致时不写');

    // 模拟回滚带回的旧模板：改 CSS 与背面。
    final SrsTemplateDef tpl = type.templates.single;
    const String oldCss = '.card { max-width: 480px; }';
    await a.saveTemplateEdits(
      nt,
      tpl.id,
      back: '${tpl.back}<div>old</div>',
      css: oldCss,
    );
    type = (await a.noteType(nt))!;
    expect(a.builtinTemplatesModified(type), isTrue);
    expect((await render(a)).fushiCardDefinitions, isNull);

    final SrsBuiltinTemplateRestore? restore = await a.restoreBuiltinTemplates(
      nt,
    );
    expect(restore, isNotNull);
    type = (await a.noteType(nt))!;
    expect(a.builtinTemplatesModified(type), isFalse);
    expect(type.css, FushiCardNoteType.template.css);
    expect(
      type.templates.single.back,
      srsBuiltinFushiCard(kProfile).templates.single.back,
    );
    expect(type.templates.single.name, tpl.name);
    expect((await render(a)).fushiCardDefinitions, contains('to commute'));

    await a.undoBuiltinTemplateRestore(restore!);
    type = (await a.noteType(nt))!;
    expect(type.css, oldCss);
    expect(type.templates.single.back, '${tpl.back}<div>old</div>');
    expect((await render(a)).fushiCardDefinitions, isNull);
  });

  test(
    'user-added templates are left alone; non-builtin types are rejected',
    () async {
      final SrsDbStore a = await device('b');
      final String nt = a.lapisNoteTypeId;
      final String extra = await a.addTemplate(
        nt,
        name: 'Extra',
        front: 'x',
        back: 'y',
      );
      await a.setCss(nt, '.changed{}');
      expect(await a.restoreBuiltinTemplates(nt), isNotNull);
      final SrsNoteTypeView type = (await a.noteType(nt))!;
      expect(type.css, LapisNoteType.template.css);
      final SrsTemplateDef kept = type.templates.firstWhere(
        (SrsTemplateDef x) => x.id == extra,
      );
      expect(kept.front, 'x');

      final String custom = await a.createStockNoteType(
        SrsStockNoteType.basic,
        'Custom',
      );
      await expectLater(
        a.restoreBuiltinTemplates(custom),
        throwsA(isA<ArgumentError>()),
      );
    },
  );
}
