import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/ocr_block_sentence.dart';

/// BUG-3487：截屏识字制卡句子从 OCR text block 里截整句。块全文是原生侧把块内
/// 各行按 `\n` 拼起来的，换行只是排版折行、不是句界。
void main() {
  int indexOf(String block, String needle) {
    final int i = block.indexOf(needle);
    expect(i, greaterThanOrEqualTo(0), reason: '测试数据里找不到「$needle」');
    return i;
  }

  test('vertical text split into columns is joined back into one sentence', () {
    // 竖排一列一行：ML Kit 把一句拆成四行。
    const String block = '吾輩は\n猫である。\n名前は\nまだ無い。';
    expect(ocrBlockSentenceAt(block, indexOf(block, '猫')), '吾輩は猫である。');
    expect(ocrBlockSentenceAt(block, indexOf(block, '名')), '名前はまだ無い。');
    expect(ocrBlockSentenceAt(block, indexOf(block, '無')), '名前はまだ無い。');
  });

  test('a sentence wrapped across lines is not cut at the line break', () {
    const String block = '今日は良い天気なので、公園に\n散歩に行きました。';
    const String whole = '今日は良い天気なので、公園に散歩に行きました。';
    expect(ocrBlockSentenceAt(block, indexOf(block, '天')), whole);
    expect(ocrBlockSentenceAt(block, indexOf(block, '散')), whole);
  });

  test('a block holding several sentences yields only the tapped one', () {
    const String block = 'これは本です！あれはペンですか？それは鉛筆です。';
    expect(ocrBlockSentenceAt(block, indexOf(block, '本')), 'これは本です！');
    expect(ocrBlockSentenceAt(block, indexOf(block, 'ペ')), 'あれはペンですか？');
    expect(ocrBlockSentenceAt(block, indexOf(block, '鉛')), 'それは鉛筆です。');
    // 点在句末标点上：归它结束的那一句。
    expect(ocrBlockSentenceAt(block, indexOf(block, '？')), 'あれはペンですか？');
  });

  test('closing quotes after the terminator stay with their sentence', () {
    const String block = '「行くぞ。」\n彼はそう言った。';
    expect(ocrBlockSentenceAt(block, indexOf(block, '行')), '「行くぞ。」');
    expect(ocrBlockSentenceAt(block, indexOf(block, '彼')), '彼はそう言った。');
  });

  test('back-to-back dialogue brackets split without a full stop', () {
    const String block = '「おはよう」\n「元気？」';
    expect(ocrBlockSentenceAt(block, indexOf(block, 'お')), '「おはよう」');
    expect(ocrBlockSentenceAt(block, indexOf(block, '元')), '「元気？」');
  });

  test('a quote followed by narration is one sentence', () {
    const String block = '「行くぞ」と\n彼は言った。';
    expect(ocrBlockSentenceAt(block, indexOf(block, '彼')), '「行くぞ」と彼は言った。');
  });

  test('ellipsis is not a sentence boundary', () {
    const String block = 'あの……実は\n話があるんだ。';
    expect(ocrBlockSentenceAt(block, indexOf(block, '話')), 'あの……実は話があるんだ。');
  });

  test('missing punctuation keeps the whole (short) block', () {
    const String block = 'もう一度\nやり直そう';
    expect(ocrBlockSentenceAt(block, indexOf(block, 'や')), 'もう一度やり直そう');
  });

  test('an over-long unpunctuated block falls back (null)', () {
    final String block = List<String>.filled(40, '設定項目です').join('\n');
    expect(ocrBlockSentenceAt(block, 3), isNull);
    // 上限可调：同一块在宽上限下照样整块返回。
    expect(ocrBlockSentenceAt(block, 3, maxLength: 1000), isNotNull);
  });

  test('English: wrapped lines get a space, periods split sentences', () {
    const String block = 'The quick brown\nfox jumps. It was 3.5 metres\nhigh!';
    expect(
      ocrBlockSentenceAt(block, indexOf(block, 'fox')),
      'The quick brown fox jumps.',
    );
    expect(
      ocrBlockSentenceAt(block, indexOf(block, 'metres')),
      'It was 3.5 metres high!',
    );
  });

  test('Chinese punctuation splits sentences', () {
    const String block = '今天天气很好。我们去\n公园散步吧！';
    expect(ocrBlockSentenceAt(block, indexOf(block, '公')), '我们去公园散步吧！');
  });

  test('out-of-range index and empty block return null', () {
    expect(ocrBlockSentenceAt('', 0), isNull);
    expect(ocrBlockSentenceAt('あいう', -1), isNull);
    expect(ocrBlockSentenceAt('あいう', 3), isNull);
  });
}
