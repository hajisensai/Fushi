import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';

/// TODO-1192：锁定「实义字符计数」口径（逐区间对齐 hoshi/ttu getCharacterCount
/// 使用的 `isNotJapaneseRegex`）。
///
/// 统计字数 / 书的总字数曾用 `chapterPlainText().length`，把标点、括号（「」『』
/// （）等）、全/半角空白、全角标点都算进去，比 hoshi 高约 10~20%（v1）。第一版
/// [japaneseCharCount]（v2）改成只数假名/汉字/字母数字，但 whitelist 与 ttu 正则
/// 有残差：多数了片假名叠字 ヽヾヿ、半角浊点 ﾞﾟ、整块 CJK 兼容汉字，少数了全角
/// 字母数字与 CJK 部首，同一本书仍比 hoshi 高上百字。v3 把 whitelist 逐区间对齐
/// ttu：
/// ```
/// /[^0-9A-Z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚｦ-ﾝ\p{Radical}\p{Unified_Ideograph}]+/gimu
/// ```
/// 撤销任一对齐即转红。
EpubBook _bookWithHtml(String html) {
  return EpubBook(
    title: 'test',
    chapters: <EpubChapter>[
      EpubChapter(
        id: 'ch1',
        href: 'ch1.xhtml',
        mediaType: 'application/xhtml+xml',
        html: html,
      ),
    ],
  );
}

void main() {
  group('japaneseCharCount', () {
    test('剔除标点/括号/空白，只数假名与汉字', () {
      const String s = '「こんにちは、世界。」';
      // 実義字符：こんにちは(5) + 世界(2) = 7；「」、。 全部剔除。
      expect(japaneseCharCount(s), 7);
      // 严格小于原始长度（含标点/括号）——即比旧口径低。
      expect(japaneseCharCount(s), lessThan(s.length));
    });

    test('全角标点 / 括号 / 全角空白一律不计', () {
      expect(japaneseCharCount('（）【】「」『』、。！？　'), 0);
    });

    test('半角字母数字计入（含小写）', () {
      // A B C 1 2 3 d e f = 9；空格与 ! 剔除。
      expect(japaneseCharCount('ABC123 def!'), 9);
    });

    test('全角字母数字计入（含小写；对齐 ttu ０-９Ａ-Ｚ + i flag）', () {
      // ＡＢＣ１２３ｄｅｆ = 9；全角空白与全角！剔除。
      expect(japaneseCharCount('ＡＢＣ１２３ｄｅｆ　！'), 9);
    });

    test('叠字/重复符号计入（々〆〇〻 ゝゞ ー）', () {
      expect(japaneseCharCount('人々'), 2); // 人 + 々
      expect(japaneseCharCount('コーヒー'), 4); // コ ー ヒ ー（长音符 U+30FC 计）
      expect(japaneseCharCount('〆〇〻'), 3); // 3005-3007 区间末 + 〻(303B)
      expect(japaneseCharCount('ゝゞ'), 2); // 平假名叠字 309D-309E
    });

    test('片假名叠字 ヽ ヾ ヿ 与半角浊点 ﾞ ﾟ 不计（ttu 白名单到 ー / ﾝ 为止）', () {
      // v2 残差：这些曾被误计，使同一本书比 hoshi 偏高。
      expect(japaneseCharCount('ヽ'), 0); // ヽ 片假名重复符
      expect(japaneseCharCount('ヾ'), 0); // ヾ 片假名浊音重复符
      expect(japaneseCharCount('ヿ'), 0); // ヿ 片假名 koto 合字
      expect(japaneseCharCount('ﾞ'), 0); // ﾞ 半角浊点
      expect(japaneseCharCount('ﾟ'), 0); // ﾟ 半角半浊点
      // ー(30FC) 与 ｦ-ﾝ(FF66-FF9D) 仍计入，边界不误伤。
      expect(japaneseCharCount('ー'), 1); // ー
      expect(japaneseCharCount('ﾝ'), 1); // ﾝ
    });

    test('半角片假名计入', () {
      expect(japaneseCharCount('ｶﾀｶﾅ'), 4);
    });

    test('CJK 部首计入（对齐 ttu \\p{Radical}）', () {
      expect(japaneseCharCount('⼀'), 1); // ⼀ 康熙部首「一」(2F00)
      expect(japaneseCharCount('⺀'), 1); // ⺀ 部首补充首码点 (2E80)
    });

    test('CJK 兼容汉字：只计 12 个被归为统一表意的码点，其余不计', () {
      expect(japaneseCharCount('﨎'), 1); // FA0E 属 Unified_Ideograph -> 计
      expect(japaneseCharCount('塚'), 0); // FA10 兼容字不属统一表意 -> 剔除
      expect(japaneseCharCount('豈'), 0); // F900 兼容块首 -> 剔除
    });

    test('BMP 外扩展B汉字（代理对）按码点计一字，不重复计', () {
      const String s = '𠮷野家'; // 𠮷 = U+20BB7（代理对，占 2 个 UTF-16 码元）
      expect(s.length, 4, reason: 'UTF-16 长度：代理对 2 + 野 + 家 = 4');
      expect(japaneseCharCount(s), 3, reason: '按码点计：𠮷 野 家 = 3');
    });

    test('CJK 兼容表意补充块（2F800-2FA1D）不计（非 Unified_Ideograph）', () {
      expect(japaneseCharCount('\u{2F800}'), 0);
      expect(japaneseCharCount('\u{2FA1D}'), 0);
    });

    test('空串 / 纯符号 → 0', () {
      expect(japaneseCharCount(''), 0);
      expect(japaneseCharCount('！？…—'), 0);
    });
  });

  group('EpubBook.chapterCharacterCount', () {
    test('振假名（rt）不计入，标点不计入', () {
      final EpubBook book = _bookWithHtml(
        '<p><ruby>漢<rt>かん</rt></ruby><ruby>字<rt>じ</rt></ruby>を読む。</p>',
      );
      // plainText = 漢字を読む。（振假名已剥离）→ 実義字符 漢字を読む = 5，。剔除。
      expect(book.chapterPlainText(0), '漢字を読む。');
      expect(book.chapterCharacterCount(0), 5);
    });

    test('含大量标点的段落：实义计数严格低于原始长度（比旧口径低）', () {
      final EpubBook book = _bookWithHtml(
        '<p>「ねえ、」と彼女は言った。──そして、笑った！</p>',
      );
      final String plain = book.chapterPlainText(0);
      expect(book.chapterCharacterCount(0), lessThan(plain.length));
      expect(book.chapterCharacterCount(0), greaterThan(0));
    });

    test('越界索引 → 0', () {
      final EpubBook book = _bookWithHtml('<p>本文</p>');
      expect(book.chapterCharacterCount(-1), 0);
      expect(book.chapterCharacterCount(5), 0);
    });
  });

  group('kChapterCharCountCaliber', () {
    test('whitelist 对齐 ttu 时口径版本已 >= 3（改 whitelist 必须 +1 版本触发重算）', () {
      // 若有人改了 whitelist 却忘了 bump 版本号，已按旧 whitelist 重算成旧版本的
      // 缓存不会再重算、继续偏离 hoshi——本断言把「改口径必 bump 版本」钉死。
      expect(kChapterCharCountCaliber, greaterThanOrEqualTo(3));
    });
  });
}
