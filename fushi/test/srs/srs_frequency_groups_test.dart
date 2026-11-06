// 词频明细按词典合并：`<li>词典: 值</li>` 同词典多值合成一项。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart';

void main() {
  test('同词典两个值合并成一项', () {
    expect(
      srsFrequencyGroups('<ul><li>JPDB: 100</li><li>JPDB: 2000</li></ul>'),
      <String>['JPDB: 100, 2000'],
    );
  });

  test('三本词典保持首次出现的顺序', () {
    expect(
      srsFrequencyGroups(
        '<li>B: 1</li><li>A: 2</li><li>B: 3</li><li>C: 4</li><li>A: 5</li>',
      ),
      <String>['B: 1, 3', 'A: 2, 5', 'C: 4'],
    );
  });

  test('词典名带冒号：按最后一个 ": " 切', () {
    expect(srsFrequencyGroups('<li>A: B: 1234</li>'), <String>['A: B: 1234']);
    expect(srsFrequencyGroups('<li>A: B: 1</li><li>A: B: 2</li>'), <String>[
      'A: B: 1, 2',
    ]);
  });

  test('重复值去重', () {
    expect(
      srsFrequencyGroups('<li>X: 7</li><li>X: 7</li><li>X: 8</li>'),
      <String>['X: 7, 8'],
    );
  });

  test('没有 <li> 时按行切', () {
    expect(srsFrequencyGroups('JPDB: 1\nJPDB: 2\nBCCWJ: 3'), <String>[
      'JPDB: 1, 2',
      'BCCWJ: 3',
    ]);
  });

  test('切不出词典名的项原样单列、不被合并', () {
    expect(
      srsFrequencyGroups('<li>1234</li><li>1234</li><li>X: 5</li>'),
      <String>['1234', '1234', 'X: 5'],
    );
    expect(srsFrequencyGroups(''), isEmpty);
  });
}
