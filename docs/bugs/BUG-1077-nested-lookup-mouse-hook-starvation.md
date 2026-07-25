## BUG-1077 · 嵌套查词瞬间全局鼠标卡顿：钩子线程无优先级+嵌套路径卸装钩子churn
- **报告**：2026-07-25（用户：「有时候你嵌套查的时候鼠标会卡一下，不知是整个画面卡还是鼠标卡。app外。」）
- **真实性**：✅ 真 bug —— BUG-1048 把 `WH_MOUSE_LL` 挪到专用线程后仍留两个残余机制，恰在嵌套查词瞬间叠加发作：
  1. **钩子线程无优先级**（`hibiki/windows/runner/low_level_mouse_hook.cpp:79`，修复前）：`std::thread(&HookThreadMain)` 默认 `THREAD_PRIORITY_NORMAL`。LL 钩子是**同步**钩子——系统等承载线程被调度并返回（上限 `LowLevelHooksTimeout` 300ms）才把输入分发给前台程序。嵌套查词瞬间进程内 CPU 风暴：Dart isolate 同步 FFI 词典查询（`app_model.dart:3564` → `hoshidicts.dart:553`）+ 整栈重序列化（`global_lookup_render.dart:271-306`，每帧 popupJson 全量重拼再 `jsonEncode`）+ platform 线程 WebView2 `put_Bounds` 同步 COM 与 `SetWindowRgn` 连击（`global_lookup_window.cpp:1771/1664/1676`）+ WebView2 渲染进程 iframe 布局。NORMAL 优先级的钩子线程被抢占几十毫秒 = 全系统鼠标卡一下，时间点精确对上「嵌套那一刻、一次性」。
  2. **嵌套路径钩子表 churn**（`global_lookup_controller.dart:527` + `global_lookup_window.cpp:744-746`/`:527`）：剪贴板面板嵌套（`clipboard_panel_controller.dart:673 _lookupExternal`）与 galgame 浮窗查词都先走 `GlobalLookupController.lookupText()` 的 reset `hide(notify:false)` → `Hide()` 无条件 `DisarmLowLevelMouseHook()`（真 `UnhookWindowsHookEx`），百毫秒后 `RevealStack` 再 `ArmLowLevelMouseHook()`（真 `SetWindowsHookEx`）。每次嵌套 = 两回全局钩子表变更，桌面级钩子链更新与 Raw Input 线程串行，各是一次全系统输入短暂停顿。
  3. 次要：`low_level_mouse_hook.cpp:83-87`（修复前）首次建线程用 `Sleep(1)` 自旋等 id 发布，跑在 platform 线程，默认定时器精度下单次可睡 ~15ms——只影响首次查词，不是嵌套主因，一并修掉。

  另有「画面卡」侧的独立贡献因子（同步 FFI 查询阻塞 UI isolate、整栈重序列化 O(N)、`SetWindowPos`+`put_Bounds`+一次嵌套 3~6 次 `SetWindowRgn` 打断 DWM/全屏合成），属更大的架构改动，见备注的后续项，不在本 bug 内。
- **[x] ① 已修复** —— 全部收敛在 `low_level_mouse_hook.{h,cpp}` 内部，不往 Dart→channel→C++ 穿特例标志：
  - `HookThreadMain` 开头 `SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL)`——LL 钩子承载线程标准做法；回调每事件只做两次整数比较，高优先级不会饿别人。
  - `Disarm` 改「立即清 `g_target`（回调纯放行，语义等同已卸载）+ 宽限期 `kDisarmGraceMs=3000ms` 后才真 `UnhookWindowsHookEx`（钩子线程 `SetTimer`/`KillTimer` 线程定时器）；期间新 `Arm` 取消卸载」。嵌套/连续查词的钩子表变更从每次 2 回降到 0；真正闲置超宽限期照样卸钩子，「不查词不留全局钩子」的承诺不变。到期回调再核一次 `g_target` 防御队列里尚未消费的 Arm。
  - `EnsureHookThread` 的 `Sleep(1)` 自旋改为事件等待（`CreateEventW` + `WaitForSingleObject`，事件句柄进程生命周期常驻）。
  - `GlobalLookupWindow` 侧零改动：`Hide`/`Reveal`/`RevealStack` 的 Arm/Disarm 调用点、点击外关闭语义、常驻剪贴板面板从不 arm 的约定全部原样。提交：c931d8f98
- **[x] ② 已加自动化测试** —— `hibiki/test/lookup/global_lookup_mouse_hook_stutter_guard_test.dart`（源码守卫：TIME_CRITICAL 必在；Disarm 必须走 `kDisarmGraceMs` + `SetTimer`/`KillTimer` 延迟真卸，不许退回立卸立装；等线程就绪必须 `WaitForSingleObject`，禁止 `Sleep` 自旋）。纯 Win32 输入队列行为无法在 Dart 行为测试复现，源码守卫是最强可落地层；BUG-1048 既有守卫 `global_lookup_mouse_hook_thread_guard_test.dart` 继续锁专用线程/只 PostMessage 结构。
- **备注**：native 改动，**待 Windows 真机复测**原始失败路径（app 外浮窗/面板里嵌套查词，观察鼠标是否还卡一下）；建议真机用 WPR 抓一次嵌套查词看 win32k 输入延迟事件。若真机复测仍有「画面卡一下」残余，按调查已定位的后续项开新 bug：① `HoshiDicts.lookup/queryKanji` 移出 UI isolate；② `buildStackRenderScript` 增量化（只下发新增/变更帧）；③ `RenderJson` 去整串复制 + `shellRects`/`WM_SIZE` 的 `SetWindowRgn` 节流合并。
