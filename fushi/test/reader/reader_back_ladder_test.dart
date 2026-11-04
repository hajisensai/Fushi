import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_back_ladder.dart';

/// 阅读器返回阶梯：Esc / 手柄 B 与系统返回同一条——歌词模式下也直接退书
/// （NJIIDAhIZL / NaFaJbaAdc），只有词典弹窗先关。
void main() {
  test('无浮层时退书（歌词模式下也一样，阶梯不看歌词层）', () {
    expect(
      resolveReaderBackStep(dictionaryShown: false),
      ReaderBackStep.exitBook,
    );
  });

  test('词典弹窗开着先关弹窗', () {
    expect(
      resolveReaderBackStep(dictionaryShown: true),
      ReaderBackStep.closeDictionary,
    );
  });

  test('显式退书在途时跳过整条阶梯', () {
    expect(
      resolveReaderBackStep(dictionaryShown: true, explicitExit: true),
      ReaderBackStep.exitBook,
    );
  });
}
