import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/source_lookup_sentence.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 反馈 TnKWBi4C-9：查词页在释义里点词叠出的浮层制卡，Sentence 恒空。
///
/// 数据通路：selection.js `textSelected` 第 4 参（被点处那一句，JS 行为见
/// `test/dictionary/popup_selection_context_sentence_test.js`）→
/// `DictionaryPopupWebView.onTextSelected` → `pushNestedPopup(contextSentence:)` →
/// [DictionaryPopupEntry.contextSentence] → 查词页 / 独立查词窗制卡时
/// [withFallbackMiningSentence] 补 `{sentence}`。
///
/// 本文件锁 entry 上这份句子的生命周期：它只属于「这个词出自那一句」，与
/// [DictionaryPopupEntry.rubySpans] 同生同灭——原地跳到别的词（词头 / 链接 / 汉字）
/// 时清空，后退回原词时恢复，热槽复用 / 复位时替换。
DictionarySearchResult _result(String term) =>
    DictionarySearchResult(searchTerm: term, entries: const []);

void main() {
  test('beginTop / pushChild 把被点处那一句记在新 entry 上', () {
    final DictionaryPopupController c = DictionaryPopupController(
      lowMemory: false,
    );
    final DictionaryPopupEntry top = c.beginTop(
      term: '世間知らず',
      rect: Rect.zero,
      reuseWarmSlot: false,
      replaceStack: false,
      visible: true,
      contextSentence: 'まだ世間知らずの若者だ。',
    );
    expect(top.contextSentence, 'まだ世間知らずの若者だ。');

    final DictionaryPopupEntry child = c.pushChild(
      term: '若者',
      rect: Rect.zero,
      parentIndex: 0,
      visible: true,
      contextSentence: '元気な若者。',
    );
    expect(child.contextSentence, '元気な若者。');
  });

  test('热槽复用换词时替换句子，复位时清空', () {
    final DictionaryPopupController c = DictionaryPopupController(
      lowMemory: false,
    )..seedWarmSlot();
    final DictionaryPopupEntry first = c.beginTop(
      term: '世間知らず',
      rect: Rect.zero,
      reuseWarmSlot: true,
      replaceStack: false,
      visible: true,
      contextSentence: 'まだ世間知らずの若者だ。',
    );
    expect(first.isWarmSlot, isTrue);
    expect(first.contextSentence, 'まだ世間知らずの若者だ。');

    // 搜索框直接查词（不出自任何句子）复用同一热槽：旧句子不得残留。
    final DictionaryPopupEntry again = c.beginTop(
      term: '大人',
      rect: Rect.zero,
      reuseWarmSlot: true,
      replaceStack: false,
      visible: true,
    );
    expect(identical(again, first), isTrue);
    expect(again.contextSentence, isEmpty);

    c.beginTop(
      term: '世間知らず',
      rect: Rect.zero,
      reuseWarmSlot: true,
      replaceStack: false,
      visible: true,
      contextSentence: 'まだ世間知らずの若者だ。',
    );
    c.pruneToWarmSlot();
    expect(c.entries.single.contextSentence, isEmpty);
  });

  test('原地跳转清空句子，后退恢复、前进再清空', () {
    final DictionaryPopupController c = DictionaryPopupController(
      lowMemory: false,
    );
    final DictionaryPopupEntry e = c.beginTop(
      term: '世間知らず',
      rect: Rect.zero,
      reuseWarmSlot: false,
      replaceStack: false,
      visible: true,
      contextSentence: 'まだ世間知らずの若者だ。',
    );
    c.fillResult(e, result: _result('世間知らず'), allLoaded: true);

    // 点词头 / 链接跳到「世間」：这个词不出自那一句。
    expect(
      c.navigateInPlace(
        e,
        term: '世間',
        result: _result('世間'),
        allLoaded: true,
        scrollTop: 0,
      ),
      isTrue,
    );
    expect(e.searchTerm, '世間');
    expect(e.contextSentence, isEmpty);

    expect(c.goBack(e, scrollTop: 0), isTrue);
    expect(e.searchTerm, '世間知らず');
    expect(e.contextSentence, 'まだ世間知らずの若者だ。');

    expect(c.goForward(e, scrollTop: 0), isTrue);
    expect(e.contextSentence, isEmpty);
  });

  test('制卡补句：JS 没带句子时补上 entry 的句子，已带或为空时不动', () {
    expect(
      withFallbackMiningSentence(<String, String>{
        'expression': '世間知らず',
      }, 'まだ世間知らずの若者だ。')['sentence'],
      'まだ世間知らずの若者だ。',
    );
    expect(
      withFallbackMiningSentence(<String, String>{
        'expression': '世間知らず',
        'sentence': '別の句。',
      }, 'まだ世間知らずの若者だ。')['sentence'],
      '別の句。',
    );
    expect(
      withFallbackMiningSentence(<String, String>{
        'expression': '世間',
      }, '').containsKey('sentence'),
      isFalse,
    );
  });
}
