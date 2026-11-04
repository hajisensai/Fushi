import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_back_ladder.dart';

/// 阅读器返回阶梯：Esc（globalBack）与系统返回同一条——词典弹窗先关，其余一律退书；
/// 歌词模式不是一级（系统返回 NJIIDAhIZL，Esc BUG-4005）。
void main() {
  test('词典弹窗开着先关弹窗', () {
    expect(
      resolveReaderBackStep(dictionaryShown: true),
      ReaderBackStep.closeDictionary,
    );
  });

  test('无浮层时退书（歌词模式下也是：一次就回书架，不先掀开歌词层）', () {
    expect(
      resolveReaderBackStep(dictionaryShown: false),
      ReaderBackStep.exitBook,
    );
  });

  test('阶梯只有「关词典」与「退书」两步', () {
    expect(ReaderBackStep.values, <ReaderBackStep>[
      ReaderBackStep.closeDictionary,
      ReaderBackStep.exitBook,
    ]);
  });

  test('显式退书在途时跳过整条阶梯', () {
    expect(
      resolveReaderBackStep(dictionaryShown: true, explicitExit: true),
      ReaderBackStep.exitBook,
    );
  });
}
