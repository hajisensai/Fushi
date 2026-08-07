import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-477 守卫（BUG-468 同根，弹窗 WebView 漏修）：查词弹窗在 Windows 上右键曾同时弹两个
/// 菜单——WebView2 原生菜单（返回/刷新/另存为/打印/更多工具）和 Hibiki 自定义的 Flutter 选区
/// 菜单（`_showWindowsContextMenu` 的搜索/复制）。`ContextMenu` 的
/// `hideDefaultSystemContextMenuItems: isWindowsPlatform` 是跨平台 API，在
/// flutter_inappwebview_windows fork 上并不接到原生菜单开关；fork 里唯一压制原生菜单的真值
/// 是 `InAppWebViewSettings.disableContextMenu`→`put_AreDefaultContextMenusEnabled`
/// （见 packages/flutter_inappwebview_windows/.../in_app_webview.cpp:231）。
///
/// 阅读器主 WebView 已由 BUG-468 修好，但弹窗是**独立的第二个 WebView**
/// （dictionary_popup_webview.dart），其 `initialSettings` 从未设 `disableContextMenu` →
/// 弹窗右键仍双菜单。故弹窗 WebView 的 `InAppWebViewSettings` 也必须把 `disableContextMenu`
/// 设成 `isWindowsPlatform`：Windows 关原生菜单只留 Flutter 菜单，移动端保持 false 不动原生
/// ContextMenu（查词项），防止回退成「双菜单」或「移动端丢菜单」。
void main() {
  String functionSource(String source, String start, String end) {
    final int startIndex = source.indexOf(start);
    expect(startIndex, isNonNegative, reason: 'missing start marker: $start');
    final int endIndex = source.indexOf(end, startIndex + start.length);
    expect(endIndex, isNonNegative, reason: 'missing end marker: $end');
    return source.substring(startIndex, endIndex);
  }

  test('popup WebView disables the native WebView2 context menu on Windows',
      () {
    final File file = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    );
    expect(file.existsSync(), isTrue,
        reason: 'popup webview source not found at ${file.path}');
    final String source = file.readAsStringSync();

    // Scope to the popup WebView's InAppWebViewSettings block (between the
    // settings ctor and the shouldInterceptRequest handler that follows it).
    final String settingsBlock = functionSource(
      source,
      'initialSettings: InAppWebViewSettings(',
      'shouldInterceptRequest:',
    );

    expect(
      RegExp(r'disableContextMenu:\s*isWindowsPlatform')
          .hasMatch(settingsBlock),
      isTrue,
      reason:
          'disableContextMenu must be isWindowsPlatform — the cross-platform '
          'ContextMenu.hideDefaultSystemContextMenuItems does NOT suppress the '
          'WebView2 native menu; only disableContextMenu does (BUG-477).',
    );

    // It must not be hard-on for every platform (that would kill the mobile
    // native ContextMenu and regress the search item on phones).
    expect(
      RegExp(r'disableContextMenu:\s*true').hasMatch(settingsBlock),
      isFalse,
      reason: 'disableContextMenu must be gated, not unconditionally true',
    );
  });
}
