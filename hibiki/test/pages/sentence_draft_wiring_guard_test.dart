import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

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
    // TODO-426：选择器 UI 暂时砍掉——sentenceDraftEnabled 由 kSentenceContextPickerEnabled
    // （恒 false）与宿主回调一起门控；常量为 false 时弹窗不渲染选择器。回调链 / handler /
    // i18n 注入全保留，将来把常量改回 true 即恢复。
    // TODO-895：sentenceDraftEnabled 的 window.* 注入搬进单一真相源
    // popup_settings_injection.dart；webview 仍按同一谓词把它喂给共享 builder 的
    // PopupSettingsOptions，injection 体据该 option 注入标量。两段一起钉死等价接线。
    expect(
        src, contains('sentenceDraftEnabled: kSentenceContextPickerEnabled &&'),
        reason: 'webview must still gate the flag on the SAME predicate '
            '(kSentenceContextPickerEnabled && host callback present) and pass '
            'it into the shared popup-settings builder.');
    expect(src, contains('widget.onSetSentenceContext != null'));
    final String injection = readSource(
        'lib/src/pages/implementations/popup_settings_injection.dart');
    expect(
        injection,
        contains(
            r'window.sentenceDraftEnabled = ${options.sentenceDraftEnabled};'),
        reason:
            'the single source of truth must inject window.sentenceDraftEnabled '
            'from the option the webview passes.');
    // 上下文方向标签从宿主 i18n 注入（恢复用，保留）。
    expect(src, contains('window.i18nContextPrevLabel ='));
    expect(src, contains('window.i18nContextNextLabel ='));
  });

  test('sentence-context picker is temporarily disabled (TODO-426)', () {
    final String src = readSource(
        'lib/src/pages/implementations/dictionary_popup_webview.dart');
    // 用户要求暂时砍掉上下文选择器 UI；总开关常量恒 false，弹窗不渲染选择器。
    expect(src, contains('const bool kSentenceContextPickerEnabled = false;'));
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
    final String src = readReaderPageSource();
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
    final String src = readReaderPageSource();
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
    final String reader = readReaderPageSource();
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

  // ---- BUG-297：换词复用热槽 WebView 时重置 JS 镜像标量（视觉态归零）守卫 ----

  test('popup.js exposes resetSentenceContextMirror that zeros both scalars',
      () {
    final String js = readSource('assets/popup/popup.js');
    // 暴露一个把镜像标量归零的函数，供宿主换词注入时调用（不重载页面、不发宿主信号）。
    expect(js, contains('window.resetSentenceContextMirror = function() {'));
    // 函数体把上 N / 下 N 两个方向标量都置 0（撤掉任一行本守卫转红）。
    final int resetAt =
        js.indexOf('window.resetSentenceContextMirror = function() {');
    final String resetBody = js.substring(resetAt, resetAt + 200);
    expect(resetBody, contains('sentenceCtxPrev = 0;'));
    expect(resetBody, contains('sentenceCtxNext = 0;'));
  });

  test('webview resets the JS sentence-context mirror on a word switch', () {
    final String src = readSource(
        'lib/src/pages/implementations/dictionary_popup_webview.dart');
    // 换词注入路径（非 loadMore）必须在 renderPopup() 之前把 JS 镜像归零，否则热槽残留
    // 标量会把上一个词的「上 N / 下 N」按钮着色成已选、与已清的宿主草稿不一致（BUG-297 C-1）。
    expect(src, contains('window.resetSentenceContextMirror();'));
    final int resetCall = src.indexOf('window.resetSentenceContextMirror();');
    final int renderCall = src.indexOf('window.renderPopup();');
    expect(resetCall, greaterThanOrEqualTo(0));
    expect(renderCall, greaterThanOrEqualTo(0));
    // 归零调用排在 renderPopup() 之前，保证重建的选择器读到的是已归零的标量。
    expect(resetCall, lessThan(renderCall));
  });
}
