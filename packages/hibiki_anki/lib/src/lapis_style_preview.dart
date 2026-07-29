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
  [data-hibiki-lapis-field] {
    cursor: pointer;
    transition: outline-color 120ms ease, background-color 120ms ease;
  }
  [data-hibiki-lapis-field].hibiki-selected-field {
    outline: 3px solid #4f8f80 !important;
    outline-offset: 4px;
    background-color: rgba(79, 143, 128, 0.16) !important;
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
<body class="card card1">
<section class="hibiki-preview-side" data-side="front">
  <div id="lapis">
    <header style="visibility:hidden"></header>
    <main lang="ja">
      <div class="front-vocab" data-hibiki-lapis-field="expression">食べる</div>
      <div id="hint" data-hibiki-lapis-field="sentence">私は毎朝パンを食べる。</div>
    </main>
  </div>
</section>
<section class="hibiki-preview-side" data-side="back">
  <div id="lapis" lang="ja">
    <header><div class="top-container">1320</div></header>
    <main>
      <div class="def-header">
        <div class="dh-vocab">
          <div class="vocab" data-hibiki-lapis-field="expression"><ruby>食<rt>た</rt></ruby>べる</div>
          <div class="info">
            <div class="pitch" data-hibiki-lapis-field="reading">たべる【2】</div>
          </div>
        </div>
        <div class="dh-image"><div class="hibiki-preview-picture">IMAGE</div></div>
      </div>
      <br>
      <div class="sentence" data-hibiki-lapis-field="sentence">
        私は毎朝パンを<b>食べる</b>。
      </div>
      <div class="def-info">First Definition 1/2</div>
      <div class="main-def">
        <div class="definition">
          <div id="primary" data-hibiki-lapis-field="primary-definition">
            物を口に入れ、かんで飲み込む。
          </div>
          <div id="glossaries" data-hibiki-lapis-field="glossaries">
            <ol><li>to eat; to consume</li><li>to live on</li></ol>
          </div>
        </div>
      </div>
    </main>
  </div>
</section>
<script>
document.getElementById('lapis-style').textContent = ${_jsonForScript(css)};
window.hibikiLapisEditor = {
  showSide: function(side) {
    document.querySelectorAll('[data-side]').forEach(function(element) {
      element.hidden = element.dataset.side !== side;
    });
  },
  selectField: function(field) {
    document.querySelectorAll('[data-hibiki-lapis-field]').forEach(function(element) {
      element.classList.toggle(
        'hibiki-selected-field',
        element.dataset.hibikiLapisField === field
      );
    });
  }
};
document.addEventListener('click', function(event) {
  var target = event.target.closest('[data-hibiki-lapis-field]');
  if (!target) return;
  var field = target.dataset.hibikiLapisField;
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
