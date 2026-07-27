import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/src/parsers/strip_html_tags.dart';

/// BUG-1161：`stripHtmlTags` 曾经无差别「删标签留内容」，把注音（振假名）读音拼进
/// 正文（`<ruby>震<rt>ふる</rt></ruby>` → `震ふる`），污染查词 / 制卡 sentence /
/// 字数统计。元素集合与 EPUB 侧 `EpubBook._removeRubyAnnotations` 相同（`rt`/`rp`/`rtc`
/// 丢注音、留基准）；阅读器 JS `isFurigana()` 不含 `rtc`，合法 HTML 下结果收敛（BUG-711）。
/// 注意 EPUB 侧是 DOM 解析、本侧是正则近似，畸形输入只保证「不吞正文」，不保证逐字等价。
void main() {
  group('stripHtmlTags 丢弃注音、保留 ruby base', () {
    test('显式闭合 </rt>', () {
      expect(stripHtmlTags('<ruby>震<rt>ふる</rt></ruby>'), '震');
    });

    test('隐式闭合（HTML 允许省略 </rt>，由 </ruby> 收尾）', () {
      expect(stripHtmlTags('<ruby>震<rt>ふる</ruby>'), '震');
    });

    test('<rp> 回退括号连内容一起丢', () {
      expect(
        stripHtmlTags('<ruby>震<rp>（</rp><rt>ふる</rt><rp>）</rp></ruby>'),
        '震',
      );
    });

    test('mono-ruby：逐字注音各自丢弃，基准按序拼回', () {
      expect(stripHtmlTags('<ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>'), '漢字');
    });

    test('<rtc> 读音容器（内嵌 <rt>）整体不进正文', () {
      expect(
        stripHtmlTags('<ruby>漢字<rtc><rt>かんじ</rt></rtc></ruby>'),
        '漢字',
      );
    });

    test('<rb> 是基准外壳：删标签但保留内容', () {
      expect(stripHtmlTags('<ruby><rb>漢</rb><rt>かん</rt></ruby>'), '漢');
    });

    test('标签大小写不敏感', () {
      expect(stripHtmlTags('<RUBY>震<RT>ふる</RT></RUBY>'), '震');
    });

    test('<rt> 带属性', () {
      expect(stripHtmlTags('<ruby>震<rt lang="ja">ふる</rt></ruby>'), '震');
    });

    test('注音夹在正文中间，前后文不粘不丢', () {
      expect(stripHtmlTags('前<ruby>震<rt>ふる</rt></ruby>後'), '前震後');
    });

    test('一行多个 ruby 元素', () {
      expect(
        stripHtmlTags(
          '<ruby>春<rt>はる</rt></ruby>と<ruby>夏<rt>なつ</rt></ruby>',
        ),
        '春と夏',
      );
    });

    test('行尾裸 <rt> 无任何后继标签，也不把读音留在正文里', () {
      expect(stripHtmlTags('震<rt>ふる'), '震');
    });

    test('ruby 与样式标签混排', () {
      expect(
        stripHtmlTags('<i><ruby>震<rt>ふる</rt></ruby>える</i>'),
        '震える',
      );
    });
  });

  group('stripHtmlTags 不误伤非注音标签（回归护栏）', () {
    test('增强 LRC 词级时间标签 <MM:SS.xx> 仍只删标签留字', () {
      expect(stripHtmlTags('<00:12.34>こん<00:12.99>にちは'), 'こんにちは');
    });

    test('VTT class / 斜体标签仍只删标签留字', () {
      expect(stripHtmlTags('<c.yellow><i>こんにちは</i></c>'), 'こんにちは');
    });

    test('形近但非注音的标签名不被当成注音（<rtl> / <rpc>）', () {
      expect(stripHtmlTags('<rtl>こんにちは</rtl>'), 'こんにちは');
      expect(stripHtmlTags('<rpc>こんにちは</rpc>'), 'こんにちは');
    });

    test('无标签文本原样直通（含首尾空白修剪）', () {
      expect(stripHtmlTags('  吾輩は猫である。  '), '吾輩は猫である。');
    });
  });

  // 畸形注音标签必须整体不匹配、退回旧行为（只删标签、留正文），绝不能借下一个标签的
  // `>` 把开标签凑「合法」再把后面的正文一路吃光。开标签属性段用 `[^>]*` 时这两条会红。
  group('stripHtmlTags 畸形注音标签退回旧行为，不吞正文', () {
    test('开标签缺 `>`：不跨越 `<` 去借下一个标签的 `>`', () {
      expect(stripHtmlTags('<ruby>漢<rt かん</ruby>の話'), '漢の話');
    });

    test('自闭合 `<rt/>`：不当成有内容的开标签，后续正文保留', () {
      expect(stripHtmlTags('a<rt/>b'), 'ab');
      expect(stripHtmlTags('<ruby>漢<rt/>の話'), '漢の話');
    });
  });
}
