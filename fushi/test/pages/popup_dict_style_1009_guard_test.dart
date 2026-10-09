import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 用户 10-09 查词弹窗外观一批修复的源码守卫（popup.css / popup.js 跑在 WebView 里，
/// headless 测不到真实绘制，故锁 CSS / JS 契约；视觉证据见 PR 里的 headless Chrome
/// 前后对比截图）。
///
/// - 安卓展开词典前闪一下蓝光：Chromium 安卓默认 tap highlight，根上设透明；
/// - 展开动画砍掉（用户确认），`::details-content` 高度过渡与 interpolate-size 不再出现；
/// - 词典名放不下换行，不再省略号截断；
/// - 释义里的振假名不进选区 / 复制；
/// - 统一样式下 SVG 小图标按 currentColor 着色；
/// - 频率 / 音调挪进词头右侧的元数据列；无注音词头不留注音预留带；
/// - 「N 本辞典」不用原生 title（WebView2 原生提示残留）；
/// - A−/A+ 后按新布局宽度重算列数并重铺（缩放时词条横向溢出）。
void main() {
  final String css = maskCssComments(
    File('assets/popup/popup.css').readAsStringSync(),
  );
  final String js = File('assets/popup/popup.js').readAsStringSync();

  String ruleBody(String selector) {
    final int at = css.indexOf('$selector {');
    expect(at, isNonNegative, reason: '缺少规则：$selector');
    final int open = css.indexOf('{', at);
    return css.substring(open + 1, css.indexOf('}', open));
  }

  test('Android tap highlight is transparent on the document root', () {
    expect(
      ruleBody('html').contains('-webkit-tap-highlight-color: transparent') ||
          css.contains(
            'html {\n    -webkit-tap-highlight-color: transparent;\n}',
          ),
      isTrue,
    );
  });

  test('dictionary expand is instant (no details-content animation)', () {
    expect(css.contains('::details-content'), isFalse);
    expect(css.contains('interpolate-size'), isFalse);
  });

  test('dictionary name wraps instead of being ellipsised', () {
    final String body = ruleBody('html.fushi-m3e .dict-label > .dict-name');
    expect(body.contains('text-overflow: ellipsis'), isFalse);
    expect(body.contains('white-space: nowrap'), isFalse);
    expect(body.contains('white-space: normal'), isTrue);
  });

  test('glossary furigana is not selectable / copyable', () {
    final String body = ruleBody(
      ':where(.glossary-group, .glossary-content) :where(.ruby-rt, rt, rp)',
    );
    expect(body.contains('user-select: none'), isTrue);
    expect(js.contains('function __fushiSelectionPlainText('), isTrue);
    expect(js.contains("document.addEventListener('copy'"), isTrue);
    final String webview = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();
    expect(
      webview.contains('win.__fushiSelectionPlainText'),
      isTrue,
      reason: '右键「复制 / 搜索」取选区文本也要剔注音',
    );
  });

  test('unified style tints SVG icons through a currentColor mask', () {
    expect(js.contains("node.dataset.fushiSvgIcon = 'true'"), isTrue);
    expect(js.contains("'--fushi-svg-image'"), isTrue);
    final String body = ruleBody(
      ':where(.fushi-dict-unified) :where(.gloss-image-link[data-fushi-svg-icon="true"]) :where(.gloss-image-background)',
    );
    expect(body.contains('background-color: currentColor !important'), isTrue);
    expect(
      body.contains('mask-image: var(--fushi-svg-image) !important'),
      isTrue,
    );
  });

  test('frequency / pitch rows sit in the header meta column', () {
    expect(js.contains("className: 'entry-header-main'"), isTrue);
    expect(js.contains("className: 'entry-header-meta'"), isTrue);
    const String start = 'function buildEntryElement(';
    final String fn = js.substring(
      js.indexOf(start),
      js.indexOf('function appendNextDeferredGlossaryBlock('),
    );
    expect(fn.contains('entryDiv.appendChild(freqSection)'), isFalse);
    expect(fn.contains('entryDiv.appendChild(pitchSection)'), isFalse);
    final String meta = ruleBody('.entry-header-meta');
    expect(
      meta.contains('flex: 1 1 14em'),
      isTrue,
      reason: '放不下时整列换到词头下方（自适应），而不是挤压词头',
    );
    expect(
      ruleBody('.entry-header.no-ruby .expression'),
      contains('padding-top: 0'),
    );
  });

  test('pitch source list is not a native title tooltip', () {
    final String fn = js.substring(
      js.indexOf('function createPitchGroup('),
      js.indexOf('function createExpressionTagsSection('),
    );
    expect(fn.contains('title:'), isFalse);
    expect(fn.contains("'data-sources'"), isTrue);
    expect(css.contains('.pitch-dict-count[data-sources]::after'), isTrue);
  });

  test('zoom step relayouts dictionary columns against the layout width', () {
    expect(js.contains('function __fushiRelayoutPopupColumns()'), isTrue);
    final String cols = js.substring(
      js.indexOf('function effectiveDictColumns()'),
      js.indexOf('function __fushiDocumentZoom()'),
    );
    expect(
      cols.contains('__fushiViewportWidth() / __fushiDocumentZoom()'),
      isTrue,
    );
    final String webview = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();
    final int apply = webview.indexOf(
      'window.__fushiApplyPopupViewport = function(){',
    );
    expect(apply, isNonNegative);
    final String applyBody = webview.substring(
      apply,
      webview.indexOf('window.__fushiApplyPopupViewport();', apply),
    );
    expect(applyBody.contains('window.__fushiRelayoutPopupColumns'), isTrue);
  });

  test('collapsed dictionary rows are compact; press layer follows the card '
      'shape (user 10-09)', () {
    expect(
      ruleBody('html.fushi-m3e .glossary-group:not([open]) > .dict-label'),
      contains('min-height: 40px'),
      reason: '收起行收紧但点按区仍 ≥ 40',
    );
    expect(js.contains('function masonryCollapsedRowGap()'), isTrue);
    expect(
      js.contains('item.open === false ? masonryCollapsedRowGap() : gap'),
      isTrue,
    );
    final String label = ruleBody('html.fushi-m3e .dict-label');
    // summary 在扁平树里的父节点是 details 影子树的 slot，inherit 拿到 0（直角按压层）。
    expect(label.contains('border-radius: inherit'), isFalse);
    expect(label.contains('margin: 0 -16px'), isTrue);
    expect(css.contains('html.fushi-m3e .dict-label:active {'), isTrue);
    expect(
      css.contains(
        'html.fushi-m3e .glossary-section > .category-body > '
        '.glossary-group:first-child > .dict-label {',
      ),
      isTrue,
    );
  });
}
