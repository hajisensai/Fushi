## BUG-1854 · 制卡截图把游戏窗口标题栏截进去了，应裁到客户区
- **报告**：2026-08-25（用户：制卡的时候不应该把应用顶栏给截图进去）
- **真实性**：✅ 真 bug。
  - galgame 制卡截图只有一条 native 路径：浮窗制卡 / 台词浮窗点词制卡 / texthooker 页制卡 /
    快捷键制卡四个入口全部汇到 `gal_hook_mining_coordinator.dart` `_captureStill` / `galgame_window_gif.dart`
    → `window_capture_channel.dart` `captureWindow(hwnd)` → `window_capture.cpp` `CaptureWindowPng`。
  - `CaptureCore` 用 WGC `interop->CreateForWindow(hwnd)` 抓**整个顶层窗口**的 DWM 视觉
    （= `DWMWA_EXTENDED_FRAME_BOUNDS`，含标题栏 / 菜单栏 / 边框），随后拿 `desc.Width/Height`
    把整张纹理原样 `EncodeBgraToPng`，全程没有一处裁剪、没有 `GetClientRect`。
  - 「应用顶栏」= 游戏窗口自己的标题栏 / 菜单栏（窗口化跑的 KiriKiri / Siglus / Ren'Py 都带）。
    Fushi 自己的工具条 / 浮窗是独立顶层 `WS_POPUP` 窗，WGC per-window 捕获物理上截不到它们；
    `put_IsBorderRequired(false)` 只关 WGC 的黄色捕获高亮框，与窗口 chrome 无关。仓库自己的
    `docs/specs/galgame-mining/handoff.md` 也早观察到「WGC 只截到菜单栏+白色画布」。
- **[x] ① 已修复** — `window_capture.cpp` 新增 `ComputeClientCropBox`，`CaptureCore` 在
  `Map` 之后 / 编码之前把纹理裁到客户区：
  - 裁剪原点 = `ClientToScreen` 的客户区屏幕原点 − `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`
    的框架原点（**不是** `GetWindowRect`：Win10+ 不可见 resize 边框会让它偏几像素；OBS「Client Area」
    同款算法）；尺寸 = `GetClientRect`，与纹理求交。本进程 per-monitor DPI aware，这几个 API 与 WGC
    纹理同为物理像素。
  - 编码只是把指针按 `RowPitch` 偏移到子矩形左上角、宽高换成子矩形，行距不变，不再拷一次纹理。
  - 任何一步失败 / 退化成空矩形 → 回退整窗编码并 `AppendDiagnostic("client-area crop unavailable…")`
    （fail-open，与本文件既有风格一致）；Magpie 重定向后的源窗同样走这条。
  - 一处改、四条入口同时生效；动图路径逐帧调同一通道，自动裁。
- **[x] ② 已加自动化测试** — `fushi/test/build/window_capture_client_area_guard_test.dart`
  三条源码守卫：① 原点公式必须是 ClientToScreen − 扩展框架原点且不得用 GetWindowRect；
  ② 裁剪落在 Map 之后、编码前按子矩形偏移指针并换宽高、不得再整窗直接编码；③ 空矩形判失败 +
  回退整窗写 diagnostics。
- **备注**：⚠️ **真机未复验**（本轮真机验证已取消）。复验点：① 窗口化游戏制卡，卡片图不含标题栏 /
  菜单栏，四边无 DWM 边框黑线；② 无边框全屏游戏（客户区 == 窗口）图不变；③ 150% 缩放显示器上
  裁剪不偏；④ Magpie 缩放窗绑定时裁的是源窗客户区。另：texthooker 页制卡（`texthooker_page.dart`
  `_mineActiveLine`）没传 `captureLeaseFactory`，游戏内查词卡开着时从该页制卡 BUG-1634 的隐藏屏障
  不生效——与本条正交的独立缺口，未在本轮处理。
