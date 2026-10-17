import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_mining.dart';

/// 自建笔记类型设为挖词目标时，字段按名字预填制卡内容槽（截图巡检：此前只认与
/// Lapis 完全同名的字段，「Front / Back」「正面 / 背面」类型全是「未映射」）。
void main() {
  test('Lapis 同名字段（大小写 / 分隔符不敏感）沿用 Lapis 默认', () {
    expect(srsGuessFieldMapping('Expression'), '{expression}');
    expect(srsGuessFieldMapping('expression_reading'), '{reading}');
    expect(srsGuessFieldMapping('Sentence Audio'), '{sentence-audio}');
    expect(srsGuessFieldMapping('MainDefinition'), '{glossary-first}');
  });

  test('常见同义名（英 / 中 / 日）对到制卡内容槽', () {
    expect(srsGuessFieldMapping('Front'), '{expression}');
    expect(srsGuessFieldMapping('Back'), '{glossary-first}');
    expect(srsGuessFieldMapping('Word'), '{expression}');
    expect(srsGuessFieldMapping('Meaning'), '{glossary-first}');
    expect(srsGuessFieldMapping('正面'), '{expression}');
    expect(srsGuessFieldMapping('背面'), '{glossary-first}');
    expect(srsGuessFieldMapping('单词'), '{expression}');
    expect(srsGuessFieldMapping('读音'), '{reading}');
    expect(srsGuessFieldMapping('例句'), '{sentence}');
    expect(srsGuessFieldMapping('読み'), '{reading}');
    expect(srsGuessFieldMapping('意味'), '{glossary-first}');
    expect(srsGuessFieldMapping('Picture'), '{card-image}');
  });

  test('拿不准的名字不猜', () {
    expect(srsGuessFieldMapping('Notes'), isNull);
    expect(srsGuessFieldMapping('Extra'), isNull);
    expect(srsGuessFieldMapping(''), isNull);
  });
}
