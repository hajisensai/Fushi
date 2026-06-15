import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-393「查词窗口句子上下文制卡」(取代 TODO-382 单按钮逐句追加)：宿主接线守卫。
///
/// 弹窗「上 N 句 / 下 N 句」上下文选择器经 base_source_page → DictionaryPopupLayer →
/// DictionaryPopupWebView 的 `setSentenceContext` 处理器回到宿主。这里钉死三段接线 +
/// reader 上下文消费 + 换词/制卡清空时机，防止任一环被悄悄断开（无头测试照不到真实
/// WebView，故用源码扫描守卫）。
void main() {
  String readSource(String relativePath) {
    final File file = File(relativePath);
    expect(file.existsSync(), isTrue, reason: 'missing $relativePath');
    return file.readAsStringSync();
  }

  test('webview registers the generic setSentenceContext JS handler', () {
    final String src = readSource(
        'lib/src/pages/implementations/dictionary_popup_webview.dart');
    expect(src, contains("handlerName: 'setSentenceContext'"));
    expect(src, contains('onSetSentenceContext'));
    // 选择器只在宿主接受 setSentenceContext 时渲染。
    expect(
        src,
        contains(
            r'window.sentenceDraftEnabled = ${widget.onSetSentenceContext != null}'));
    // 上下文方向标签从宿主 i18n 注入。
    expect(src, contains('window.i18nContextPrevLabel ='));
    expect(src, contains('window.i18nContextNextLabel ='));
  });

  test('popup layer forwards onSetSentenceContext to the webview', () {
    final String src =
        readSource('lib/src/pages/implementations/dictionary_popup_layer.dart');
    expect(src, contains('onSetSentenceContext: onSetSentenceContext'));
  });

  test(
      'base page wires onSetSentenceContext only when the surface supports drafts',
      () {
    final String src = readSource('lib/src/pages/base_source_page.dart');
    expect(src, contains('supportsSentenceDraft'));
    expect(src, contains('onSetSentenceContextToDraft'));
    expect(
      src,
      contains('supportsSentenceDraft ? onSetSentenceContextToDraft : null'),
    );
    // Default: no draft support (pure dictionary / home lookup).
    expect(src, contains('bool get supportsSentenceDraft => false;'));
    expect(
      src,
      contains(
          'Future<int> onSetSentenceContextToDraft(int prevCount, int nextCount) async =>'),
    );
  });

  test(
      'reader opts into drafts, sets directional context, and merges at mine time',
      () {
    final String src =
        readSource('lib/src/pages/implementations/reader_hibiki_page.dart');
    // Opts in.
    expect(src, contains('bool get supportsSentenceDraft => true;'));
    // Set-context fetches the surrounding sentences and sets the draft as a whole.
    expect(
      src,
      contains(
          'Future<int> onSetSentenceContextToDraft(int prevCount, int nextCount) async'),
    );
    expect(src, contains('surroundingSentencesInvocation('));
    expect(src, contains('_miningDraft.setContext('));
    // Mine composes draft + current for both text and audio range.
    expect(src, contains('_miningDraft.composeText(currentSentence)'));
    expect(src, contains('_miningDraft.composeAudioRange(currentRange)'));
  });

  test('reader clears the draft on a new lookup, after mine, and on dismiss',
      () {
    final String src =
        readSource('lib/src/pages/implementations/reader_hibiki_page.dart');
    // >=3: new lookup (_handleTextSelected), mine success, onAllPopupsDismissed.
    expect(
        '_miningDraft.clear()'.allMatches(src).length, greaterThanOrEqualTo(3));
  });

  // ---- 可撤销：清空草稿（undo）链路守卫 ----

  test('webview still registers the clearSentenceDraft JS handler', () {
    final String src = readSource(
        'lib/src/pages/implementations/dictionary_popup_webview.dart');
    expect(src, contains("handlerName: 'clearSentenceDraft'"));
    expect(src, contains('onClearSentenceDraft'));
    expect(src, contains('window.i18nClearSentenceDraftTooltip ='));
  });

  test('popup layer forwards onClearSentenceDraft to the webview', () {
    final String src =
        readSource('lib/src/pages/implementations/dictionary_popup_layer.dart');
    expect(src, contains('onClearSentenceDraft: onClearSentenceDraft'));
  });

  test('reader and video override clear to empty their draft', () {
    final String reader =
        readSource('lib/src/pages/implementations/reader_hibiki_page.dart');
    expect(reader, contains('Future<int> onClearSentenceDraftToDraft() async'));
    final String video =
        readSource('lib/src/pages/implementations/video_hibiki_page.dart');
    expect(video,
        contains('Future<int> Function()? get onClearSentenceDraftToDraft'));
    final String mixin =
        readSource('lib/src/pages/implementations/dictionary_page_mixin.dart');
    expect(
        mixin, contains('onClearSentenceDraft: onClearSentenceDraftToDraft'));
  });

  test('popup.js renders the context picker and the clear button', () {
    final String js = readSource('assets/popup/popup.js');
    // Directional context picker (上 N / 下 N) wired to setSentenceContext.
    expect(js, contains('sentence-context-picker'));
    expect(js, contains('buildSentenceContextPicker'));
    expect(js, contains("callHandler(\n            'setSentenceContext'"));
    expect(js, contains('refreshAllSentenceContextPickers'));
    // Both directions are mirrored as scalars (not free accumulation).
    expect(js, contains('let sentenceCtxPrev = 0;'));
    expect(js, contains('let sentenceCtxNext = 0;'));
    // A dedicated, visible undo/clear control wired to clearSentenceDraft.
    expect(js, contains('clear-draft-button'));
    expect(js, contains("callHandler('clearSentenceDraft')"));
    // Clear button is hidden when no context is selected.
    expect(js, contains('(sentenceCtxPrev + sentenceCtxNext) <= 0'));
  });
}
