## BUG-1372 · Android appSmoke：预热 headless WebView 永不销毁，renderer 被 OOM kill 后连坐杀整个 app 进程
- **报告**：2026-08-02（CI：develop `Build and Test Android / macOS / Linux / Windows` 的 android job，TODO-2560）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/main.dart:376`（旧实现：`HeadlessInAppWebView` 的 `dispose()` 只挂在 `onLoadStop` 这一条成功回调上）
  - 现象不是断言失败，是 **app 进程被杀**：`flutter drive` 侧 `DriverError: ... ext.flutter.driver: (112) Service has disappeared`；app 侧
    `W/cr_ChildProcessConn: onServiceDisconnected (crash or killed by oom): pid=4440`
    → `F/chromium: [FATAL:crashpad_client_linux.cc(745)] Render process (4440)'s crash wasn't handled by all associated webviews, triggering application crash.`
    → `F/libc: Fatal signal 5 (SIGTRAP) ... pid 3331 (p.hibiki.reader)`。
  - 4/4 次 CI 复现同一签名（run 30688292397 / 30696409627 / 30708854995 / 30710399089），且 4 次里
    `[Hibiki] WebView engine pre-warmed` 一次都没打印过 —— 证明 `onLoadStop` 从未到达、`dispose()` 从未执行，
    那个 headless WebView 和它的 chromium renderer 子进程一直活到进程被杀。
  - 两层根因：
    1. **生命周期**：销毁绑死在单一成功回调上。回调不来（低端机 / 软件渲染 / 载入失败）就是**永久泄漏一个 renderer 进程**，没有任何终点。
    2. **平台契约**：全 app 没有任何 WebView 注册 `onRenderProcessGone`。`third_party/flutter_inappwebview_android/.../InAppWebViewClientCompat.java:811-822`
       —— 只有 `useOnRenderProcessGone` 为真时才 `return true`，否则走 `super.onRenderProcessGone(...)`（= false），而 Android 对 false 的默认动作就是杀掉整个 app 进程。
  - 真机影响：不是 CI 专属。任何 Android 设备上 WebView renderer 被系统 OOM kill（后台常见）都会让 Hibiki 直接闪退。
- **[x] ① 已修复** — `hibiki/lib/src/startup/webview_prewarm.dart` 新增 `WebViewPrewarmSession`：把「什么时候结束」从单一成功回调改成**先到者胜的多路终点**
  （载入完成 / 载入失败 `onReceivedError` / renderer 死亡 `onRenderProcessGone` / 30s 兜底超时），`finish()` 幂等只 dispose 一次、dispose 抛错不外抛；
  `hibiki/lib/main.dart:376-412` 按此接线。注册 `onRenderProcessGone` 同时让 Android 侧返回 true，renderer 死亡不再连坐杀进程。
- **[x] ② 已加自动化测试** — `hibiki/test/startup/webview_prewarm_session_test.dart`：6 条行为单测（幂等、`fakeAsync` 超时兜底、撤表、dispose 抛错吞掉）
  + 1 条 main.dart 接线守卫（`enclosingCallOf` 括号配对取窗口，`maskComments` 掩注释）。守卫做过变异实测：
  把 `onRenderProcessGone:` 整段挪进注释 → 红；注释掉 `session.armTimeout()` → 红。
- **备注**：
  - CI 侧另有**不由本修复覆盖**的环境限制：hosted runner 的 AVD 跑软件 GL，日志里单帧耗时到 `app_time_stats: avg=213995.03ms`、
    `Skipped 1402 frames`，整轮 appSmoke 耗时 11-23 分钟。本修复移除了观测到的致死路径，但不保证 appSmoke 从此稳定绿；
    该 job 已是 `continue-on-error: true`（`.github/workflows/build-multiplatform.yml:56`），不阻塞合并门。
  - **未收口的同类风险（另开条目再修）**：`lapis_style_editor_page.dart:379`、`manga_hibiki_page.dart:2899`、
    `dictionary_popup_webview.dart:1249`、`reader_hibiki/webview.part.dart:1654` 四个**用户可见**的 `InAppWebView` 同样没有 `onRenderProcessGone`，
    renderer 死亡一样会杀进程。这四处需要各自的降级 UX（重载 / 提示 / 退回列表），不是加个回调就完事，不并入本次改动。
