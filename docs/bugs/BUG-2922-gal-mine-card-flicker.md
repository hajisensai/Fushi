## BUG-2922 · 游戏内查词卡点制卡时卡片消失一下
- **报告**：2026-10-03（用户：「点制卡的时候查词窗会消失一下」）
- **真实性**：✅ 真 bug（设计缺陷）。制卡要截游戏画面，`GalIngameLookupController.acquireMiningCaptureLease`（`fushi/lib/src/lookup/gal_ingame_lookup_controller.dart:942`）在 hook 确认隐藏游戏层后，又把**直连查词卡 HWND** `GlobalLookupChannel.hide` 掉，截完再 `_drainRecapture` 重新上屏——每次点制卡卡片都闪一下。理由注释说直连卡「不在游戏 Layer 里，hook 藏不掉，会被 WGC/窗口捕获拍进去」，但游戏截图只走按窗口的捕获（`window_capture.cpp`：WGC `CreateForWindow` + PrintWindow 回退，没有屏幕级抓取），而直连卡是独立顶层窗（`GWLP_HWNDPARENT` 设为游戏的 owned popup，不是子窗）。
- **验证**：本机独立探针（MSVC 直编 C++/WinRT）：红色主窗上压一个 owned、topmost、`WS_EX_NOACTIVATE` 的绿色弹窗，屏幕像素读到绿色，`WGC CreateForWindow(主窗)` 抓帧同一点读到红色——owned 顶层弹窗不会进窗口捕获。PrintWindow 只渲染目标窗口自身，同理。
- **[x] ① 已修复** — 取截图租约时不再 hide 直连卡、不再把 `_directSurfaceActive` 置假；hook 侧的 suspend（隐藏位图回退卡与词高亮，这些确实在游戏渲染树里）照旧，release 照旧重投一次解除 hook suppress（直连卡原位不动）。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/gal_ingame_lookup_contract_test.dart`：行为测试「制卡截图租约不隐藏直连卡」（取租约 / 释放全程 global channel 零 `hide`，hook `galLookupSuspendForCapture` 仍发出）+ 源码守卫（`acquireMiningCaptureLease` 体内不得出现 `GlobalLookupChannel.hide(` 与 `_directSurfaceActive = false`）。
- **备注**：attached 校准路径（`gal_hook_text_overlay_controller.dart` 的 `_acquireAttachedMiningCaptureLease` 会 `suspendForCapture` 桌面查词卡）同样是独立顶层窗，理论上同样不必藏，但不是本次报告的路径，未改。真游戏里制卡后卡片是否完全不闪、截图里是否确实没有卡片，**未在真机复验**（`implemented_unverified`）。
