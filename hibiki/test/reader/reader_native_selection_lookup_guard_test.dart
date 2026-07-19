import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-927 源码守卫：阅读器桌面/细指针（鼠标）路径「原生选区残留卡住查词 + 右键闪退」
/// 三连锁的根因修复不得回退。
///
/// 为什么源码扫描而非行为测试：阅读器页含真实 `InAppWebView` 平台视图，widget 测试挂
/// 不上；pointerup/复制/右键都涉浏览器原生 `window.getSelection()` 与 WebView2 半销毁
/// 竞态，难确定性复现。故照 reader_desktop_copy_guard / reader_lookup_eval_guard 的
/// 静态断言范式钉死结构。
void main() {
  final File webview =
      File('lib/src/pages/implementations/reader_hibiki/webview.part.dart');
  final File chrome =
      File('lib/src/pages/implementations/reader_hibiki/chrome.part.dart');

  test('webview.part.dart：pointerup 早退只认 nativeMoved，不认残留原生选区', () {
    expect(webview.existsSync(), isTrue,
        reason: 'webview.part.dart 不存在，路径变了须更新守卫');
    final String src = webview.readAsStringSync().replaceAll('\r\n', '\n');

    // 根因①：早退条件必须是纯 nativeMoved。旧代码 `nativeMoved || hasNativeSelection`
    // 会让纯 tap 在残留原生选区时提前 return，跳过 selectText → 查词被吞死循环。
    expect(src, contains('if (nativeMoved) {'),
        reason: 'pointerup 原生选词分支早退必须只认 nativeMoved（本次手势真的拖动过）');
    expect(src.contains('nativeMoved || hasNativeSelection'), isFalse,
        reason: 'BUG-927 回退：残留原生选区不得再塞进 pointerup 早退条件，'
            '否则纯 tap 被吞、查词永远打不开');
    expect(src.contains('hasNativeSelection'), isFalse,
        reason: 'hasNativeSelection 已随修复删除；复活即回归风险');
  });

  test('chrome.part.dart：桌面右键复制后清原生选区 + 右键 eval 有 try/catch', () {
    expect(chrome.existsSync(), isTrue,
        reason: 'chrome.part.dart 不存在，路径变了须更新守卫');
    final String src = chrome.readAsStringSync().replaceAll('\r\n', '\n');

    // 根因②：桌面右键 copy 分支复制后必须清选区（与移动端拖选菜单 copy 对齐），
    // 否则残留原生蓝色选区喂给根因① 卡死查词。selectedText 是桌面路径专有变量。
    final int copyIdx =
        src.indexOf('Clipboard.setData(ClipboardData(text: selectedText))');
    expect(copyIdx, greaterThanOrEqualTo(0),
        reason: '缺桌面右键 copy 分支（Clipboard.setData(text: selectedText)）');
    final String copyRegion = src.substring(copyIdx, copyIdx + 700);
    expect(copyRegion, contains('_clearReaderAppSelection()'),
        reason: 'BUG-927 回退：桌面右键 copy 复制后必须 _clearReaderAppSelection() 清'
            '残留原生选区');

    // 根因③：_showReaderTextContextMenu 从 onSecondaryTapDown fire-and-forget 调，
    // 首个 evaluateJavascript 必须 try/catch（靠此 ErrorLogService tag 标识），否则
    // WebView 半销毁时抛 PlatformException 逃 zone → 记为 fatal → 右键闪退。
    expect(src, contains("'ReaderHibiki.showReaderTextContextMenu'"),
        reason: 'BUG-927 回退：右键菜单首个 evaluateJavascript 必须 try/catch，'
            '异常记 ErrorLogService 后 return，勿退回裸 eval 让异常逃 zone 闪退');
  });

  test('webview.part.dart：移动端原生 ContextMenu 复制后也清原生选区', () {
    final String src = webview.readAsStringSync().replaceAll('\r\n', '\n');
    // 移动端原生 ContextMenu copy（id:3）用局部 text 变量，复制后同样补清选区。
    final int copyIdx =
        src.indexOf('Clipboard.setData(ClipboardData(text: text))');
    expect(copyIdx, greaterThanOrEqualTo(0),
        reason: '缺移动端原生 ContextMenu copy 分支');
    final String copyRegion = src.substring(copyIdx, copyIdx + 700);
    expect(copyRegion, contains('_clearReaderAppSelection()'),
        reason: 'BUG-927 回退：移动端原生菜单 copy 复制后也要清选区，与桌面右键对齐');
  });
}
