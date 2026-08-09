import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-802 守卫：查词弹窗里选中词典正文后，右键「复制/搜索」曾完全无效。两层根因：
///
///   1. 弹窗把每张词条卡渲染成独立**同源** iframe（global_lookup_host.js），用户拖选的
///      原生文本落在 CHILD iframe 的 `window.getSelection()` 里，顶层文档选区永远是空。
///   2. 桌面 flutter_inappwebview_windows fork **根本没实现 `getSelectedText`**
///      （webview_channel_delegate.cpp 无该 method 分支 → `NotImplemented()` → Dart 侧
///      返回 null）；移动端 `getSelectedText` 也只读顶层文档。
///
///   两条 contextMenu 路径（非 Windows 的 `menuItems` 查词项 + Windows 的
///   `_showWindowsContextMenu` 复制/搜索）都靠 `getSelectedText()` 拿选区 → 空串 → 早退 →
///   无效。修复改用穿透同源 iframe 的 `evaluateJavascript`（[_selectedTextAcrossFrames]）。
///
///   本守卫锁死：① 弹窗源码不得再用 `getSelectedText`（否则回退成 Windows 恒空 + iframe
///   盲）；② 必须存在遍历 iframe 的选区读取 JS（含 `iframe` 与 `contentWindow` 递归）。
void main() {
  final File file = File(
    'lib/src/pages/implementations/dictionary_popup_webview.dart',
  );

  test('popup copy/search must not read selection via getSelectedText', () {
    expect(file.existsSync(), isTrue,
        reason: 'popup webview source not found at ${file.path}');
    final String code = maskComments(file.readAsStringSync());

    // getSelectedText 在桌面 fork 未实现（恒 null）且天然只读顶层文档，取不到 iframe 内
    // 选区。弹窗任何选区读取都不许再走它，否则复制/搜索回归无效。
    expect(
      code.contains('getSelectedText'),
      isFalse,
      reason: '弹窗不得用 getSelectedText 读选区：桌面 fork 未实现（NotImplemented→null），'
          '且只读顶层文档取不到子 iframe 选区。改用 _selectedTextAcrossFrames（BUG-802）。',
    );
  });

  test('popup exposes an iframe-piercing selection reader (BUG-802)', () {
    final String source = file.readAsStringSync();

    // 穿透 iframe 的选区读取 helper 与其 JS 必须存在。
    expect(
      source.contains('_selectedTextAcrossFrames'),
      isTrue,
      reason: '缺少穿透 iframe 的选区读取 helper _selectedTextAcrossFrames',
    );
    expect(
      source.contains('_selectedTextAcrossFramesJs'),
      isTrue,
      reason: '缺少穿透 iframe 的选区读取 JS 常量 _selectedTextAcrossFramesJs',
    );

    // JS 必须真正递归遍历子 frame（读 contentWindow / 查 iframe），否则只读顶层文档
    // 仍取不到词条卡 iframe 内的选区。
    final int jsStart = source.indexOf('_selectedTextAcrossFramesJs');
    expect(jsStart, isNonNegative);
    final int jsEnd =
        source.indexOf("'''", source.indexOf("r'''", jsStart) + 4);
    expect(jsEnd, isNonNegative, reason: 'selection JS 常量未正常闭合');
    final String js = source.substring(jsStart, jsEnd);
    expect(js.contains('iframe'), isTrue, reason: '选区 JS 必须查询 iframe 子 frame');
    expect(js.contains('contentWindow'), isTrue,
        reason: '选区 JS 必须递归读 iframe.contentWindow 的选区');
    expect(js.contains('getSelection'), isTrue,
        reason: '选区 JS 必须读 window.getSelection()');
  });
}
