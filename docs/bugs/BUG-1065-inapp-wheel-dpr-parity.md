## BUG-1065 · app 内查词弹窗滚轮比 app 外慢 1/dpr（native sendScroll 未还原 DPR）

- **报告**：2026-07-25（用户：app 外的查词弹窗和 app 内的查词弹窗滚轮滚动速度感觉不一样）
- **真实性**：✅ 真 bug — 两条弹窗路径喂给 WebView2 的 wheel 单位不同，差 `devicePixelRatio` 倍。根因链：
  1. `packages/flutter_inappwebview_windows/lib/src/in_app_webview/custom_platform_view.dart:484-488` — app 内弹窗（`InAppWebView`）的滚轮取 Flutter `PointerScrollEvent.scrollDelta`，而 framework 的 `converter.dart:283-284` 对 scrollDelta 统一做了 `/ devicePixelRatio`，拿到的是**逻辑像素**。
  2. `packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp:1974-1983`（修前）— `sendScroll` 用硬编码 `delta * kScrollMultiplier(6)`，注释自陈前提是「一档 delta≈20」，该前提只在 dpr=1 成立。**同一文件的鼠标坐标（`:1843` / `:1907` / `setPosition`）都乘了 `scaleFactor_` 还原物理像素，唯独滚轮 delta 漏了**。
  3. `hibiki/windows/runner/global_lookup_window.cpp:913-962` — app 外弹窗是裸 WebView2 overlay，`ForwardCompositionMouse` 把系统原始 `GET_WHEEL_DELTA_WPARAM`（一档 120）原样转发，不打折。
  - 报告机实测主显示器 DPI 144（150% 缩放，4K），`WheelScrollLines=3`。一档鼠标：app 外 → 120（1 个 WHEEL_DELTA，DOM `deltaY≈100`）；app 内 → `20/1.5×6 = 80`（0.67 档，`deltaY≈67`）。两端跑的是同一份 `assets/popup/popup.js`（同一 0.24 粗档系数 + 同源 zoom 补偿），所以差的就是入口的 1/dpr。
  - 附带危害：`popup.js` 以 `POPUP_WHEEL_MOUSE_NOTCH_PX=60` 区分粗鼠标/触控板。dpr≥2 时 app 内一档 `deltaY` 跌到 50 < 60，会被**误判成触控板**走 1.0 倍率（而非 0.24），同一台机器上 app 内弹窗反而暴快约 4 倍。修复后分类回到设计假设。
- **[x] ① 已修复** — `in_app_webview.cpp` `sendScroll` 先按 `scaleFactor_`（`setSurfaceSize` / `setPosition` 存的 `View.devicePixelRatio`，缺省 1.0）把逻辑像素还原成物理像素再乘 `kScrollMultiplier`：`delta * kScrollMultiplier * dprScale + residual`。与同文件坐标处理一致，dpr=1 的机器逐帧与改前完全相同；BUG-870 的跨帧残差累积（`scrollResidualX_/Y_`、`offset==0` 留到下帧）原样保留，触控板慢滑不回归（还原后更容易凑够整 wheel 单位）。
- **[x] ② 已加自动化测试** — `hibiki/test/build/popup_wheel_native_residual_guard_test.dart` 扩为双端契约守卫：新 group 断言 in-app 侧 `sendScroll` 乘 `scaleFactor_`、旧的无 DPR 形式 `delta * kScrollMultiplier + residual` 不再出现；并锚定 app 外 `global_lookup_window.cpp` 仍原样转发 `GET_WHEEL_DELTA_WPARAM`（对照端不许悄悄改成打折转发）。native 无法在测试宿主运行，故为源码扫描守卫，与 BUG-870 同法。
- **备注**：爆炸半径 = 所有 Windows `InAppWebView` 的滚轮/触控板输入（查词弹窗、阅读器连续模式、视频页、首页词典），方向是**恢复到与系统原生一致**，不是加速特例。100% 缩放机器零行为变化。真机终验项：150% 缩放下 app 内/app 外弹窗一档滚动距离应目测一致（需 `flutter build windows` 编 native）。
