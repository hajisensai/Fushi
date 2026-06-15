import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show floatingLyricSearchTerm;

/// TODO-376：桌面悬浮字幕条点词时，[floatingLyricSearchTerm] 从整句 + 点击字符
/// 索引解析出真正要查的词，再交给剪贴板查词出口（DesktopLookupService）。
///
/// 这里只钉纯函数的分词器优先 / 整句回退 / 双空 no-op 契约——分词本身由
/// JapaneseLanguage.wordFromIndex 负责（见 popup_floating_lyric_charindex_test）。
void main() {
  group('floatingLyricSearchTerm', () {
    test('分词器切出词时优先用词（去空白）', () {
      expect(
        floatingLyricSearchTerm(text: '今日は良い天気', index: 3, word: '  良い '),
        '良い',
      );
    });

    test('分词器切不出（空 / 纯空白）时回退整句（去空白）', () {
      expect(
        floatingLyricSearchTerm(text: '  今日は良い天気  ', index: 0, word: ''),
        '今日は良い天気',
      );
      expect(
        floatingLyricSearchTerm(text: '今日は', index: 0, word: '   '),
        '今日は',
      );
    });

    test('词与整句皆空 → 空串（调用方据此 no-op，不发起查词）', () {
      expect(floatingLyricSearchTerm(text: '   ', index: 0, word: ''), isEmpty);
      expect(floatingLyricSearchTerm(text: '', index: 0, word: ''), isEmpty);
    });
  });
}
