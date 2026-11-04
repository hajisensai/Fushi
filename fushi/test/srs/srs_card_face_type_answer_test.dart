// DAgSPc8ixN：Anki 打字输入答案在 WebView 卡面上的接线——外壳页装好输入框脚本与样式，
// 答案面只用这张卡问题面打的字填比对结果。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

void main() {
  SrsCardFace face(
    String cardId, {
    required bool answer,
    required String body,
  }) => SrsCardFace(
    cardId: cardId,
    showingAnswer: answer,
    bodyHtml: body,
    css: '',
    languageCode: null,
    onBridgeKey: (String _) {},
  );

  final ({String question, String answer}) faces = ankiResolveTypeAnswer(
    question: '猫 [[type:Back]]',
    answer: '猫<hr id=answer>[[type:Back]]',
    fields: const <String, String>{'Back': 'ねこ'},
    cardOrd: 0,
  );

  test('外壳页装好打字框脚本（回调名）与 Anki 同名类的样式', () {
    final String shell = srsCardShellHtml(themeCss: '', classes: '');
    expect(shell, contains(kSrsTypeAnswerScript));
    expect(shell, contains(kSrsTypeAnswerHandler));
    expect(shell, contains('.typeGood{'));
    expect(shell, contains('.typeMissed{'));
  });

  test('答案面：本卡打的字填成比对结果', () {
    final SrsCardFace out = srsFaceWithTypedAnswer(
      face('c1', answer: true, body: faces.answer),
      (cardId: 'c1', text: 'ねず'),
    );
    expect(ankiHasTypeAnswerSlot(out.bodyHtml), isFalse);
    expect(out.bodyHtml, contains('<span class="typeBad">ず</span>'));
    expect(out.bodyHtml, contains('<span class="typeMissed">こ</span>'));
    expect(out.cardId, 'c1');
    expect(out.showingAnswer, isTrue);
  });

  test('别的卡打的字不串到这张卡：按没打字只显示期望答案', () {
    final SrsCardFace out = srsFaceWithTypedAnswer(
      face('c2', answer: true, body: faces.answer),
      (cardId: 'c1', text: 'ねこ'),
    );
    expect(
      out.bodyHtml,
      contains('<code id="typeans" class="fushi-typeans-result">ねこ</code>'),
    );
    expect(out.bodyHtml, isNot(contains('typeGood')));
  });

  test('问题面原样（输入框留着）', () {
    final SrsCardFace q = face('c1', answer: false, body: faces.question);
    expect(
      identical(srsFaceWithTypedAnswer(q, (cardId: 'c1', text: 'x')), q),
      isTrue,
    );
    expect(q.bodyHtml, contains('<input type="text" id="typeans"'));
  });
}
