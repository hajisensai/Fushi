import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audio_text_normalizer.dart';

void main() {
  group('AudioTextNormalizer.normalize', () {
    test('preserves hiragana', () {
      expect(AudioTextNormalizer.normalize('あいうえお'), 'あいうえお');
    });

    test('preserves katakana', () {
      expect(AudioTextNormalizer.normalize('アイウエオ'), 'アイウエオ');
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

    test('lowercases fullwidth uppercase', () {
      expect(AudioTextNormalizer.normalize('ＡＢＣ'), 'ａｂｃ');
    });

    test('preserves digits', () {
      expect(AudioTextNormalizer.normalize('123'), '123');
    });

    test('preserves fullwidth digits', () {
      expect(AudioTextNormalizer.normalize('０１２'), '０１２');
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

    test('preserves halfwidth katakana', () {
      expect(AudioTextNormalizer.normalize('ｱｲｳ'), 'ｱｲｳ');
    });

    test('preserves 々 repetition mark', () {
      expect(AudioTextNormalizer.normalize('人々'), '人々');
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
