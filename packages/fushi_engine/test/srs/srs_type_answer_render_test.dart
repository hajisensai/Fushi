// DAgSPc8ixN：Anki「问答（打字输入答案）」类型迁进内置复习后，问题面要有输入框、答案面要有
// 比对占位（以前 `{{type:…}}` 渲染成空串，卡看起来跟基础卡一样）。走真实 SrsDbStore.renderCard。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsFieldDef, SrsNoteTypeView;
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show openTestStore;

/// 名字写的模板 → fieldId 引用（与编辑器保存时同一个函数）。
String templateNamesToIdsFor(SrsNoteTypeView v, String tpl) =>
    templateNamesToIds(tpl, <String, String>{
      for (final SrsFieldDef f in v.fields) f.name: f.id,
    });

const String kProfile = '01928c3e-0000-7000-8000-000000000001';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('打字输入答案：问题面一个输入框，答案面带期望答案的比对占位，填字后出比对', () async {
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => DateTime.utc(2026, 11, 4, 12).millisecondsSinceEpoch,
    );
    final String nt = await s.createStockNoteType(
      SrsStockNoteType.basic,
      '问答（打字）',
    );
    final SrsNoteTypeView v = (await s.noteType(nt))!;
    final String tpl = await s.addTemplate(
      nt,
      name: 'Typing',
      front: templateNamesToIdsFor(v, '{{Front}}<br>{{type:Back}}'),
      back: templateNamesToIdsFor(v, '{{Front}}<hr id=answer>{{type:Back}}'),
    );
    final String note = await s.createNote(
      noteTypeId: nt,
      fieldsById: <String, String>{
        v.fields[0].id: '猫',
        v.fields[1].id: '<b>ねこ</b>[sound:neko.mp3]',
      },
    );
    final SrsCardCacheRow card = (await s.cardsOfNote(
      note,
    )).firstWhere((SrsCardCacheRow c) => c.templateId == tpl);
    final SrsRenderedCard r = (await s.renderCard(card.id))!;

    expect(r.question, contains('<input type="text" id="typeans"'));
    expect(r.question, isNot(contains('[[type:')));
    expect(r.answer, isNot(contains('[[type:')));
    expect(ankiHasTypeAnswerSlot(r.answer), isTrue);
    expect(r.answer, contains('data-expected="ねこ"'));

    expect(
      ankiFillTypeAnswer(r.answer, 'ねこ'),
      contains(
        '<code id="typeans" class="fushi-typeans-result">'
        '<span class="typeGood">ねこ</span></code>',
      ),
    );
    final String wrong = ankiFillTypeAnswer(r.answer, 'ねず');
    expect(wrong, contains('<span class="typeBad">ず</span>'));
    expect(wrong, contains('<span class="typeMissed">こ</span>'));
  });
}
