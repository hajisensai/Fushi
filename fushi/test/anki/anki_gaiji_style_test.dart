import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 外字（gaiji）中和样式 `normalizeAnkiDictionaryHtml` 的两面守卫。
///
/// 旧格式（A-overlap）：制卡 meaning 里外字框被词典自带 CSS
/// `span[data-sc-img][data-sc-class="gaiji"] .gloss-image-container{width:15em!important}`
/// 撑成 15em → 压重叠正文（明鏡国語辞典 第三版，BUG「3分の2」截图）。旧版 popup.js
/// 导出的 HTML 仍带 `gloss-*` class，中和样式追加在末尾，选择器特异性必须 **不低于**
/// 词典规则（等特异性时靠后者居上的源码顺序取胜）。互联制卡里尚未升级的对端仍会发来
/// 这种 HTML，所以这层兜底保留。
///
/// 新格式（BUG-2825）：popup.js 按 Yomitan 形态导出，内联 structured-content 样式并剥掉
/// `gloss-*` class，门控不命中，字段必须字节不变——否则中和样式会把外字压成 1em 并下沉
/// （用户在明鏡真卡上对照 Yomitan 卡确认过）。同时锁定图片外层 `<a href>` 里的媒体
/// 占位符与 `<img src>` 一起被换成真实文件名（`replaceAll`），点开的是同一个媒体文件。
class _TestRepo extends BaseAnkiRepository {
  @override
  Future<AnkiFetchResult> fetchConfiguration() => throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) => throw UnimplementedError();

  @override
  Future<bool> isDuplicate(String expression, String reading) =>
      throw UnimplementedError();

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) =>
      throw UnimplementedError();

  @override
  Future<bool> createDeck(String name) => throw UnimplementedError();

  Map<String, String> fieldsFor(String glossary, Map<String, String> tags) =>
      buildMinedFields(
        fieldMappings: const <String, String>{'Back': '{glossary}'},
        payload: AnkiMiningPayload(expression: '一', glossary: glossary),
        context: const AnkiMiningContext(sentence: ''),
        dictionaryMediaTags: tags,
      );
}

/// popup.js 修复后导出的外字形状（Yomitan 同形：`<a target rel href>`，无 class）。
const String _exportedGaiji =
    '<div class="yomitan-glossary"><ol><li data-dictionary="明鏡国語辞典 第三版">'
    '<span><span data-sc-img="" data-sc-class="gaiji">'
    '<a target="_blank" rel="noreferrer noopener" href="fushi_dict_0.svg" '
    'style="display:inline-block;">'
    '<span style="display:inline-block;font-size:1em;">'
    '<img alt="3分の2" src="fushi_dict_0.svg" style="display:inline-block;">'
    '</span></a></span></span></li></ol></div>';

void main() {
  group('Anki gaiji image style (A-overlap, legacy export shape)', () {
    test('neutralizer container rule beats dict 15em width by specificity', () {
      // 明鏡词典自带的「撑爆」规则（用户卡片 HTML 实测）。
      const dictGaijiContainerSelector =
          '.yomitan-glossary [data-dictionary="明鏡国語辞典 第三版"] '
          'span[data-sc-img][data-sc-class="gaiji"] .gloss-image-container';

      // 触发追加（含 data-sc-img + gloss-image），并把词典规则放进输入模拟真实卡片。
      const input =
          '<div class="yomitan-glossary">'
          '<span data-sc-img data-sc-class="gaiji">'
          '<span class="gloss-image-link"><span class="gloss-image-container">'
          '<span class="gloss-image">3分の2</span></span></span></span>'
          '<style>$dictGaijiContainerSelector{width:15em!important}</style>'
          '</div>';

      final out = normalizeAnkiDictionaryHtml(input);

      // 取「追加在末尾」的中和器 <style> 的 .gloss-image-container 规则选择器。
      final neutralizerSelector = _selectorForRuleEndingWith(
        out,
        '.gloss-image-container',
      );
      expect(
        neutralizerSelector,
        isNotNull,
        reason: '中和器必须包含一条 .gloss-image-container 规则',
      );

      final dictSpec = _specificity(dictGaijiContainerSelector);
      final neutSpec = _specificity(neutralizerSelector!);

      // 中和器追加在末尾，等特异性即可取胜；故要求 >= 词典规则。
      expect(
        _compareSpecificity(neutSpec, dictSpec) >= 0,
        isTrue,
        reason:
            '中和器 .gloss-image-container 特异性 $neutSpec 必须 >= 词典 $dictSpec，'
            '否则 width:15em!important 仍生效→外字框撑爆重叠',
      );

      // 中和器必须把宽度收回到 1em 量级且 !important。
      expect(out, contains('width:1em!important'));
    });

    test('non-gaiji html is returned unchanged', () {
      const plain = '<div class="yomitan-glossary"><span>定义</span></div>';
      expect(normalizeAnkiDictionaryHtml(plain), plain);
    });
  });

  group('Anki gaiji image style (BUG-2825, Yomitan export shape)', () {
    test(
      'new export shape (no gloss-* class) passes through byte-identical',
      () {
        expect(_exportedGaiji, contains('data-sc-img'));
        expect(_exportedGaiji, isNot(contains('gloss-')));
        expect(normalizeAnkiDictionaryHtml(_exportedGaiji), _exportedGaiji);
      },
    );

    test('mined field is the exported glossary with media placeholders '
        'replaced, no neutralizer style appended', () {
      final String back = _TestRepo().fieldsFor(
        _exportedGaiji,
        const <String, String>{'fushi_dict_0.svg': 'real_stored.svg'},
      )['Back']!;

      expect(back, isNot(contains('<style>')), reason: '新导出形态不得命中外字中和门控');
      expect(back, isNot(contains('!important')));
      expect(
        back,
        _exportedGaiji.replaceAll('fushi_dict_0.svg', 'real_stored.svg'),
        reason: '字段内容就是 popup.js 导出的释义，只做媒体占位符替换',
      );
      expect(
        back,
        contains('href="real_stored.svg"'),
        reason: '图片外层 <a> 的 href 必须与 <img src> 指向同一个已存入 Anki 的媒体',
      );
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
