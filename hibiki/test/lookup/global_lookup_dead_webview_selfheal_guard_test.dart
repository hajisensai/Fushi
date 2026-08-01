import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-693 / TODO-1268 — 覆盖窗 WebView2 死亡自愈契约（源码扫描守卫）。
///
/// 真机根因：app 外全局查词覆盖窗（`windows/runner/global_lookup_window.cpp`）
/// 的 WebView2 在启动时预热一次、随后整个会话常驻（查词间只 SW_HIDE）。其进程树
/// 在会话中途死亡（WebView2 运行时后台更新 / GPU 重置 / OOM / 渲染崩溃）后，
/// COM 代理仍在、`webview_ready_` 恒 true，`RenderJson` 把渲染脚本盲打进死页：
/// host 永远不再回 `overlaySize`/`popupRendered`，Dart 只能靠 READY-SAFETY 兜底
/// 翻出**空白窗**，直到重启 app——这正是 TODO-1268 用户四次复诉「点击悬浮字幕
/// 文字没有出现查词窗口」的真机日志签名（`lookupText → searched → showAt →
/// reveal: READY-SAFETY`，零 host 消息；同会话早先的热键查词正常）。
///
/// 修复契约（离屏故障注入已验证，见
/// `integration_test/floating_lyric_tap_lookup_itest.dart` 阶段 2）：
/// 1. `RenderJson` 不得盲发 `ExecuteScript(...)`：必须带 completion handler 检查
///    异步 HRESULT，且检查同步 HRESULT，任一 FAILED 即走 `RecoverDeadWebView`
///    （webview 级 `ProcessFailed` 事件对 force-kill 实测**不触发**，不能只靠它）。
/// 2. `RecoverDeadWebView`：缓存 replay 脚本进 `pending_json_`、置
///    `webview_ready_ = false`、以 `recovering_` 防重入、释放
///    controller_/webview_/env_ 后 `EnsureWebView()` 原地重建。
/// 3. `NavigationCompleted` 重臂 `webview_ready_`、清 `recovering_` 并 flush
///    `pending_json_`——发现死面的那一次点词也能补渲染出真词卡。
/// 4. `add_ProcessFailed` 仍注册为纵深防御，三个基础 kind 走同一重建路径。
///
/// 覆盖窗真弹出依赖 native WebView2，headless 测不了，故用源码扫描钉住契约；
/// 端到端行为由上述离屏集成测试（含真杀进程注入）验收。
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  late String cpp;
  late String hdr;
  setUpAll(() {
    cpp = read('windows/runner/global_lookup_window.cpp');
    hdr = read('windows/runner/global_lookup_window.h');
  });

  /// 取 `webview_->add_XXX(...)` 这一次事件注册调用的完整切片（圆括号配对）。
  ///
  /// 旧写法是 `cpp.substring(at, at + 1200/1600)` 的定长窗口：NavigationCompleted
  /// 那处实测调用只有 699 字符，窗口越界 501 字符读进下面那段讲 RecoverDeadWebView
  /// 的长注释（注释里同样出现 `webview_ready_` / `pending_json_` 字样，离把断言喂成
  /// 假绿只差几十个字符）；ProcessFailed 那处调用 1500 字符、窗口 1600，末尾的
  /// `pending_json_` 断言只剩 ~170 字符余量，handler 里多写四行就凭空变红。
  ///
  /// 锚点取 `(` 之后第一个字符，[enclosingCall] 于是返回这层调用本身。配对跑在掩码串
  /// 上，注释与字符串里的括号不参与——本文件（`global_lookup_window.cpp`）已确认没有
  /// C++ 原始字符串 `R"(...)"`（掩码器按 Dart 词法解析，认不出 `R"delim(` 定界符）。
  String registrationCall(String src, String anchor) {
    final int at = src.indexOf(anchor);
    expect(at, greaterThanOrEqualTo(0), reason: '必须存在：$anchor');
    return enclosingCall(src, at + anchor.length).text;
  }

  test('RenderJson 不盲发 ExecuteScript：同步+异步 HRESULT 都要检查并触发自愈', () {
    // 函数体用花括号配对取（methodBody 对 C++ 同样适用），不再是「到下一个左对齐 `}`」。
    final String body = methodBody(cpp, 'void GlobalLookupWindow::RenderJson(');
    expect(
        body.contains(
            'ExecuteScript(Utf8ToWide(full_script).c_str(), nullptr)'),
        isFalse,
        reason: 'BUG-693：不得把渲染脚本盲打进可能已死的 WebView2（nullptr '
            'completion handler 意味着死面失败被吞、覆盖窗空白到重启）');
    expect(body, contains('ICoreWebView2ExecuteScriptCompletedHandler'),
        reason: '必须带 completion handler 检查异步 HRESULT');
    expect(body, contains('FAILED(error_code)'),
        reason: '异步 HRESULT FAILED 必须被检查');
    expect(body, contains('FAILED(sync_hr)'),
        reason: '同步 HRESULT FAILED 必须被检查');
    expect(
        'RecoverDeadWebView'.allMatches(body).length, greaterThanOrEqualTo(2),
        reason: '同步与异步失败两条路径都必须走 RecoverDeadWebView 自愈');
    expect(body, contains('recovering_'),
        reason: '重建进行中必须缓存脚本而不是执行（recovering_ 门控）');
  });

  test('RecoverDeadWebView：缓存 replay、清 ready、防重入、原地重建', () {
    final String body =
        methodBody(cpp, 'void GlobalLookupWindow::RecoverDeadWebView(');
    expect(body, contains('pending_json_ = replay_script'),
        reason: '发现死面的那次渲染脚本必须缓存等重建后 replay');
    expect(body, contains('webview_ready_ = false'),
        reason: '必须立刻打断「dead-but-ready」状态');
    expect(body, contains('if (recovering_)'),
        reason: '失败风暴/事件竞态只允许一次重建（防重入守卫）');
    expect(body, contains('EnsureWebView()'),
        reason: '必须原地重建 WebView2（同一 hwnd_）');
    for (final String member in <String>[
      'controller_ = nullptr',
      'webview_ = nullptr',
      'env_ = nullptr',
    ]) {
      expect(body, contains(member), reason: '死进程树下的 COM 代理必须先释放再重建：$member');
    }
  });

  test('NavigationCompleted 重臂 ready、清 recovering_ 并 flush pending', () {
    final String seg = registrationCall(cpp, 'add_NavigationCompleted(');
    expect(seg, contains('webview_ready_ = true'));
    expect(seg, contains('recovering_ = false'),
        reason: '重建完成必须解除 recovering_ 门控，否则后续渲染永远只缓存');
    expect(seg, contains('pending_json_'), reason: '重建完成必须 replay 缓存的渲染脚本');
  });

  test('ProcessFailed 仍注册为纵深防御并走同一自愈路径', () {
    expect(cpp, contains('add_ProcessFailed'),
        reason: '事件级检测保留（纵深防御；force-kill 下可能不触发，'
            '但真实崩溃/无响应场景仍有价值）');
    final String seg = registrationCall(cpp, 'add_ProcessFailed(');
    for (final String kind in <String>[
      'COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED',
      'COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_EXITED',
      'COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_UNRESPONSIVE',
    ]) {
      expect(seg, contains(kind), reason: '三个基础失败 kind 都要处理：$kind');
    }
    expect(seg, contains('RecoverDeadWebView'),
        reason: '事件路径与 ExecuteScript 活性检测共用同一重建入口');
  });

  test('头文件声明 RecoverDeadWebView 与 recovering_', () {
    expect(hdr, contains('void RecoverDeadWebView(const std::string&'));
    expect(hdr, contains('bool recovering_ = false;'));
  });
}
