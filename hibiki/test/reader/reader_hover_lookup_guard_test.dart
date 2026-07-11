import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// 悬停查词（hover）路径的连续化守卫（「按住 Shift 一路滑，弹窗跟着光标走」）。
///
/// 历史：TODO-851 曾给两个 hover 入口（`onShiftHover` / `onDismissBarrierHover`）
/// 都加 `if (isDictionaryShown) return;`「限一级弹窗」——弹窗一出就不再查新词，用户
/// 必须先关弹窗才能查下一个，无法像鼠标词典那样连续。现改为连续查词，本守卫锁住三条
/// 不变量，防退化：
///
/// 1. 两个 hover 入口调 `_selectTextAt` 仍必须带 `fromHover: true`——JS `selectText`
///    命中空白时不 fire `onTapEmpty`，避免悬停扫过正文空白反复 toggle 操作栏闪烁。
/// 2. 两个 hover 入口都**不再**有 `if (isDictionaryShown) return;` 门控：弹窗出现后
///    继续按住 Shift 滑动能换词（连续查词）。换词经 `_runLookupAndHighlight →
///    prunePopupStack(0)` 复用热槽无缝替换，不叠层不白屏（BUG-092/482）。
/// 3. JS `selectText` 的「同词短路」在 `fromHover` 下必须**先于** `clearSelection()`
///    直接 `return null`：连续 hover 命中同一个词时保留当前选区高亮与弹窗，不重复
///    fire `onTextSelected`（去重、不闪、不刷 FFI / 查词历史）；真点击仍保持 toggle。
///
/// 真点击路径（`onTap` 的 `_selectTextAt`）刻意**不**带 fromHover（默认 false），保留
/// 「点空白隐藏操作栏」旧行为；本守卫不强制它，只守 hover 两入口 + JS 同词短路。
///
/// 为什么用源码扫描而非 widget 行为测试：reader 页含真实 `InAppWebView` 平台视图，无法
/// 在 widget 测试里挂载真控制器触发 onShiftHover / onDismissBarrierHover 的 JS 回调
/// （照 reader_lookup_eval_guard_test.dart / BUG-005 成例）。
void main() {
  final String src = readReaderPageSource();

  group('hover lookup continuous guards', () {
    test('onShiftHover passes fromHover:true to _selectTextAt', () {
      final RegExp re = RegExp(
        r"handlerName:\s*'onShiftHover'[\s\S]*?"
        r'_selectTextAt\([^;]*fromHover:\s*true[^;]*\);',
      );
      expect(
        re.hasMatch(src),
        isTrue,
        reason: 'onShiftHover 必须以 fromHover:true 调 _selectTextAt。',
      );
    });

    test('onDismissBarrierHover passes fromHover:true to _selectTextAt', () {
      final RegExp re = RegExp(
        r'void onDismissBarrierHover\(PointerHoverEvent event\)[\s\S]*?'
        r'_selectTextAt\([^;]*fromHover:\s*true[^;]*\);',
      );
      expect(
        re.hasMatch(src),
        isTrue,
        reason: 'onDismissBarrierHover 必须以 fromHover:true 调 _selectTextAt。',
      );
    });

    test('onShiftHover no longer gates lookup behind isDictionaryShown', () {
      // 截取 onShiftHover callback「进入 → 首个 _selectTextAt」这一段，断言其中不再
      // 出现 isDictionaryShown 门控（连续查词：弹窗已出仍换词）。
      final Match? m = RegExp(
        r"handlerName:\s*'onShiftHover'[\s\S]*?_selectTextAt\(",
      ).firstMatch(src);
      expect(m, isNotNull, reason: 'onShiftHover handler 结构变了，守卫需同步更新。');
      // 检测门控**语句** `if (isDictionaryShown) return;`，而非这个词——注释里会提到
      // 「不再门控 isDictionaryShown」，用 contains(词) 会误命中散文。
      expect(
        RegExp(r'if\s*\(\s*isDictionaryShown\s*\)\s*return')
            .hasMatch(m!.group(0)!),
        isFalse,
        reason: 'onShiftHover 不应再有 if (isDictionaryShown) return 门控（连续查词已放开）。',
      );
    });

    test(
        'onDismissBarrierHover no longer gates lookup behind isDictionaryShown',
        () {
      final Match? m = RegExp(
        r'void onDismissBarrierHover\(PointerHoverEvent event\)[\s\S]*?'
        r'_selectTextAt\(',
      ).firstMatch(src);
      expect(m, isNotNull, reason: 'onDismissBarrierHover 结构变了，守卫需同步更新。');
      expect(
        RegExp(r'if\s*\(\s*isDictionaryShown\s*\)\s*return')
            .hasMatch(m!.group(0)!),
        isFalse,
        reason:
            'onDismissBarrierHover 不应再有 if (isDictionaryShown) return 门控（连续查词已放开）。',
      );
    });

    test(
        'JS selectText same-word short-circuit keeps selection under fromHover',
        () {
      final String js = File(
        'lib/src/reader/reader_selection_scripts.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      // 同词分支：命中的还是当前选区起点 → fromHover 时必须先 return null，且这个
      // return 出现在 clearSelection() 之前（保留高亮）。
      final RegExp re = RegExp(
        r'hit\.offset === this\.selection\.startOffset\)\s*\{'
        r'[\s\S]*?if\s*\(\s*fromHover\s*\)\s*\{\s*return null;\s*\}'
        r'[\s\S]*?this\.clearSelection\(\);',
      );
      expect(
        re.hasMatch(js),
        isTrue,
        reason: 'selectText 同词分支必须在 fromHover 下先 return null（保留选区），'
            '再对真点击走 clearSelection——否则连续 hover 会把当前词高亮抹掉/闪。',
      );
    });
  });
}
