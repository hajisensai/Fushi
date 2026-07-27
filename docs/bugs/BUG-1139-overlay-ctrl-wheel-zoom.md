## BUG-1139 · app 外查词浮窗 Ctrl+滚轮触发 WebView2 原生页面缩放，窗口/region 几何按 zoom=1 计算导致卡片被切、露出底下应用
- **报告**：2026-07-27（用户：「这个缩放有点问题 滚轮。左边是空的。」附截图：Anki 上方的 app 外查词浮窗，第一张词典卡被窗口左边缘竖着切掉一半，切口外直接是 Anki 的背景）
- **真实性**：✅ 真 bug（沿真实代码路径验真，未复现于 in-app 弹窗——in-app 有独立的两道防护，见下）
- **现状（2026-07-27 复审）**：⚠️ **标题症状尚未闭环**。① 拆掉了 WebView2 原生 ZoomFactor
  这个第二真值来源（真实且必要），但几何链对 CSS zoom 依旧零补偿，放大后窗口宽度不变、高度在
  未触卡上限时仍偏小 z 倍，卡片仍会被 window region 切。详见下方 ③。下面 ①/② 的 `[x]` 只表示
  「原生缩放已断开」与「已有守卫」，**不代表用户可见症状已消失**。

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

  **有意不做**的事：app 外**不**在 JS 侧就地改 `documentElement.style.zoom`，改由 Dart 改
「词典字号」这一唯一真值后整栈重渲，避免 JS 与 Dart 两处各写一份 zoom。代价是每档多一次
Dart 往返（约 1~2 帧）。

- **[ ] ③ 未闭环：几何链仍不认识 CSS zoom（复审 2026-07-27 发现，原始症状会以同一形态复发）**

  ① 只拆掉了「WebView2 原生 ZoomFactor」这个第二真值来源，**没有**给几何链补上 zoom 分量。
  沿真实代码路径复核后，本文件早先「走 Dart 改字号 → 按新字号真实重排，高度/bbox/region 沿现有
  链路自然更新」的说法**不成立**：

  1. `dictionaryFontSize` 对渲染的**唯一**作用就是 CSS zoom ——
     `popup_settings_injection.dart:534-537,551` 注入
     `documentElement.style.zoom = popupContentZoom(appUiScale, fs)`
     （`dictionary_popup_webview.dart:283-289`，= `appUiScale × fs/16`）；
     全仓没有任何一处用 `dictionaryFontSize` 生成 `font-size` CSS。所以「重渲」重渲出来的
     差异也只是这一行 zoom —— 原生 zoom 换成了 CSS zoom，不是真正的按字号重排。
  2. 几何链对 CSS zoom **零补偿**：`global_lookup_host.js:1820-1834` 的 `measureContentHeight`
     直接读 `body.scrollHeight / offsetHeight`（CSS `zoom` 下是未乘 z 的 layout px，本仓
     `popup.js:3929-3945` 自己钉死过这个事实），没有 `× z`。
  3. 高度只会**往小里收**：`global_lookup_host.js:1722-1725`
     `if (measured > 0 && (height <= 0 || measured < height)) height = measured;`，撑不大。
  4. 物理窗口公式里没有字号分量：`global_lookup_controller.dart:1350-1351`
     `overlaySize.width/height × appUiScale`（`:1445-1448` 再 `× dpr`）—— 只有 `appUiScale`，
     没有 `popupContentZoom`/`fs`。注意这里的不对称：`appUiScale` 在盒子侧被完整抵消
     （内容与盒子同步放大），而 `fs` 只放大内容、盒子一动不动。

  后果：Ctrl+滚轮放大后**窗口宽度一个像素都不会变**（卡内有效布局宽反而从 `size×16/16` 缩到
  `size×16/fs`，文字列变窄、行数变多）；高度在「内容未触卡上限」时被裁到未乘 z 的 `measured`，
  而卡片实际画出 `measured × z`，底部 `(1 − 1/z)` 落在 window region 外 → **卡片照样被切、
  照样露出底下的应用**。

  需要说清的归属：这条**不是本 PR 引入的回归** —— head 里那行 zoom 注入在 develop 上一直存在，
  任何 `dictionaryFontSize ≠ 16` 或 `appUiScale ≠ 1` 的老用户在 app 外浮窗上早已命中；本 PR 的
  改动让用户可以用 Ctrl+滚轮在几秒内**交互式地**把自己滚进这个区间，因此暴露面明显变大。

  真正闭环需要二选一（或都做），属独立跟进项：
  - `measureContentHeight` 乘上 iframe 的 `documentElement.style.zoom`，把 layout px 换算成
    host 可视 px；且高度判据要允许撑大而不只是收小；
  - 或让 `cardW/cardH` 乘 `fs/16`，使盒子随字号长大，与 `appUiScale` 对称——否则「放大」永远
    等价于「视口变窄」。

  剪贴板面板路径不受**高度**问题影响：`global_lookup_host.js:1678-1683` 在 panel 模式直接短路
  （窗口尺寸固定），但「放大=视口变窄」的观感问题同样存在。

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
  **仍缺真机目视复测**，且按 ③ 的分析，真机上跑原始失败路径（Anki 上方开 app 外浮窗 →
  Ctrl+滚轮放大）**预期仍会看到卡片被切** —— 复测重点不是「是否已修好」，而是确认：
  字号逐档变、重开后记住档位、原生 Ctrl+加减/触控板捏合确实已失效（① 生效），
  以及 ③ 描述的切边形态与预测是否一致。离屏 itest 取不到原生覆盖窗的像素
  （见 agent 文档的离屏能力边界），故这一步必须人工目视。
  另注：本机 `flutter build windows --debug` 的验证结论仍成立（两个 COM setter 编译通过）。
