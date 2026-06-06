import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// A-overlap 守卫：制卡 meaning 里外字（gaiji）框被词典自带 CSS
/// `span[data-sc-img][data-sc-class="gaiji"] .gloss-image-container{width:15em!important}`
/// 撑成 15em → 压重叠正文（明鏡国語辞典 第三版，BUG「3分の2」截图）。
///
/// `normalizeAnkiDictionaryHtml` 会把 gaiji 中和样式 **追加在末尾**。要真正赢过词典
/// 那条 `!important` 规则，中和器选择器的 CSS 特异性必须 **不低于** 词典规则
/// （等特异性时靠后者居上的源码顺序取胜）。本测试用最小特异性计算器对比两者。
void main() {
  group('Anki gaiji image style (A-overlap)', () {
    test('neutralizer container rule beats dict 15em width by specificity', () {
      // 明鏡词典自带的「撑爆」规则（用户卡片 HTML 实测）。
      const dictGaijiContainerSelector =
          '.yomitan-glossary [data-dictionary="明鏡国語辞典 第三版"] '
          'span[data-sc-img][data-sc-class="gaiji"] .gloss-image-container';

      // 触发追加（含 data-sc-img + gloss-image），并把词典规则放进输入模拟真实卡片。
      const input = '<div class="yomitan-glossary">'
          '<span data-sc-img data-sc-class="gaiji">'
          '<span class="gloss-image-link"><span class="gloss-image-container">'
          '<span class="gloss-image">3分の2</span></span></span></span>'
          '<style>$dictGaijiContainerSelector{width:15em!important}</style>'
          '</div>';

      final out = normalizeAnkiDictionaryHtml(input);

      // 取「追加在末尾」的中和器 <style> 的 .gloss-image-container 规则选择器。
      final neutralizerSelector =
          _selectorForRuleEndingWith(out, '.gloss-image-container');
      expect(neutralizerSelector, isNotNull,
          reason: '中和器必须包含一条 .gloss-image-container 规则');

      final dictSpec = _specificity(dictGaijiContainerSelector);
      final neutSpec = _specificity(neutralizerSelector!);

      // 中和器追加在末尾，等特异性即可取胜；故要求 >= 词典规则。
      expect(_compareSpecificity(neutSpec, dictSpec) >= 0, isTrue,
          reason: '中和器 .gloss-image-container 特异性 $neutSpec 必须 >= 词典 $dictSpec，'
              '否则 width:15em!important 仍生效→外字框撑爆重叠');

      // 中和器必须把宽度收回到 1em 量级且 !important。
      expect(out, contains('width:1em!important'));
    });

    test('non-gaiji html is returned unchanged', () {
      const plain = '<div class="yomitan-glossary"><span>定义</span></div>';
      expect(normalizeAnkiDictionaryHtml(plain), plain);
    });
  });
}

/// 返回末尾（最后一个）以 [suffix] 收尾的选择器对应的规则选择器整串；无则 null。
/// 简易解析：扫描所有 `selector{...}` 段，挑选择器以 suffix 结尾的最后一条。
String? _selectorForRuleEndingWith(String css, String suffix) {
  final reg = RegExp(r'([^{}]+)\{[^{}]*\}');
  String? found;
  for (final m in reg.allMatches(css)) {
    final sel = m.group(1)!.trim();
    if (sel.endsWith(suffix)) found = sel;
  }
  return found;
}

/// CSS 特异性 (a,b,c)：a=#id，b=.class/[attr]/:pseudo-class，c=元素/::pseudo-element。
List<int> _specificity(String selector) {
  int a = 0, b = 0, c = 0;
  // 去掉属性值里可能混入的 token 干扰：先抠出 [..] 计数再移除。
  final attrs = RegExp(r'\[[^\]]*\]').allMatches(selector).length;
  b += attrs;
  final stripped = selector.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
  a += RegExp(r'#[\w-]+').allMatches(stripped).length;
  b += RegExp(r'\.[\w-]+').allMatches(stripped).length;
  b += RegExp(r'(?<!:):[\w-]+').allMatches(stripped).length; // :pseudo-class
  // 元素名：被空格/>/+/~ 分隔、不以 . # : [ 开头的裸 token。
  for (final tok in stripped.split(RegExp(r'[\s>+~]+'))) {
    final t = tok.trim();
    if (t.isEmpty) continue;
    if (RegExp(r'^[a-zA-Z][\w-]*$').hasMatch(t)) c += 1;
  }
  return <int>[a, b, c];
}

int _compareSpecificity(List<int> x, List<int> y) {
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return 0;
}
