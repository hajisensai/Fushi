## BUG-1096 · 画面捕获出现两个鼠标指针

- **报告**：2026-07-26（用户：）
- **真实性**：✅ 真 bug（成因在捕获目标，不在我们画光标）。本仓画面捕获只有一条链：
  Dart `hibiki/lib/src/mining/window_capture_channel.dart:16`（`app.hibiki.reader/window_capture`）
  → native WGC 单帧 `hibiki/windows/runner/window_capture.cpp`。全仓零 `gdigrab` /
  `-draw_mouse` / `DXGI_OUTDUPL_POINTER` / `DrawIcon` / `GetCursorInfo`——**我们只关不画**，
  GIF 也只是连拍静帧再 ffmpeg 合成（`galgame_window_gif.dart`，ffmpeg 只吃 PNG 序列）。
  所以两个指针只能是捕获源画面里本来就有两个，两种成因：
  ① **捕获目标是 Magpie（或同类缩放工具）的缩放窗口**：Magpie 与我们对称地关掉了 WGC
  合成光标，然后**自己按 cursorScaling 把光标画进缩放输出**，于是它的窗口里 =
  游戏自绘光标 + Magpie 补画的一个 = 两个；我们再抓这个窗口就原样进 GIF。Magpie 的缩放窗
  是普通顶层窗口（类名 `Window_Magpie_<GUID>`），完全可能被 `listWindows()` 选中，它上面挂
  着窗口属性 `Magpie.SrcHWND` 指向真实源窗口。
  ② **`put_IsCursorCaptureEnabled(false)` 在用户机器上没生效**：`IGraphicsCaptureSession2`
  需要 Win10 build 19041+，而 `window_capture.cpp:310-318`（修复前）的 QI 结果与 put_ 的
  HRESULT **两处都被静默吞掉、不写任何日志**，是彻底的盲区——「到底关掉没有」不可证。
- **[x] ① 已修复**（提交 fceb21443）— 两条成因都覆盖：
  - **成因①（捕获目标）**：新增 `hibiki::ResolveScalingSourceWindow()`
    （`hibiki/windows/runner/window_capture.cpp` + `.h`），按窗口属性 `Magpie.SrcHWND`
    （**不按类名**——类名里的 GUID 是实现细节，属性名才是稳定契约）把缩放窗解析成源窗口。
    两处都过一遍：`EnumProc`（枚举阶段，连 `title`/`pid` 一起换成源窗口的——PID 以前会是
    Magpie.exe，voice hook 的注入目标同样会错；并按 hwnd 去重）与 `CaptureWindowPng`
    （绑定阶段，覆盖 Dart 侧缓存句柄 / 选窗后才开 Magpie 的情况）。
    拿不到属性 / 句柄失效时保持原窗口不变（没装 Magpie 的用户路径逐字不变）。
  - **成因②（盲区）**：`WindowCaptureResult` 新增 `diagnostics` 字段（与 `error` 正交，
    成功路径也带）。QI 失败与 `put_IsCursorCaptureEnabled` 的 HRESULT 都写进去，
    经 `flutter_window.cpp` 的 `WM_WINDOWCAP_DONE` 回复带到 Dart
    （`WindowCaptureResult.diagnostics`），由 `galgame_window_gif.dart` /
    `gal_hook_mining_coordinator.dart` 在非空时记一条日志。捕获目标被重定向也记一条。
  - **不在范围内**：游戏**自绘**的光标是画面内容本身，任何捕获 API 都剥不掉；本轮没修也修不了。
- **[x] ② 已加自动化测试** —
  - 源码守卫 `hibiki/test/build/window_capture_magpie_cursor_guard_test.dart`：断言
    `Magpie.SrcHWND` 重定向在枚举与绑定两处都存在、`put_IsCursorCaptureEnabled` 的 HRESULT
    与 QI 结果不再被丢弃、`diagnostics` 经 channel 回到 Dart。
  - Dart 单测 `hibiki/test/mining/window_capture_channel_test.dart`（新增）：
    `diagnostics` 字段解析，且带 diagnostics 的成功结果仍是 `ok`。
- **备注**：native C++ 改动已用 `flutter build windows --debug` 真编译验证。
  **未做真机验证**：需要用户装着 Magpie 的原始路径复跑一次，确认 GIF 里只剩一个指针，
  并在日志里看到重定向/光标抑制两条 diagnostics 的实际取值。在此之前只能算
  `implemented_unverified`。
