import 'dart:convert';

import 'lapis_blocks.dart';
import 'lapis_styling.dart';

/// 预览背面的 `<main>` 区块。抽成常量是为了让自定义区域能用
/// [insertLapisBlocksIntoBackHtml]——**与真模板同一个函数、同一套锚点**插进来。
/// 预览自己再写一套定位，就会出现「预览里位置对、真卡上位置不对」。
///
/// 只取背面：正面也有 `<main>` 和 `</main>`，拿整份 HTML 去 indexOf 会插错边。
const String _previewBackMain = '''    <main>
      <div class="def-header">
        <div class="dh-vocab">
          <div class="vocab" data-hibiki-lapis-targets="expression"><ruby>食<rt>た</rt></ruby>べる</div>
          <div class="info">
            <div class="pitch" data-hibiki-lapis-targets="reading">たべる【2】</div>
            <div class="audio-buttons"><span class="hibiki-preview-audio">▶ AUDIO</span></div>
          </div>
        </div>
        <div class="dh-image">
          <div class="image"><div class="hibiki-preview-picture">IMAGE</div></div>
        </div>
      </div>
      <br>
      <div class="sentence" data-hibiki-lapis-targets="sentence">
        <div class="image-alt"><div class="hibiki-preview-picture">IMAGE</div></div>
        私は毎朝パンを<b>食べる</b>。
        <div class="audio-buttons-alt"><span class="hibiki-preview-audio">▶ AUDIO</span></div>
      </div>
      <div class="def-info" data-hibiki-lapis-targets="definition-info">
        First Definition 1/3
      </div>
      <div class="main-def" data-hibiki-lapis-targets="definition-box">
        <div class="definition">
          <div id="selection"
               data-hibiki-lapis-targets="selected-definition definition-content">
            <span class="hibiki-preview-definition-label">Text Selection</span>
            生命を維持するために食物を取る。
          </div>
          <div id="primary"
               data-hibiki-lapis-targets="primary-definition definition-content">
            <div class="yomitan-glossary" style="text-align: left;">
              <ol>
                <li data-dictionary="明鏡国語辞典 第三版"
                    data-hibiki-lapis-targets="dictionary-entry">
                  <i data-hibiki-lapis-targets="dictionary-name">(他動詞, 明鏡国語辞典 第三版)</i>
                  <span>
                    物を口に入れ、かんで飲み込む。
                    <span data-sc-content="example-sentence"
                          data-hibiki-lapis-targets="definition-example">
                      例：朝食を食べる。
                    </span>
                  </span>
                </li>
              </ol>
            </div>
          </div>
          <div id="glossaries"
               data-hibiki-lapis-targets="glossaries definition-content">
            <div class="yomitan-glossary" style="text-align: left;">
              <ol>
                <li data-dictionary="JMdict"
                    data-hibiki-lapis-targets="dictionary-entry">
                  <i data-hibiki-lapis-targets="dictionary-name">(v1, vt, JMdict)</i>
                  <span>
                    <ul><li>to eat; to consume</li><li>to live on</li></ul>
                  </span>
                </li>
                <li data-dictionary="新和英大辞典"
                    data-hibiki-lapis-targets="dictionary-entry">
                  <i data-hibiki-lapis-targets="dictionary-name">(新和英大辞典)</i>
                  <span>パンを食べる — to eat bread</span>
                </li>
              </ol>
            </div>
          </div>
        </div>
      </div>
      <div class="sentence-alt" data-hibiki-lapis-targets="sentence">
        <div class="image-alt"><div class="hibiki-preview-picture">IMAGE</div></div>
        私は毎朝パンを<b>食べる</b>。
        <div class="audio-buttons-alt"><span class="hibiki-preview-audio">▶ AUDIO</span></div>
      </div>
    </main>''';

/// 字段在预览里的示例内容。取不到就显示字段名本身——比显示空白强，用户至少
/// 知道那块放的是哪个字段。
const Map<String, String> _previewFieldSamples = <String, String>{
  'Expression': '食べる',
  'ExpressionFurigana': '食べる',
  'ExpressionReading': 'たべる',
  'ExpressionAudio': '▶ AUDIO',
  'Sentence': '私は毎朝パンを食べる。',
  'SentenceFurigana': '私は毎朝パンを食べる。',
  'SentenceAudio': '▶ AUDIO',
  'SelectionText': '生命を維持するために食物を取る。',
  'MainDefinition': '物を口に入れ、かんで飲み込む。',
  'Glossary': 'to eat; to consume',
  'Frequency': '1320',
  'FreqSort': '1320',
  'PitchPosition': '2',
  'PitchCategories': 'nakadaka',
  'MiscInfo': 'サンプル出典',
  'Hint': 'ヒント',
};

/// 预览里的一个自定义区域。
///
/// 与真模板产物（[buildLapisBlockHtml]）的**结构和 class 完全一致**——区域样式
/// 走 `[data-hibiki-block]` selector，结构一漂样式预览就不准。区别只有两点：
/// 内容换成示例文本（真模板是 handlebar），以及多挂一个点击目标属性。
String _previewBlockHtml(LapisCustomBlock block) {
  final String target = lapisPreviewBlockTarget(block.id);
  final Iterable<String> parts = block.fields
      .where(isValidLapisBlockFieldName)
      .map((String f) => '<div class="hibiki-block-field" data-hibiki-field="'
          '$f">${_previewFieldSamples[f] ?? f}</div>');
  // 空区域在真卡上被 `:empty` 隐藏，但预览里必须看得见——否则「新建区域」之后
  // 屏幕上什么都没有，用户既选不中它也不知道它在哪。
  final String body = block.fields.isEmpty
      ? '<span class="hibiki-preview-block-empty">EMPTY BLOCK</span>'
      : parts.join();
  return '<div class="hibiki-block" data-hibiki-block="${block.id}" '
      'data-hibiki-lapis-targets="$target">$body</div>';
}

/// 用真实 Lapis selector 构造一张无外部资源的示例卡。正式预览把 vendored CSS
/// 与当前用户 CSS 作为 [css] 注入；所有内容区域都带稳定 data attribute，供
/// WebView 点击回传和高亮。
String buildLapisStylePreviewHtml({
  required String css,
  required LapisVisualField selectedField,
  required bool showBack,
  required bool darkMode,
  List<LapisCustomBlock> blocks = const <LapisCustomBlock>[],
  String? selectedBlockId,
}) {
  final String modeClass = darkMode ? 'nightMode' : '';
  final String bodyModeClass = darkMode ? ' nightMode' : '';
  // 选中目标：自定义区域优先。两者互斥——面板上同一时刻只编辑一个目标。
  final String selectedTarget = selectedBlockId != null
      ? lapisPreviewBlockTarget(selectedBlockId)
      : selectedField.wireName;
  final String backMain = insertLapisBlocksIntoBackHtml(
    _previewBackMain,
    blocks,
    renderBlock: _previewBlockHtml,
  );
  return '''<!doctype html>
<html class="$modeClass">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style id="lapis-style"></style>
<style>
  html, body { min-height: 100%; margin: 0; }
  body { box-sizing: border-box; padding: 24px; overflow: auto; }
  .hibiki-preview-side[hidden] { display: none !important; }
  [data-hibiki-lapis-targets] {
    cursor: pointer;
    transition: outline-color 120ms ease;
  }
  [data-hibiki-lapis-targets].hibiki-selected-field {
    outline: 3px solid #4f8f80 !important;
    outline-offset: 4px;
  }
  .hibiki-preview-definition-label {
    display: inline-block;
    margin-inline-end: 0.4em;
    color: var(--fg-subtle);
    font-size: 0.8em;
  }
  .hibiki-preview-side .def-info {
    visibility: visible;
  }
  .hibiki-preview-picture {
    min-height: 120px;
    display: grid;
    place-items: center;
    color: var(--fg-subtle);
    background: var(--bg-elevated);
    border-radius: 5px;
  }
  /* `.audio-buttons-alt` 出厂带 font-size: 0（真卡里放的是 svg 回放按钮），
     预览用文字占位，必须自己把字号写回来才看得见。 */
  .hibiki-preview-block-empty {
    display: inline-block;
    padding: 0.3em 0.8em;
    border: 1px dashed var(--fg-subtle);
    border-radius: 5px;
    color: var(--fg-subtle);
    font-size: 0.8rem;
  }
  .hibiki-preview-audio {
    display: inline-block;
    font-size: 1rem;
    line-height: 1.6;
    padding-inline: 0.5em;
    border: 1px solid var(--fg-subtle);
    border-radius: 5px;
    color: var(--fg-subtle);
  }
</style>
</head>
<body class="card card1$bodyModeClass">
<section class="hibiki-preview-side" data-side="front">
  <div id="lapis">
    <header style="visibility:hidden"></header>
    <main lang="ja">
      <div class="front-vocab" data-hibiki-lapis-targets="expression">食べる</div>
      <div id="hint" data-hibiki-lapis-targets="sentence">私は毎朝パンを食べる。</div>
    </main>
  </div>
</section>
<section class="hibiki-preview-side" data-side="back">
  <div id="lapis" lang="ja">
    <header><div class="top-container">1320</div></header>
${backMain}
  </div>
</section>
<script>
document.getElementById('lapis-style').textContent = ${_jsonForScript(css)};
window.hibikiLapisEditor = {
  selectedField: null,
  // 与 LapisNoteType.back 的 userSettings() 同一套判据：读 :root 上的 user
  // settings 变量，去引号小写后写成 #lapis 的 data-* 属性——布局全靠这些属性
  // 选中 vendored CSS 里的切换规则。真卡只在加载时跑一次；预览每次注入新 CSS
  // 后都要重跑，否则改了位置看不到变化。
  applyLayout: function() {
    var styles = getComputedStyle(document.documentElement);
    var options = [
      '--main-picture-position',
      '--sentence-position',
      '--audio-buttons',
      '--sentence-furigana',
      '--glossary-separator'
    ];
    var nodes = document.querySelectorAll('[id="lapis"]');
    for (var i = 0; i < options.length; i++) {
      var opt = options[i];
      var value = styles.getPropertyValue(opt)
        .replace(/^['"]|['"]\$/g, '')
        .trim()
        .toLowerCase();
      for (var n = 0; n < nodes.length; n++) {
        nodes[n].setAttribute('data-' + opt.slice(2), value);
      }
    }
  },
  showSide: function(side) {
    document.querySelectorAll('[data-side]').forEach(function(element) {
      element.hidden = element.dataset.side !== side;
    });
  },
  selectField: function(field) {
    this.selectedField = field;
    document.querySelectorAll('[data-hibiki-lapis-targets]').forEach(function(element) {
      var targets = (element.dataset.hibikiLapisTargets || '').split(/\\s+/);
      element.classList.toggle(
        'hibiki-selected-field',
        targets.indexOf(field) >= 0
      );
    });
  }
};
document.addEventListener('click', function(event) {
  var target = event.target.closest('[data-hibiki-lapis-targets]');
  if (!target) return;
  var candidates = [];
  var current = target;
  while (current) {
    var targets = (current.dataset.hibikiLapisTargets || '').split(/\\s+/);
    targets.forEach(function(field) {
      if (field && candidates.indexOf(field) < 0) candidates.push(field);
    });
    current = current.parentElement
      ? current.parentElement.closest('[data-hibiki-lapis-targets]')
      : null;
  }
  var selectedIndex = candidates.indexOf(window.hibikiLapisEditor.selectedField);
  var field = selectedIndex >= 0 && selectedIndex + 1 < candidates.length
    ? candidates[selectedIndex + 1]
    : candidates[0];
  window.hibikiLapisEditor.selectField(field);
  if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
    window.flutter_inappwebview.callHandler('selectLapisVisualField', field);
  }
});
window.hibikiLapisEditor.applyLayout();
window.hibikiLapisEditor.showSide(${_jsonForScript(showBack ? 'back' : 'front')});
window.hibikiLapisEditor.selectField(${_jsonForScript(selectedTarget)});
</script>
</body>
</html>''';
}

/// 编辑器每次改动后重放到预览 WebView 的脚本。
///
/// 与首屏内联脚本的**收尾四步逐字对应**，是同一份契约的单一真相源：注入新 CSS
/// → 重跑布局映射 → 切正/背面 → 重新高亮选中区域。顺序不能动：`applyLayout`
/// 读的是 computed style，CSS 没落地就读到旧值；漏掉它则改了区块位置要重新载入
/// 页面才看得到效果（守卫见 `lapis_style_preview_test.dart`『刷新脚本按同一顺序
/// 重放布局』）。
String buildLapisStylePreviewRefreshScript({
  required String css,
  required LapisVisualField selectedField,
  required bool showBack,
  String? selectedBlockId,
}) =>
    '''
document.getElementById('lapis-style').textContent = ${_jsonForScript(css)};
window.hibikiLapisEditor.applyLayout();
window.hibikiLapisEditor.showSide(${_jsonForScript(showBack ? 'back' : 'front')});
window.hibikiLapisEditor.selectField(${_jsonForScript(selectedBlockId != null ? lapisPreviewBlockTarget(selectedBlockId) : selectedField.wireName)});
''';

String _jsonForScript(String value) =>
    jsonEncode(value).replaceAll('<', r'\u003C');
