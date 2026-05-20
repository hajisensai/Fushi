import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  group('AudioTextNormalizer.normalize', () {
    test('preserves hiragana', () {
      expect(AudioTextNormalizer.normalize('あいうえお'), 'あいうえお');
    });

    test('converts katakana to hiragana', () {
      expect(AudioTextNormalizer.normalize('アイウエオ'), 'あいうえお');
    });

    test('preserves kanji', () {
      expect(AudioTextNormalizer.normalize('漢字'), '漢字');
    });

    test('strips punctuation', () {
      expect(AudioTextNormalizer.normalize('吾輩は、猫である。'), '吾輩は猫である');
    });

    test('strips spaces', () {
      expect(AudioTextNormalizer.normalize('hello world'), 'helloworld');
    });

    test('lowercases ASCII uppercase', () {
      expect(AudioTextNormalizer.normalize('ABC'), 'abc');
    });

    test('lowercases fullwidth uppercase to ASCII', () {
      expect(AudioTextNormalizer.normalize('ＡＢＣ'), 'abc');
    });

    test('preserves digits', () {
      expect(AudioTextNormalizer.normalize('123'), '123');
    });

    test('converts fullwidth digits to ASCII', () {
      expect(AudioTextNormalizer.normalize('０１２'), '012');
    });

    test('strips emoji and special symbols', () {
      expect(AudioTextNormalizer.normalize('猫🐱です！'), '猫です');
    });

    test('empty string returns empty', () {
      expect(AudioTextNormalizer.normalize(''), '');
    });

    test('mixed content keeps only whitelisted chars', () {
      expect(
        AudioTextNormalizer.normalize('第1話「開始」'),
        '第1話開始',
      );
    });

    test('converts halfwidth katakana to hiragana', () {
      expect(AudioTextNormalizer.normalize('ｱｲｳ'), 'あいう');
    });

    test('preserves 々 repetition mark', () {
      expect(AudioTextNormalizer.normalize('人々'), '人々');
    });

    test('fullwidth lowercase letters map to ASCII', () {
      expect(AudioTextNormalizer.normalize('ａｂｃ'), 'abc');
    });

    test('mixed ASCII and fullwidth normalize to same form', () {
      expect(
        AudioTextNormalizer.normalize('Helloｗorld'),
        AudioTextNormalizer.normalize('Ｈｅｌｌｏworld'),
      );
    });

    test('fullwidth and ASCII digits normalize to same form', () {
      expect(
        AudioTextNormalizer.normalize('第１話'),
        AudioTextNormalizer.normalize('第1話'),
      );
    });

    test('halfwidth katakana with fullwidth equivalent match', () {
      expect(
        AudioTextNormalizer.normalize('ｶﾀｶﾅ'),
        AudioTextNormalizer.normalize('カタカナ'),
      );
    });

    test('katakana and hiragana normalize to same form', () {
      expect(
        AudioTextNormalizer.normalize('カタカナ'),
        AudioTextNormalizer.normalize('かたかな'),
      );
    });

    test('mixed katakana/hiragana normalizes to hiragana', () {
      expect(
        AudioTextNormalizer.normalize('カタかな'),
        'かたかな',
      );
    });

    test('chōon mark ー preserved (no hiragana equivalent)', () {
      expect(AudioTextNormalizer.normalize('コーヒー'), 'こーひー');
    });

    test('halfwidth katakana chains through to hiragana', () {
      expect(AudioTextNormalizer.normalize('ｶﾀｶﾅ'), 'かたかな');
    });
  });

  group('AudioTextNormalizer.appendNormalized', () {
    test('appends to existing buffer content', () {
      final buf = StringBuffer('prefix');
      AudioTextNormalizer.appendNormalized(buf, '漢字');
      expect(buf.toString(), 'prefix漢字');
    });

    test('multiple appends concatenate correctly', () {
      final buf = StringBuffer();
      AudioTextNormalizer.appendNormalized(buf, '第一章');
      AudioTextNormalizer.appendNormalized(buf, '：');
      AudioTextNormalizer.appendNormalized(buf, '開始');
      expect(buf.toString(), '第一章開始');
    });
  });
}
