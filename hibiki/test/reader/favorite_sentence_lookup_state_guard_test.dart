import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

/// BUG-455 守卫：阅读器查词弹窗顶栏「收藏句子」读 `currentMediaSource.currentSentence`，
/// 为空就误报「未选择句子」(no_sentence_selected)。tap 查词走 `_handleTextSelected` 已
/// 写穿 currentSentence（TODO-956 + resolveCurrentSentenceText 非空契约），但 **右键 /
/// 原生菜单「查词」** 两条路径直接调 `searchDictionaryResult`，绕过 `_handleTextSelected`，
/// 从不写 currentSentence —— 弹窗顶栏照样有收藏星，于是读到默认空串误报。
///
/// 这俩路径与右键「导出片段」(`_exportAudiobookClipFromSelection`) 同样从原生选区出发，
/// 必须共享同一套「原生选区 → 查词状态」解析（[_fillLookupStateFromNativeSelection]），
/// 把 currentSentence / cue / 选区缓存填成与 tap 路径等价，再弹查词。这份源码守卫锁死接线，
/// 防回归（整页 WebView 不便 mount，行为契约的纯函数部分由
/// reader_selection_scripts_test.dart 的 resolveCurrentSentenceText 覆盖）。
void main() {
  late String src;

  setUpAll(() => src = readReaderPageSource());

  test('存在共享 helper：原生选区写穿 currentSentence（非空契约）', () {
    final int defIdx = src
        .indexOf('ReaderSelectionData?> _fillLookupStateFromNativeSelection');
    expect(defIdx, greaterThan(0), reason: '必须有共享 helper 把原生选区解析为查词状态');
    // helper 体内必须写 currentSentence，并用 resolveCurrentSentenceText 保非空
    // （句子优先、派生不出退回选中词）。切到下一个方法定义为界，抗方法体增长漂移。
    final int endIdx =
        src.indexOf('Future<void> _exportAudiobookClipFromSelection()', defIdx);
    expect(endIdx, greaterThan(defIdx));
    final String body = src.substring(defIdx, endIdx);
    expect(body.contains('setCurrentSentence'), isTrue,
        reason: 'helper 必须写 currentSentence');
    expect(body.contains('resolveCurrentSentenceText'), isTrue,
        reason: 'helper 必须用非空契约（句子优先、退回选中词）');
  });

  test('Windows 右键「查词」先把原生选区写穿 currentSentence 再弹查词', () {
    final int caseIdx = src.indexOf("case 'search':");
    expect(caseIdx, greaterThan(0));
    final int endIdx = src.indexOf("case 'copy':", caseIdx);
    expect(endIdx, greaterThan(caseIdx));
    final String block = src.substring(caseIdx, endIdx);
    expect(block.contains('_fillLookupStateFromNativeSelection'), isTrue,
        reason: '右键查词必须先把原生选区解析进查词状态');
    expect(block.contains('searchDictionaryResult'), isTrue);
    // 句级解析失败（helper 返回 null）也要满足契约：退回 selectedText。
    expect(block.contains('setCurrentSentence'), isTrue,
        reason: '解析失败时退回 selectedText，仍保证 currentSentence 非空');
  });

  test('移动端原生菜单「查词」也经共享 helper 写穿 currentSentence', () {
    // ContextMenuItem(id:1, title: t.search) 的 action —— 切到下一个 ContextMenuItem。
    final int idx = src.indexOf('title: t.search,');
    expect(idx, greaterThan(0));
    final int nextItem = src.indexOf('ContextMenuItem(', idx);
    expect(nextItem, greaterThan(idx));
    final String block = src.substring(idx, nextItem);
    expect(block.contains('_fillLookupStateFromNativeSelection'), isTrue,
        reason: '移动端原生「查词」也必须把原生选区写进查词状态');
    expect(block.contains('searchDictionaryResult'), isTrue);
    expect(block.contains('setCurrentSentence'), isTrue,
        reason: '解析失败时退回选中文本，保证 currentSentence 非空');
  });

  test('导出片段路径复用同一 helper（无重复的原生选区解析）', () {
    // _exportAudiobookClipFromSelection 不再自己解析 native selection JSON，
    // 而是复用共享 helper —— 避免两套解析漂移。
    final int exportIdx =
        src.indexOf('Future<void> _exportAudiobookClipFromSelection()');
    expect(exportIdx, greaterThan(0));
    final int nextMethod = src.indexOf('Future<void> _shareReaderImage(');
    expect(nextMethod, greaterThan(exportIdx));
    final String body = src.substring(exportIdx, nextMethod);
    expect(body.contains('_fillLookupStateFromNativeSelection'), isTrue,
        reason: '导出路径必须复用共享 helper');
  });
}
