## BUG-2790 · 查过一次词后再开 app 外查词窗只剩旧 WebView 残影、卡片画不出
- **报告**：2026-09-29（排查 BUG-2789 时真机发现；与用户报的「截屏识字只有一层灰」同一类症状）
- **真实性**：✅ 真 bug，根因未定位。三星 Tab S9（Android 16）上 **release 包 `2.8.0-debug.16172` 与本地 debug 包都复现**，与 BUG-2789 的锚点布局无关：
  1. 用 `PROCESS_TEXT`（或截屏识字点字）打开 app 外查词窗查一次词——词典结果 WebView（flutter_inappwebview 平台视图）在 `:popup` 热引擎里建出来；
  2. 关窗（`PopupDictFlutterActivity` finish，引擎留在 `FlutterEngineCache`）；
  3. 再用任何入口打开查词窗（悬浮球「应用外查词」/ 系统「处理文本」/ 截屏识字）。
  新 Activity 挂回热引擎后 `:popup` 进程每帧报 `E/flutter: [ERROR:flutter/impeller/toolkit/egl/egl.cc(56)] EGL Error: Bad Access (12290)` + `gpu_surface_gl_impeller.cc(76) Could not make the context current to acquire the frame`：Flutter 整帧画不出来（没有搜索栏 / 卡片），屏上只剩上一次那个 WebView 平台视图停在旧位置；透明关闭层仍收触摸，点外面能关。
  没建过 WebView（只开空查词窗）时反复开关不复现（release 包实测两次零 EGL 错误）。
- **根因（2026-09-30，按 Flutter 3.44 引擎源码逐行确认）**：热槽 WebView 是老式 Hybrid Composition（`dictionary_popup_webview.dart` 未设 `useHybridComposition`，fork 默认 true），一出现 `external_view_embedder.cc` 就把 raster 线程并进 platform 线程，GL 上下文在 platform 线程上 make current。关窗 detach → `Rasterizer::Teardown`（`shell/common/rasterizer.cc:120-143`）在合并线程上 make current 后 `surface_.reset()`：Skia 的 `~GPUSurfaceGLSkia` 会 `GLContextClearCurrent()`，**`~GPUSurfaceGLImpeller() = default` 什么都不清**；随后的 unmerge 回调因 `surface_` 已空跳过 ClearRenderContext，`TeardownOnScreenContext` 又投到已解除合并的 raster 线程。上下文永久留在 platform 线程 → 新 Activity 的 raster 线程每帧 `EGL_BAD_ACCESS`。上游 flutter#174495（同日志，未修）。
- **2026-09-30 用户报「悬浮球查出来不能往下滑」就是本条**：悬浮球的应用外查词 / 剪贴板查词 / 截屏识字都开这个窗，第二次打开起卡片画不出、只剩冻住的旧 WebView，滑不动。真机（SM-X716B，用户装机 2.8.0-debug.16248）复现：悬浮球剪贴板查词 → 关 → 再开，EGL Error 51 次，滑动前后帧完全相同。
- **[x] ① 已修复（2026-09-30 真机复验）** — `PopupEngineHolder.kt`：`:popup` 引擎以 `--enable-impeller=false` 创建（Skia 析构路径不漏上下文；主进程不受影响）。**临时兼容层**（上游引擎缺陷）：清理条件 = 上游修好 Teardown 顺序，或 Skia 被移除前改为「弹窗 WebView 走 TLHC（useHybridComposition:false）」。热槽（TODO-951）不受影响。真机复验（SM-X716B，并行测试包 + Weblio 古語辞典）：首开查词建出 WebView（dumpsys 1 个 InAppWebView）→ 关窗（Activity 已销毁）→ 再开 + 另 3 轮开关，**EGL Error 始终 0**，每次都画出搜索栏 / 新词卡片且能上下滑；logcat 见 `Impeller opt-out deprecated`（:popup 已走 Skia）。对照：同机用户装机旧包同流程第二次打开 51 次 EGL Error、滑动前后帧不变。
- **[x] ② 已加自动化测试** — `fushi/test/build/popup_engine_impeller_guard_test.dart`（源码守卫：`:popup` 引擎必须带 `--enable-impeller=false`，兼容层带根因注释）。
- **备注**：取证命令：`adb logcat -d | grep -c "EGL Error"`，在上述第 3 步后 > 0 即复现。
