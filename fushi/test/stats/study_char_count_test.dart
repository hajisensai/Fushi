import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/stats/study_char_count.dart';

/// 学习统计字数口径 [countStudyChars] 的行为锁定。
///
/// 口径见 `study_char_count.dart` 库注释：CJK / 假名 / 谚文等无空格文字按码点计 1，
/// 空格分词文字的连续字母数字串计 1，组合记号与词内撇号透明，标点空白符号不计。
void main() {
  group('无空格文字按码点计', () {
    test('日文假名与汉字', () {
      expect(countStudyChars('素晴らしい世界'), 7);
      expect(countStudyChars('コーヒー'), 4, reason: '长音符 ー 计入（Script Ext 归假名）');
      expect(countStudyChars('人々'), 2, reason: '迭代符 々 计入（Script Ext 归汉字）');
      expect(countStudyChars('ｶﾀｶﾅ'), 4, reason: '半角片假名计入');
    });

    test('中文与增补面汉字', () {
      expect(countStudyChars('你好世界'), 4);
      expect(countStudyChars('\u{20BB7}野家'), 3, reason: '按码点计，代理对不双计');
    });

    test('谚文按码点计（沿用 galgame 既有口径）', () {
      expect(countStudyChars('안녕하세요'), 5);
    });

    test('泰文按码点计', () {
      expect(countStudyChars('สวัสดี'), 4,
          reason: '6 个码点里 ั 与 ี 是组合记号（透明），计入的是 4 个辅音字母；'
              '泰文不用空格分词，按码点计的是字母而非音节');
    });
  });

  group('空格分词文字按词计', () {
    test('英语', () {
      expect(countStudyChars('I do not know'), 4);
      expect(countStudyChars('Hello, world!'), 2);
    });

    test('词内撇号不拆词', () {
      expect(countStudyChars("I don't know"), 3);
      expect(countStudyChars('I don\u2019t know'), 3,
          reason: '排版撇号 U+2019 同样透明');
      expect(countStudyChars("John's book"), 2);
      expect(countStudyChars("rock 'n' roll"), 3, reason: '断词靠空白，不靠撇号；n 自成一词');
    });

    test('带变音的拉丁字母整词计 1（旧口径漏计变音字母）', () {
      expect(countStudyChars('café'), 1);
      expect(countStudyChars('Grüße über Straße'), 3);
    });

    test('西里尔 / 希腊 / 阿拉伯 / 希伯来 / 天城文（旧口径整脚本计 0）', () {
      expect(countStudyChars('Привет мир'), 2);
      expect(countStudyChars('Καλημέρα κόσμε'), 2);
      expect(countStudyChars('\u0645\u0631\u062D\u0628\u0627 \u0628\u0643'), 2);
      expect(
          countStudyChars('\u05E9\u05DC\u05D5\u05DD \u05E2\u05D5\u05DC\u05DD'),
          2);
      expect(
          countStudyChars(
              '\u0928\u092E\u0938\u094D\u0924\u0947 \u0926\u0941\u0928\u093F\u092F\u093E'),
          2,
          reason: '天城文用空格分词，matra 是组合记号（透明）');
    });

    test('阿拉伯语的 harakat 不拆词', () {
      expect(countStudyChars('\u0643\u0650\u062A\u064E\u0627\u0628'), 1,
          reason: r'词中的 harakat 是 \p{M}，透明不断词');
    });

    test('数字连续串计 1', () {
      expect(countStudyChars('2026'), 1);
      expect(countStudyChars('I read 300 pages'), 4);
    });
  });

  group('不计入的字符', () {
    test('标点 / 括号 / 空白', () {
      expect(countStudyChars('（）【】「」『』、。！？\u3000'), 0);
      expect(countStudyChars('！？…—'), 0);
      expect(countStudyChars(''), 0);
      expect(countStudyChars('   \n\t'), 0);
    });

    test('判定顺序：先脚本后类别', () {
      expect(countStudyChars('\u3007'), 1,
          reason: r'〇 是 \p{N} 但 Script Ext 是 Han，必须按码点计 1 而不是并进词串');
      expect(countStudyChars('\u3002'), 0,
          reason: r'。的 Script Ext 含 Han，但既非 \p{L} 也非 \p{N}，不得计入');
      expect(countStudyChars('\u30071\u30072'), 4, reason: '〇 逐个计，中间的西文数字各自成串');
    });
  });

  group('混排', () {
    test('日文正文里的西文按词计，不再逐字母', () {
      // これは = こ れ は = 3；Hello = 1；World = 1；です = で す = 2
      expect(countStudyChars('これは Hello World です'), 3 + 1 + 1 + 2);
    });
  });
}
