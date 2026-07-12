import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// Niratan「制卡前调整·选择句子上下文」模态接线守卫。
///
/// 这是**独立于**旧内联步进器（`kSentenceContextPickerEnabled` 恒 false，永不渲染）的新
/// 特性：词条上的「调整上下文」按钮打开一个模态，展示前文/当前句(词高亮)/后文的真实文本，
/// 用前退/前加/后退/后加一句调整、确认制卡。数据经宿主只读回调 `onSentenceContextPreview`
/// （→ `sentenceContextPreview` JS handler）回传；调整仍走既有 `setSentenceContext`；确认
/// 制卡复用词条 mineButton。无头测试照不到真实 WebView，故用源码扫描守卫钉死每段接线。
void main() {
  String read(String relativePath) {
    final File file = File(relativePath);
    expect(file.existsSync(), isTrue, reason: 'missing $relativePath');
    return file.readAsStringSync();
  }

  test('webview registers sentenceContextPreview handler + injects flag/i18n',
      () {
    final String src =
        read('lib/src/pages/implementations/dictionary_popup_webview.dart');
    expect(src, contains("handlerName: 'sentenceContextPreview'"));
    expect(src, contains('widget.onSentenceContextPreview'));
    // 独立门控 flag，从宿主回调是否接入派生（不复用被砍掉的 sentenceDraftEnabled）。
    expect(
      src,
      contains(
          r'window.sentenceContextPreviewEnabled = ${widget.onSentenceContextPreview != null};'),
      reason: '按钮门控 flag 必须从 onSentenceContextPreview 是否接入派生',
    );
    // 模态文案注入（popup.js 无自带 i18n）。
    expect(src, contains('window.i18nCtx = {'));
    expect(src, contains('t.popup_ctx_modal_title'));
    expect(src, contains('t.popup_ctx_confirm'));
  });

  test('popup layer forwards onSentenceContextPreview to the webview', () {
    final String src =
        read('lib/src/pages/implementations/dictionary_popup_layer.dart');
    // 字段声明 + 构造透传 + 转发给 webview 三处都在。
    expect(
        src,
        contains(
            'final Future<Map<String, Object?>> Function()? onSentenceContextPreview;'));
    expect(src, contains('this.onSentenceContextPreview,'));
    expect(src, contains('onSentenceContextPreview: onSentenceContextPreview'));
  });

  test('base page wires preview only when the surface supports drafts', () {
    final String src = read('lib/src/pages/base_source_page.dart');
    expect(
      src,
      contains(
          'supportsSentenceDraft ? onSentenceContextPreviewFromDraft : null'),
    );
    // 默认返回空 Map（纯查词页不支持草稿）。
    expect(
      src,
      contains(
          'Future<Map<String, Object?>> onSentenceContextPreviewFromDraft() async =>'),
    );
  });

  test('reader overrides preview using the draft + cached word offset', () {
    final String src = readReaderPageSource();
    expect(
      src,
      contains(
          'Future<Map<String, Object?>> onSentenceContextPreviewFromDraft() async'),
    );
    expect(src, contains('buildSentenceContextPreview('));
    // 当前句取制卡同源（currentSentence），词偏移取查词缓存——保证预览=真实落卡。
    expect(src, contains('currentOffset: _cachedSentenceOffset'));
  });

  test('video + mixin wire the preview callback symmetrically', () {
    final String video =
        read('lib/src/pages/implementations/video_hibiki_page.dart');
    expect(video, contains('get onSentenceContextPreviewToDraft'));
    expect(video, contains('buildSentenceContextPreview('));
    final String mixin =
        read('lib/src/pages/implementations/dictionary_page_mixin.dart');
    expect(mixin,
        contains('onSentenceContextPreview: onSentenceContextPreviewToDraft'));
  });

  test('popup.js renders the adjust button + modal, gated on the new flag', () {
    final String js = read('assets/popup/popup.js');
    // 独立门控（不是被砍掉的 sentenceDraftEnabled）。
    expect(js, contains('if (window.sentenceContextPreviewEnabled)'));
    expect(js, contains('ctx-adjust-button'));
    expect(js, contains("setButtonIcon(adjustBtn, 'tune')"));
    // 模态本体 + 只读预览桥接。
    expect(js, contains('function openSentenceContextModal('));
    expect(js, contains("callHandler('sentenceContextPreview')"));
    expect(js, contains('sentence-context-modal'));
    // 前退/前加/后退/后加一句四向调整（复用镜像 + setSentenceContext）。
    expect(js, contains("makeAdjustBtn('prev', 'minus'"));
    expect(js, contains("makeAdjustBtn('next', 'plus'"));
    // 确认制卡复用词条 mineButton（不复制制卡逻辑）。
    expect(js, contains('mineButton.click();'));
  });

  test('modal highlights the looked-up word without innerHTML injection', () {
    final String js = read('assets/popup/popup.js');
    // 当前句高亮用 textNode + 高亮 span 构造，绝不 innerHTML 拼用户句子文本。
    expect(js, contains('function buildHighlightedCurrentText('));
    expect(js, contains('scm-hl'));
    expect(js, contains('document.createTextNode('));
  });

  test('popup.css ships the modal styles (theme-aware, token radius)', () {
    final String css = read('assets/popup/popup.css');
    expect(css, contains('.sentence-context-modal'));
    expect(css, contains('.scm-card'));
    expect(css, contains('.scm-box.scm-current'));
    expect(css, contains('.scm-hl'));
    // 卡片圆角走注入 token（与 kanji-card / global-lookup-sentence 一致，不硬编码）。
    expect(css, contains('var(--hibiki-radius-card'));
  });

  test('extension content.css mirrors carry the scoped modal selectors', () {
    for (final String root in const <String>[
      'assets/browser_extension',
      '../tools/browser-extension',
    ]) {
      final String content = read('$root/vendor/content.css');
      expect(content.contains('.sentence-context-modal'), isTrue,
          reason: '$root/vendor/content.css missing .sentence-context-modal '
              '(re-run generate-content-css.mjs)');
      expect(content.contains('.scm-hl'), isTrue,
          reason: '$root/vendor/content.css missing .scm-hl');
    }
  });

  test('BUG-763: 预览区能收缩+滚动（不被按钮区遮挡）', () {
    final String css = read('assets/popup/popup.css');
    // .scm-boxes 必须能收缩才会触发内部滚动（flex column 里默认 min-height:auto 拒收缩）。
    final int boxesStart = css.indexOf('.scm-boxes {');
    expect(boxesStart, greaterThanOrEqualTo(0));
    final String boxesRule =
        css.substring(boxesStart, css.indexOf('}', boxesStart));
    expect(boxesRule, contains('flex: 1 1 auto'),
        reason: '.scm-boxes 必须 flex:1 1 auto 吸收剩余空间');
    expect(boxesRule, contains('min-height: 0'),
        reason: '.scm-boxes 必须 min-height:0 放开收缩、激活 overflow-y 滚动');
    expect(boxesRule, contains('overflow-y: auto'));
    // .scm-card 必须 overflow:hidden 把内容夹在 max-height 内（否则撑破+溢出遮挡按钮）。
    final int cardStart = css.indexOf('.scm-card {');
    expect(cardStart, greaterThanOrEqualTo(0));
    final String cardRule =
        css.substring(cardStart, css.indexOf('}', cardStart));
    expect(cardRule, contains('overflow: hidden'),
        reason: '.scm-card 必须 overflow:hidden 夹住溢出内容');
  });

  test('BUG-764: 到上下文边界时禁用「+」（诚实反馈，不点了没反应）', () {
    final String js = read('assets/popup/popup.js');
    expect(js, contains('reqPrev'));
    expect(js, contains('reqNext'));
    expect(
        js,
        contains(
            'prevPlusBtn.disabled = reqPrev !== null && prev.length < reqPrev'));
    expect(
        js,
        contains(
            'nextPlusBtn.disabled = reqNext !== null && next.length < reqNext'));
  });
}
