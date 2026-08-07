import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG — 覆盖窗 HWND 死亡自愈契约（源码扫描守卫）。
///
/// 真机根因（与 [global_lookup_dead_webview_selfheal_guard_test] 的死 WebView2
/// 是姊妹，但这里死的是 **Win32 窗口本身**）：app 外全局查词/剪贴板面板覆盖窗
/// （`windows/runner/global_lookup_window.cpp`）的 HWND 被外部拆掉（WebView2
/// 运行时后台更新/崩溃、owner 主窗 teardown、任何外部 `DestroyWindow`）后，
/// 成员 `hwnd_` 只在析构里才置 null——于是变成**悬垂的非 null 句柄**：
/// - `ShowAt` 的旧 `if (hwnd_ == nullptr)` 守卫为假 → 走 else 分支对死句柄
///   `SetWindowPos`（静默失败）→ **永不 `CreateWindowExW` 重建**；
/// - `IsShowing()` 的 `hwnd_ != nullptr` 被悬垂/回收句柄骗过 → Dart 复检跳过重建、
///   往不存在的窗口渲染并记 `panel: updated`/`reveal(box)` 成功。
///
/// 用户症状：手动关闭第一个弹窗/面板后，第二个**弹不出来**，Dart 日志却一切正常，
/// 且**不重启 app 永远回不来**（实测探测 0 个 `FushiGlobalLookupWindow` 窗口，
/// 但 Dart 持续记 reveal 成功；重启后恢复）。
///
/// 修复契约：
/// 1. `OwnsLiveWindow()`：`hwnd_ != nullptr && IsWindow(hwnd_)`（死句柄 `IsWindow`
///    返 false）**且** `GetWindowLongPtr(hwnd_, GWLP_USERDATA) == this`（句柄被
///    Windows 回收给别的窗时 USERDATA≠this，双重防漏）。
/// 2. `ForgetDeadWindow()`：句柄非我方活窗时清 `hwnd_` + 释放 controller_/webview_/
///    env_ 死代理 + 复位 webview_ready_/visible_/revealed_，让下一次 ShowAt/
///    PrewarmWebView 从零重建。
/// 3. `ShowAt` 与 `PrewarmWebView` 在创建/幂等守卫前必须先 `ForgetDeadWindow()`。
/// 4. `IsShowing()` 用 `OwnsLiveWindow()` 而不是裸 `hwnd_ != nullptr`。
///
/// 覆盖窗真弹出依赖 native WebView2，headless 测不了，故用源码扫描钉住契约。
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  late String cpp;
  late String hdr;
  setUpAll(() {
    cpp = read('windows/runner/global_lookup_window.cpp');
    hdr = read('windows/runner/global_lookup_window.h');
  });

  /// 抽出一个顶层函数体（从签名行到下一个左对齐 `}`）。
  String functionBody(String src, String signature) {
    final int at = src.indexOf(signature);
    expect(at, greaterThanOrEqualTo(0), reason: '必须存在：$signature');
    final int end = src.indexOf('\n}', at);
    expect(end, greaterThan(at));
    return src.substring(at, end);
  }

  test('OwnsLiveWindow：IsWindow + GWLP_USERDATA==this 双重校验', () {
    final String body =
        functionBody(cpp, 'bool GlobalLookupWindow::OwnsLiveWindow()');
    expect(body, contains('IsWindow(hwnd_)'),
        reason: '死句柄必须被 IsWindow() 拒绝（否则悬垂句柄冒充活窗）');
    expect(body, contains('GetWindowLongPtr(hwnd_, GWLP_USERDATA)'),
        reason: 'HWND 会被 Windows 回收给别的窗，必须核对 USERDATA 仍指向本实例');
    expect(body, contains('== this'), reason: 'USERDATA 必须等于 this 才算「我方」活窗');
  });

  test('ForgetDeadWindow：非活窗则清 hwnd_ + 释放死 COM 代理 + 复位状态', () {
    final String body =
        functionBody(cpp, 'void GlobalLookupWindow::ForgetDeadWindow()');
    expect(body, contains('OwnsLiveWindow()'),
        reason: '判据必须复用 OwnsLiveWindow（单一真值源）');
    expect(body, contains('hwnd_ = nullptr'),
        reason: '悬垂句柄必须清空，否则 ShowAt 仍走 SetWindowPos 死句柄分支');
    for (final String member in <String>[
      'controller_ = nullptr',
      'webview_ = nullptr',
      'env_ = nullptr',
    ]) {
      expect(body, contains(member), reason: '死进程树下的 COM 代理必须释放：$member');
    }
    expect(body, contains('webview_ready_ = false'),
        reason: '必须打断「dead-but-ready」状态，重建后由 NavigationCompleted 重臂');
    expect(body, contains('error_cb_'), reason: '发现死窗必须记进设备日志，让销毁者可诊断，而不是静默重建');
  });

  test('ShowAt 在创建守卫前先 ForgetDeadWindow（悬垂句柄触发真重建）', () {
    final String body = functionBody(cpp, 'bool GlobalLookupWindow::ShowAt(');
    final int forget = body.indexOf('ForgetDeadWindow()');
    final int guard = body.indexOf('if (hwnd_ == nullptr)');
    expect(forget, greaterThanOrEqualTo(0), reason: 'ShowAt 必须先丢弃死句柄');
    expect(guard, greaterThan(forget),
        reason: 'ForgetDeadWindow 必须在 `if (hwnd_ == nullptr)` 重建守卫之前，'
            '否则死句柄仍走 else 的 SetWindowPos 分支、永不 CreateWindowExW');
  });

  test('PrewarmWebView 幂等守卫前先 ForgetDeadWindow', () {
    final String body =
        functionBody(cpp, 'void GlobalLookupWindow::PrewarmWebView(');
    final int forget = body.indexOf('ForgetDeadWindow()');
    final int guard = body.indexOf('if (hwnd_ != nullptr)');
    expect(forget, greaterThanOrEqualTo(0), reason: '死掉的预热窗必须被重建');
    expect(guard, greaterThan(forget),
        reason: 'ForgetDeadWindow 必须在「已预热就返回」守卫之前');
  });

  test('IsShowing 用 OwnsLiveWindow 而非裸 hwnd_ != nullptr', () {
    final String body =
        functionBody(cpp, 'bool GlobalLookupWindow::IsShowing()');
    expect(body, contains('OwnsLiveWindow()'),
        reason: '否则悬垂/回收句柄让 IsShowing 报 true，Dart 跳过重建');
    expect(body.contains('hwnd_ != nullptr && IsWindowVisible'), isFalse,
        reason: '不得退回裸 hwnd_ != nullptr 判据（BUG 回归signature）');
  });

  test('头文件声明 OwnsLiveWindow 与 ForgetDeadWindow', () {
    expect(hdr, contains('bool OwnsLiveWindow() const;'));
    expect(hdr, contains('void ForgetDeadWindow();'));
  });
}
