import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-270 F/G「查词窗口多句合一制卡」(乙方案)：宿主接线守卫。
///
/// 弹窗「+句」按钮经 base_source_page → DictionaryPopupLayer → DictionaryPopupWebView
/// 的 `appendSentence` 处理器回到宿主。这里钉死三段接线 + reader 草稿消费 + 清空时机，
/// 防止任一环被悄悄断开（无头测试照不到真实 WebView，故用源码扫描守卫）。
void main() {
  String readSource(String relativePath) {
    final File file = File(relativePath);
    expect(file.existsSync(), isTrue, reason: 'missing $relativePath');
    return file.readAsStringSync();
  }

  test('webview registers the generic appendSentence JS handler', () {
    final String src = readSource(
        'lib/src/pages/implementations/dictionary_popup_webview.dart');
    expect(src, contains("handlerName: 'appendSentence'"));
    expect(src, contains('onAppendSentence'));
    expect(src, contains('window.sentenceDraftEnabled ='));
  });

  test('popup layer forwards onAppendSentence to the webview', () {
    final String src =
        readSource('lib/src/pages/implementations/dictionary_popup_layer.dart');
    expect(src, contains('onAppendSentence: onAppendSentence'));
  });

  test('base page wires onAppendSentence only when the surface supports drafts',
      () {
    final String src = readSource('lib/src/pages/base_source_page.dart');
    expect(src, contains('supportsSentenceDraft'));
    expect(src, contains('onAppendSentenceToDraft'));
    expect(
      src,
      contains('supportsSentenceDraft ? onAppendSentenceToDraft : null'),
    );
    // Default: no draft support (pure dictionary / video E before wiring).
    expect(src, contains('bool get supportsSentenceDraft => false;'));
  });

  test('reader opts into drafts, accumulates, and merges at mine time', () {
    final String src =
        readSource('lib/src/pages/implementations/reader_hibiki_page.dart');
    // Opts in.
    expect(src, contains('bool get supportsSentenceDraft => true;'));
    // Append pushes current sentence + its audio range into the draft.
    expect(src, contains('Future<int> onAppendSentenceToDraft() async'));
    expect(src, contains('_miningDraft.append(MiningDraftSentence('));
    expect(src, contains('audioRange: _currentSentenceAudioRange()'));
    // Mine composes draft + current for both text and audio range.
    expect(src, contains('_miningDraft.composeText(currentSentence)'));
    expect(src, contains('_miningDraft.composeAudioRange(currentRange)'));
  });

  test('reader clears the draft after a successful mine and on dismiss', () {
    final String src =
        readSource('lib/src/pages/implementations/reader_hibiki_page.dart');
    expect(
        '_miningDraft.clear()'.allMatches(src).length, greaterThanOrEqualTo(2));
  });
}
