// BUG-4331（反馈 Hm3asDcb8b）：复习卡上明鏡的外字（［参考］菱形 SVG）画成 150px 方块。
//
// 制卡端把几何写死在字段里：Yomitan 给没有固有尺寸的 SVG（只有 viewBox）填媒体加载器
// 默认的 150×150，导出成 `font-size:1px;width:150em`；导出又把 gloss-* class 剥掉，卡面上
// 能认出外字的只剩 `data-sc-class="gaiji"`。Fushi 卡片样式表必须按这个属性把图片盒压回
// 一个字大，且三种导出形态都要命中：
//   * Yomitan / 现行 Fushi：`<a>` 图片链接，盒子是它的第一个 span（无 class）；
//   * 旧版 Fushi：`.gloss-image-link > .gloss-image-container`，词典 CSS 的
//     `.yomitan-glossary [data-dictionary=…] span[data-sc-img][data-sc-class="gaiji"]
//      .gloss-image-container{width:15em!important}`（特异度 0,5,1）在卡面上命中。
// 这里是样式表守卫（真浏览器排版取证见 BUG 文件）：规则在、取值对、特异度压得过词典规则。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

/// 样式表里的一条规则（选择器按逗号拆开，声明按属性名归一）。
class _Rule {
  _Rule(this.selectors, this.declarations);

  final List<String> selectors;
  final Map<String, String> declarations;
}

List<_Rule> _parseRules(String css) {
  final String noComments = css.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final List<_Rule> rules = <_Rule>[];
  for (final RegExpMatch m in RegExp(
    r'([^{}]+)\{([^{}]*)\}',
  ).allMatches(noComments)) {
    final List<String> selectors = m
        .group(1)!
        .split(',')
        .map((String s) => s.trim().replaceAll(RegExp(r'\s+'), ' '))
        .where((String s) => s.isNotEmpty)
        .toList();
    final Map<String, String> decls = <String, String>{};
    for (final String d in m.group(2)!.split(';')) {
      final int colon = d.indexOf(':');
      if (colon < 0) continue;
      decls[d.substring(0, colon).trim()] = d
          .substring(colon + 1)
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');
    }
    rules.add(_Rule(selectors, decls));
  }
  return rules;
}

/// 简单选择器的特异度 (id, class/属性/伪类, 元素)。只处理本测试用到的写法。
(int, int, int) _specificity(String selector) {
  final String s = selector.replaceAll(RegExp(r'\[[^\]]*\]'), ' .attr ');
  final int ids = RegExp(r'#[\w-]+').allMatches(s).length;
  final int classes = RegExp(r'\.[\w-]+|:[\w-]+').allMatches(s).length;
  final int elements = RegExp(
    r'(^|[\s>+~])([a-zA-Z][\w-]*)',
  ).allMatches(s).length;
  return (ids, classes, elements);
}

bool _beats((int, int, int) a, (int, int, int) b) {
  if (a.$1 != b.$1) return a.$1 > b.$1;
  if (a.$2 != b.$2) return a.$2 > b.$2;
  return a.$3 > b.$3;
}

void main() {
  final List<_Rule> rules = _parseRules(kFushiCardStylingCss);

  _Rule ruleFor(String selector) => rules.firstWhere(
    (_Rule r) => r.selectors.contains(selector),
    orElse: () => throw StateError('styling.css 缺少规则：$selector'),
  );

  const String scope =
      '.fc .fc-gloss li[data-dictionary] [data-sc-class="gaiji"]';
  const String currentBox = '$scope a > span:first-child';
  const String legacyBox = '$scope .gloss-image-link > .gloss-image-container';
  const String currentLink = '$scope a';
  const String legacyLink = '$scope .gloss-image-link';

  // 明鏡 styles.css 里撑大外字盒的那条规则（作用域前缀是 Yomitan / Fushi 导出加的）。
  const String meikyoRule =
      '.yomitan-glossary [data-dictionary="明鏡国語辞典 第三版"] '
      'span[data-sc-img][data-sc-class="gaiji"] .gloss-image-container';

  test('外字图片盒在两种导出形态下都压成 1em 方块', () {
    for (final String selector in <String>[currentBox, legacyBox]) {
      final Map<String, String> d = ruleFor(selector).declarations;
      for (final String prop in <String>[
        'width',
        'height',
        'max-width',
        'max-height',
        'font-size',
      ]) {
        expect(d[prop], '1em !important', reason: '$selector 的 $prop');
      }
      // Fushi 导出的外字盒内联了 `width:auto!important`（内联 !important 压不动），
      // 只能靠 min-width 撑出 1em；写成 0 会把盒子塌成 0 宽、外字消失。
      expect(d['min-width'], '1em !important', reason: '$selector 的 min-width');
      expect(d['display'], 'inline-block !important');
    }
  });

  test('外字图片链接限宽、按文字底对齐', () {
    for (final String selector in <String>[currentLink, legacyLink]) {
      final Map<String, String> d = ruleFor(selector).declarations;
      expect(d['max-width'], '1.2em !important', reason: selector);
      expect(d['vertical-align'], 'text-bottom !important', reason: selector);
    }
  });

  test('特异度压过词典 CSS 撑大外字盒的规则（0,5,1）', () {
    final (int, int, int) dict = _specificity(meikyoRule);
    expect(dict, (0, 5, 1));
    for (final String selector in <String>[currentBox, legacyBox]) {
      expect(
        _beats(_specificity(selector), dict),
        isTrue,
        reason: '$selector ${_specificity(selector)} 必须高于 $dict',
      );
    }
  });

  test('不碰外字以外的图片：规则都限定在 data-sc-class="gaiji" 下', () {
    for (final _Rule r in rules) {
      final bool touchesBox = r.selectors.any(
        (String s) => s.endsWith('a > span:first-child'),
      );
      if (!touchesBox) continue;
      for (final String s in r.selectors) {
        expect(s, contains('[data-sc-class="gaiji"]'), reason: s);
      }
    }
  });
}
