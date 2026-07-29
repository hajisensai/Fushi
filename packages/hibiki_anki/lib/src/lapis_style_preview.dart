import 'dart:convert';

import 'lapis_styling.dart';

/// 用真实 Lapis selector 构造一张无外部资源的示例卡。正式预览把 vendored CSS
/// 与当前用户 CSS 作为 [css] 注入；所有内容区域都带稳定 data attribute，供
/// WebView 点击回传和高亮。
String buildLapisStylePreviewHtml({
  required String css,
  required LapisVisualField selectedField,
  required bool showBack,
  required bool darkMode,
}) {
  final String modeClass = darkMode ? 'nightMode' : '';
  final String bodyModeClass = darkMode ? ' nightMode' : '';
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
    <main>
      <div class="def-header">
        <div class="dh-vocab">
          <div class="vocab" data-hibiki-lapis-targets="expression"><ruby>食<rt>た</rt></ruby>べる</div>
          <div class="info">
            <div class="pitch" data-hibiki-lapis-targets="reading">たべる【2】</div>
          </div>
        </div>
        <div class="dh-image"><div class="hibiki-preview-picture">IMAGE</div></div>
      </div>
      <br>
      <div class="sentence" data-hibiki-lapis-targets="sentence">
        私は毎朝パンを<b>食べる</b>。
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
            <ol class="yomitan-glossary">
              <li data-dictionary="明鏡国語辞典 第三版"
                  data-hibiki-lapis-targets="dictionary-entry">
                <i data-hibiki-lapis-targets="dictionary-name">明鏡国語辞典</i>
                <div class="dict-group__tag-list">
                  <span class="dict-group__tag"
                        data-hibiki-lapis-targets="part-of-speech">他動詞</span>
                </div>
                <div class="dict-group__glossary">
                  物を口に入れ、かんで飲み込む。
                  <span data-sc-content="example-sentence"
                        data-hibiki-lapis-targets="definition-example">
                    例：朝食を食べる。
                  </span>
                </div>
              </li>
            </ol>
          </div>
          <div id="glossaries"
               data-hibiki-lapis-targets="glossaries definition-content">
            <ol>
              <li data-details="JMdict"
                  data-hibiki-lapis-targets="dictionary-entry">
                <i data-hibiki-lapis-targets="dictionary-name">JMdict</i>
                <div class="dict-group__tag-list">
                  <span class="dict-group__tag"
                        data-hibiki-lapis-targets="part-of-speech">Ichidan verb</span>
                </div>
                <div class="dict-group__glossary">
                  <ul><li>to eat; to consume</li><li>to live on</li></ul>
                  <span data-sc-content="example"
                        data-hibiki-lapis-targets="definition-example">
                    パンを食べる — to eat bread
                  </span>
                </div>
              </li>
            </ol>
          </div>
        </div>
      </div>
    </main>
  </div>
</section>
<script>
document.getElementById('lapis-style').textContent = ${_jsonForScript(css)};
window.hibikiLapisEditor = {
  selectedField: null,
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
window.hibikiLapisEditor.showSide(${_jsonForScript(showBack ? 'back' : 'front')});
window.hibikiLapisEditor.selectField(${_jsonForScript(selectedField.wireName)});
</script>
</body>
</html>''';
}

String _jsonForScript(String value) =>
    jsonEncode(value).replaceAll('<', r'\u003C');
