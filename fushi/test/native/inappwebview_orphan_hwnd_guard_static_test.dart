import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-904 native 源码守卫：WebView2 实例异步创建失败时孤儿 hwnd 必须被回收。
///
/// 根因：`in_app_webview_manager.cpp` 的 `createInAppWebView` 在 `:138 CreateWindowEx`
/// 先建一个 hwnd，再异步调 `createInAppWebViewEnv`。成功回调把 hwnd 接管进
/// InAppWebView（其析构 `~InAppWebView` 调 `DestroyWindow`）；但**异步失败回调**
/// （`else` 分支，`result_->Error("0", "Cannot create the InAppWebView instance!")`）
/// 从不构造 InAppWebView/CustomPlatformView → 该 hwnd 无人 `DestroyWindow` → 反复
/// 开关书时孤儿 hwnd 单调累积、耗尽资源 → 之后稳定抛 904（死亡螺旋）。
///
/// 修复：在该失败 `else` 分支就地 `DestroyWindow(hwnd)` 回收。
///
/// 守卫断言：失败分支（含 `"Cannot create the InAppWebView instance!"` 的 else）里
/// 出现 `DestroyWindow`。删掉即红。源码语料层是该 native 改动最强可落地的回归网
/// （ctest 需完整 WebView2 + 真窗口环境，CI 无法跑）。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('createInAppWebView 异步失败分支回收孤儿 hwnd（DestroyWindow）', () {
    final String src = read(
        '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.cpp');

    // 904 失败文案出现两次：① 同步早退（!plugin，从未建 hwnd，no-op）；
    // ② 异步回调 else 分支（hwnd 已在 :138 建好但未接管 → 真正的孤儿泄漏点）。
    // 取「最后一个」失败文案 = 异步 else 分支，断言其前回收 hwnd。
    const String failLine =
        'result_->Error("0", "Cannot create the InAppWebView instance!");';
    final int asyncFailIdx = src.lastIndexOf(failLine);
    expect(asyncFailIdx, greaterThan(-1),
        reason: '应保留 904 失败文案（异步 else 分支抛出点）');
    // 确认确实有两处（同步 + 异步），否则定位逻辑失效需重审。
    expect(src.indexOf(failLine), lessThan(asyncFailIdx),
        reason: '应同时存在同步早退与异步失败两处 904 文案');

    // 异步 else 分支内必须先 DestroyWindow 回收 :138 建的孤儿 hwnd。
    final int windowStart = (asyncFailIdx - 400).clamp(0, asyncFailIdx);
    final String elseBlock = src.substring(windowStart, asyncFailIdx);
    expect(elseBlock.contains('DestroyWindow'), isTrue,
        reason: '异步失败 else 分支必须 DestroyWindow 回收 :138 建的孤儿 hwnd');
    expect(elseBlock.contains('hwnd'), isTrue,
        reason: 'DestroyWindow 的目标必须是上文建的 hwnd');
  });
}
