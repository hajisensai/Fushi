## BUG-1139 · app 外查词浮窗 Ctrl+滚轮触发 WebView2 原生页面缩放，窗口/region 几何按 zoom=1 计算导致卡片被切、露出底下应用
- **报告**：2026-07-27（用户：「这个缩放有点问题 滚轮。左边是空的。」附截图：Anki 上方的 app 外查词浮窗，第一张词典卡被窗口左边缘竖着切掉一半，切口外直接是 Anki 的背景）
- **真实性**：✅ 真 bug（沿真实代码路径验真，未复现于 in-app 弹窗——in-app 有独立的两道防护，见下）

### 根因

一条「看不见的第二真值来源」：**WebView2 自带的页面缩放（ZoomFactor）不在覆盖窗的几何链里**。

1. `hibiki/windows/runner/global_lookup_window.cpp:962` — `ForwardCompositionMouse` 把 `WM_MOUSEWHEEL`
   连同 `GET_KEYSTATE_WPARAM`（含 `MK_CONTROL`）原样 `SendMouseInput` 给 WebView2。
2. `hibiki/windows/runner/global_lookup_window.cpp` 的 `ConfigureWebView()` 只设了
   `put_IsStatusBarEnabled(FALSE)`，**从没设 `put_IsZoomControlEnabled(FALSE)`** → 原生缩放默认开着。
3. `hibiki/assets/popup/popup.js:4100` — 弹窗滚轮监听明确 `if (e.ctrlKey) return;`，把 Ctrl+滚轮让给原生。
4. app 外浮窗**从没装** in-app 那套内容缩放：`_zoomWheelJs` / `__hoshiPopupZoomStep` 只在
   `dictionary_popup_webview.dart:1872` 的 `onLoadStop` 注入（in-app 三个表面专属）。
5. 而覆盖窗整条几何链按「CSS px @ zoom=1」算：
   - `hibiki/assets/popup/global_lookup_host.js:1791-1817` — host 用 `shell.style.left/width` +
     `body.scrollHeight` 报 bbox 与 shellRects（CSS px）；
   - `hibiki/lib/src/lookup/global_lookup_controller.dart:251` — Dart 按 `逻辑宽 × appUiScale × dpr`
     定物理窗口尺寸；
   - C++ 再用同一批数值 `SetWindowPos` + `ApplyRoundedRegion` 裁 window region。

ZoomFactor 只放大**绘制**，不改上面任何一个读数。于是 Ctrl+滚轮后内容按 z 绘制、窗口与 region 仍是
z=1 的尺寸 → 卡片被窗口边缘切掉，region 外露出底下的应用（用户看到的「左边是空的」）。

in-app 弹窗为何不受影响：`dictionary_popup_webview.dart:1227` 设了 `supportZoom: false`（关原生缩放），
并自己装了走「词典字号 + 就地 zoom + 持久化」的 Ctrl+滚轮。两道防护 app 外一道都没有。

加重项：WebView2 的缩放档位按 origin **持久记忆**在用户数据目录里 —— 只关控制不复位，已经缩过的
老用户升级后窗口照样是切的。

- **[x] ① 已修复** — commit `f0f5596ff`
  1. `hibiki/windows/runner/global_lookup_window.cpp` `ConfigureWebView()`：
     `put_IsZoomControlEnabled(FALSE)` 断掉原生缩放（与 in-app `supportZoom:false` 对齐）+
     `put_ZoomFactor(1.0)` 复位持久档位。ConfigureWebView 是两条创建路径 + BUG-693 自愈重建的
     唯一漏斗，覆盖这个窗曾经拥有的每个 surface；瞬态覆盖窗与常驻剪贴板面板是同一个
     `GlobalLookupWindow` 类的两个实例，一处修复覆盖两个表面。
  2. 缩放能力不丢：`popup_settings_injection.dart` 新增 `_globalLookupZoomWheelJs`（仅
     `options.globalLookup` 注入），Ctrl+滚轮 → `preventDefault` → rAF 合帧累加**净档数** →
     `callHandler('popupZoomFontStep', steps)`。
  3. `overlay_bridge_handlers.dart` 新增 `maybeHandleOverlayZoomFontStep` + 纯函数
     `zoomFontSizeAfterSteps`：逐档过既有的 `steppedPopupZoomFontSize`（含 8..72 夹紧，与 in-app
     Ctrl+滚轮、弹窗顶栏 A−/A+ 同一真值），改 `dictionaryFontSize` 后回调整栈重渲；
     `global_lookup_controller` / `clipboard_panel_controller` 各接一处（共享实现，两表面不漂开）。

  **有意不做**的事：app 外**不**就地改 `documentElement.style.zoom`。CSS `zoom` 下
  `body.scrollHeight` 仍是未乘 z 的 CSS px，而 host 的 `measureContentHeight` 正是读它报卡片高度 ——
  就地缩放会让高度被系统性报小 z 倍，等于把同一个几何毛病换个地方复发。走 Dart 改字号 → 重渲 →
  按新字号真实重排，高度/bbox/region 沿现有链路自然更新，几何链一行不用改。代价是每档多一次
  Dart 往返（约 1~2 帧）。

- **[x] ② 已加自动化测试** — `hibiki/test/lookup/overlay_ctrl_wheel_zoom_test.dart`（8 条）
  - 纯函数：净档数 → 字号折算、0 档、双侧夹死 8..72、顶到边界后返回原值（据此跳过无谓重渲）；
  - 分发：非本 handler 不拦截；本 handler 恒被吞掉且无 model 时不重渲；
  - 源码守卫：C++ 两项设置必须落在 `ConfigureWebView` 内；app 外注入必须有 ctrl 门控 +
    `popupZoomFontStep` + rAF 合帧，且**不得**出现 `style.zoom`（防止把几何毛病搬回来）；
    注入必须由 `globalLookup` 门控（防与 in-app `_zoomWheelJs` 双装一档滚两级）；
    两个 app 外表面都必须接线。

- **备注**：本机验证 = `flutter analyze` 全量（含 test）零问题 + 新测试 8/8 + 相邻定向 584/584
  （test/lookup、popup 列数、masonry 守卫、bugs per-file 守卫）+ `flutter build windows --debug`
  通过（323.3s，`√ Built build\windows\x64\runner\Debug\hibiki.exe`，`global_lookup_window.cpp`
  零告警——两个 COM setter 编译验证通过）。
  **仍缺真机目视复测**：需在 Windows 上跑原始失败路径（Anki 上方开 app 外浮窗 → Ctrl+滚轮 →
  卡片不再被窗口边缘切、字号逐档变、重开后记住档位），并顺带确认常驻剪贴板面板同样生效。
  离屏 itest 取不到原生覆盖窗的像素（见 agent 文档的离屏能力边界），故这一步必须人工目视。
