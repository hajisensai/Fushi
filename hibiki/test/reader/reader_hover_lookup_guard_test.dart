import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-851 守卫：悬停查词（hover）路径的两件事必须长在源码里，防退化。
///
/// 1. 两个 hover 入口（`onShiftHover` / `onDismissBarrierHover`）调 `_selectTextAt`
///    时必须带 `fromHover: true`——这样 JS `selectText` 命中空白时不再 fire
///    `onTapEmpty`，避免悬停扫过正文空白反复 toggle 操作栏导致闪烁。
/// 2. 两个 hover 入口都必须有 `if (isDictionaryShown) return;` 门控（限一级弹窗）：
///    已有可见弹窗时悬停不再叠新查词。只加一个入口会让另一路径漏网。
///
/// 真点击路径（`onTap` 的 `_selectTextAt`）刻意**不**带 fromHover（默认 false），
/// 保留「点空白隐藏操作栏」旧行为；本守卫不强制它，只守 hover 两入口。
///
/// 为什么用源码扫描而非 widget 行为测试：reader 页含真实 `InAppWebView` 平台视图，
/// 无法在 widget 测试里挂载真控制器触发 onShiftHover / onDismissBarrierHover 的 JS
/// 回调（照 reader_lookup_eval_guard_test.dart / BUG-005 成例）。
void main() {
  final String src = readReaderPageSource();

  group('TODO-851 hover lookup guards', () {
    test('onShiftHover passes fromHover:true to _selectTextAt', () {
      // onShiftHover handler 块内出现带 fromHover:true 的 _selectTextAt 调用。
      final RegExp re = RegExp(
        r"handlerName:\s*'onShiftHover'[\s\S]*?"
        r'_selectTextAt\([^;]*fromHover:\s*true[^;]*\);',
      );
      expect(
        re.hasMatch(src),
        isTrue,
        reason: 'onShiftHover 必须以 fromHover:true 调 _selectTextAt（TODO-851）。',
      );
    });

    test('onShiftHover gates lookup behind isDictionaryShown (one-layer)', () {
      final RegExp re = RegExp(
        r"handlerName:\s*'onShiftHover'[\s\S]*?"
        r'if\s*\(\s*isDictionaryShown\s*\)\s*return;[\s\S]*?'
        r'_selectTextAt\(',
      );
      expect(
        re.hasMatch(src),
        isTrue,
        reason: 'onShiftHover 必须有 if (isDictionaryShown) return; 限一级弹窗门控。',
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
        reason:
            'onDismissBarrierHover 必须以 fromHover:true 调 _selectTextAt（TODO-851）。',
      );
    });

    test('onDismissBarrierHover gates lookup behind isDictionaryShown', () {
      final RegExp re = RegExp(
        r'void onDismissBarrierHover\(PointerHoverEvent event\)[\s\S]*?'
        r'if\s*\(\s*isDictionaryShown\s*\)\s*return;[\s\S]*?'
        r'_selectTextAt\(',
      );
      expect(
        re.hasMatch(src),
        isTrue,
        reason:
            'onDismissBarrierHover 必须有 if (isDictionaryShown) return; 限一级弹窗门控。',
      );
    });
  });
}
