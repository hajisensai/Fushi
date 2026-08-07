/// 用**用户自己的卡模板**渲染编辑器预览。
///
/// 取代早先那份手写 DOM mock：mock 只是「长得像」Lapis，用户换了版本或改过模板
/// 就与真卡对不上（反馈原话「调整器里面默认的 lapis 和默认的 lapis 不一样」）。
/// 拿真实模板渲染示例数据之后，预览的结构天然与真卡一致。
///
/// 点选标记不再手写在 mock 里，而是**在浏览器侧按 [lapisVisualSelector] 自动打**：
/// selector 本来就是「这个可视字段对应真卡上哪些元素」的真相源，让它同时驱动预览
/// 的可点选区域，就不可能出现「预览能选、真卡选不中」的漂移。
library;

import 'dart:convert';

import 'anki_template_render.dart';
import 'lapis_blocks.dart';
import 'lapis_styling.dart';

/// 各字段在预览里的示例值。
///
/// 只求「形状对」：给出的都是短、可辨认、能体现排版的内容。取不到示例的字段回落
/// 成字段名本身，比空白强——用户至少能看出那块位置放的是哪个字段。
const Map<String, String> kLapisPreviewFieldSamples = <String, String>{
  'Expression': '食べる',
  'ExpressionFurigana': ' 食[た]べる',
  'ExpressionReading': 'たべる',
  'ExpressionAudio': '<a class="replay-button">▶</a>',
  'SelectionText': '生命を維持するために食物を取る。',
  'MainDefinition': '<div class="yomitan-glossary" style="text-align: left;">'
      '<ol><li data-dictionary="明鏡国語辞典 第三版">'
      '<i>(他動詞, 明鏡国語辞典 第三版)</i>'
      '<span>物を口に入れ、かんで飲み込む。'
      '<span data-sc-content="example-sentence">例：朝食を食べる。</span>'
      '</span></li></ol></div>',
  'Glossary': '<div class="yomitan-glossary" style="text-align: left;">'
      '<ol><li data-dictionary="JMdict"><i>(v1, vt, JMdict)</i>'
      '<span><ul><li>to eat; to consume</li><li>to live on</li></ul></span>'
      '</li>'
      '<li data-dictionary="新和英大辞典"><i>(新和英大辞典)</i>'
      '<span>パンを食べる — to eat bread</span></li></ol></div>',
  'Sentence': '私は毎朝パンを食べる。',
  'SentenceFurigana': '私[わたし]は 毎朝[まいあさ]パンを 食[た]べる。',
  'SentenceAudio': '<a class="replay-button">▶</a>',
  'Picture': '<div class="hibiki-preview-picture">IMAGE</div>',
  'DefinitionPicture': '<div class="hibiki-preview-picture">IMAGE</div>',
  'Hint': 'ヒント',
  'PitchPosition': '2',
  'PitchCategories': 'nakadaka',
  'Frequency': '1320',
  'FreqSort': '1320',
  'MiscInfo': 'サンプル出典',
  'Tags': 'hibiki',
  'IsWordAndSentenceCard': 'x',
};

/// 模板会用到、但没有示例值的字段：回落成字段名，让位置可见。
Map<String, String> buildLapisPreviewFields(String template) {
  final Map<String, String> fields = <String, String>{};
  for (final String name in ankiTemplateReferencedFields(template)) {
    fields[name] = kLapisPreviewFieldSamples[name] ?? name;
  }
  return fields;
}

/// 渲染一面（正面或背面）：插入自定义区域 → 用示例数据渲染。
///
/// 区域只插背面（[blocks] 传空即可跳过），与真实推送同一个函数、同一套锚点。
String renderLapisPreviewSide({
  required String template,
  List<LapisCustomBlock> blocks = const <LapisCustomBlock>[],
}) {
  final String withBlocks = blocks.isEmpty
      ? template
      : insertLapisBlocksIntoBackHtml(
          stripLapisBlocksSections(template),
          blocks,
          renderBlock: buildLapisBlockHtml,
        );
  return renderAnkiTemplate(withBlocks, buildLapisPreviewFields(withBlocks));
}

/// 浏览器侧脚本：按 [lapisVisualSelector] 给渲染结果打上可点选标记。
///
/// 每个可视字段的 selector 命中的元素都会拿到 `data-hibiki-lapis-targets`，
/// 与手写 mock 时代的属性语义完全一致，但**来源变成了 selector 真相源**，所以
/// 「预览可选中的东西」与「样式实际作用的东西」按定义永远一致。
String buildLapisPreviewTargetScript() {
  final Map<String, String> selectors = <String, String>{
    for (final LapisVisualField field in LapisVisualField.values)
      field.wireName: lapisVisualSelector(field),
  };
  return '''
window.hibikiLapisTargets = ${jsonEncode(selectors)};
window.hibikiLapisMarkTargets = function() {
  var map = window.hibikiLapisTargets;
  // 先清空再重打：布局/区域变化后元素集合会变，残留标记会让已经不存在的
  // 位置继续「可点」。
  document.querySelectorAll('[data-hibiki-lapis-targets]').forEach(
    function(el) { el.removeAttribute('data-hibiki-lapis-targets'); });
  Object.keys(map).forEach(function(name) {
    var nodes;
    try { nodes = document.querySelectorAll(map[name]); } catch (e) { return; }
    nodes.forEach(function(el) {
      var prev = el.getAttribute('data-hibiki-lapis-targets');
      el.setAttribute(
        'data-hibiki-lapis-targets', prev ? prev + ' ' + name : name);
    });
  });
  // 自定义区域自带 data-hibiki-block，点选目标直接由它派生。
  document.querySelectorAll('[data-hibiki-block]').forEach(function(el) {
    el.setAttribute(
      'data-hibiki-lapis-targets',
      'block-' + el.getAttribute('data-hibiki-block'));
  });
};
''';
}
