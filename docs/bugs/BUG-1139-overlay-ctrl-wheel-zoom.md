## BUG-1139 · app 外查词浮窗 Ctrl+滚轮触发 WebView2 原生页面缩放，窗口/region 几何按 zoom=1 计算导致卡片被切、露出底下应用
- **报告**：2026-07-27（用户：「这个缩放有点问题 滚轮。左边是空的。」附截图：Anki 上方的 app 外查词浮窗，第一张词典卡被窗口左边缘竖着切掉一半，切口外直接是 Anki 的背景）
- **真实性**：✅ 真 bug（沿真实代码路径验真，未复现于 in-app 弹窗——in-app 有独立的两道防护，见下）
- **现状（2026-07-27 复审后已闭环）**：✅ 三段都落地。复审曾发现 ① 只断开了 WebView2 原生
  ZoomFactor、几何链仍不认识 CSS zoom（放大后卡片照样被切），已在同一 PR 内补上 ③ 的测高换算，
  原始失败路径现在真正闭环。

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


- **[x] ② 已加自动化测试** — `hibiki/test/lookup/overlay_ctrl_wheel_zoom_test.dart`（9 条）
  + `hibiki/test/lookup/global_lookup_host_test.mjs` 新增 **Z1**（node harness，行为级）
  - 纯函数：净档数 → 字号折算、0 档、双侧夹死 8..72、顶到边界后返回原值（据此跳过无谓重渲）；
  - 分发：非本 handler 不拦截；本 handler 恒被吞掉且无 model 时不重渲；
  - 源码守卫：C++ 两项设置必须落在 `ConfigureWebView` 内；app 外注入必须有 ctrl 门控 +
    `popupZoomFontStep` + rAF 合帧，且**不得**出现 `style.zoom`（防止把几何毛病搬回来）；
    注入必须由 `globalLookup` 门控（防与 in-app `_zoomWheelJs` 双装一档滚两级）；
    两个 app 外表面都必须接线；
  - ③ 的几何换算有两层守卫：**行为级** node harness Z1（z=1 恒等 / z=2 按视觉高度报 /
    超上限仍收敛到卡上限 / 非法 zoom 回落 1）—— 已做**负向验证**：去掉换算那一行，
    Z1 以 `exit 1` 失败并精确报 “放大后窗口按视觉高度报，卡片底部不再被裁”，
    加回即 PASS；**源码级** Dart 守卫（`frameContentZoom` 存在且换算落在
    `measureContentHeight` 内），因为 node harness 不在 CI 里跑，只有 Dart 这层能挡住
    「删掉换算而 CI 依然全绿」。

- **[x] ③ 已修复：几何链认识 CSS zoom** — 复审发现 ① 不足以闭环，本段是真正让症状消失的一步。

  ① 只拆掉了「WebView2 原生 ZoomFactor」这个第二真值来源。但 `dictionaryFontSize` 对渲染的
  **唯一**作用是注入卡片 iframe 的 `documentElement.style.zoom`
  （`popup_settings_injection.dart` head，= `popupContentZoom(appUiScale, fs)` = `appUiScale × fs/16`；
  全仓没有任何一处用 `dictionaryFontSize` 生成 `font-size` CSS）。所以「重渲」换来的仍是 CSS zoom，
  只是把原生缩放换了个实现——几何链照样不认识它。

  **谁错了（只有高度错，宽度是对的）**：
  - 宽度**不需要补偿**：host 文档自身从不设 zoom（已 grep 确认 `global_lookup_host.js` 零处
    `style.zoom`），shell 几何是未缩放的 host CSS px；iframe 是 `width:100%/height:100%`
    （`global_lookup_host.js:1124-1125`）铺满 shell。z 只压缩 iframe **内部**的布局视口
    （`shellWidth/z` layout px）再按 z 画回去，视觉上始终铺满 shell。
    「放大 = 卡内视口变窄、行数变多」正是字号设置应有的语义，不是缺陷
    （复审初稿把它写成缺陷，是**过度断言**，此处订正）。
  - 高度**必须补偿**：标准化 CSS zoom 下 `body.scrollHeight / offsetHeight` 返回**未乘 z 的
    layout px**（本仓 `popup.js:4172` 的 `layoutStep = visualStep / popupCurrentZoom(scroller)`
    是同一语义的另一半），而卡片实际画出 `layout × z`。
    `measureContentHeight`（`global_lookup_host.js`）把这个 layout px 直接交给
    `measureAndReport`，后者用它算 union bbox 的 `maxBottom`（→ 窗口高度）和
    `shellRects`（→ `ApplyRoundedRegion` 的 window region）。
    → z>1 时窗口与 region 比内容矮 `1 − 1/z`，**卡片底部被窗口边缘裁掉、裁口外露出底下的应用**。

  **修法**：`global_lookup_host.js` 新增 `frameContentZoom(record)`（读该 iframe
  `documentElement.style.zoom`，非法/缺失/跨域抛错一律回落 1），`measureContentHeight` 返回
  `Math.ceil(layoutPx × z)`，把 layout px 换算成与 shell 几何同单位的 host CSS px。
  - 只改这**一个函数**：`measureContentHeight` 在全文件只有 1 个调用点（measureAndReport），
    host 此前零处 zoom 感知，没有第二份需要同步的镜像。
  - **z=1（默认 16px 字号 + 100% 界面大小）时是恒等变换**，`scrollHeight/offsetHeight` 本就是整数，
    `Math.ceil` 不改值 → 默认配置行为逐字节不变，回归面为零。
  - 「只收小、不撑大」的既有语义**没动**：换算后仍走原来的 `measured < height` 判据，
    内容视觉高度超过 planned frame 时依旧收敛到卡上限、内容在 iframe 内滚动。
  **🔴 红线：只有高度要换算，`onLinkClick` / `textSelected` 的 rect 绝不能跟着乘 z。**
  那条 rect 来自 popup.js 的 `getBoundingClientRect()`（6 处：`popup.js:1818/2382/2410/3254/3578/4218`）
  与 `selection.js:347-350` 的 `getClientRects()`，标准化 CSS zoom 下**已经是乘过 z 的 visual px**，
  而 iframe 视口 ≡ shell 尺寸 ≡ host CSS px，`anchorRectToScreen` 直接加 shell 偏移本就正确；
  再乘一次会让子卡锚点偏移 z 倍。全仓没有一处用 `offsetTop/offsetLeft` 产出这个 rect，
  不存在混用两套单位的隐患。（另：`popupRendered` / `contentHeight` 携带的高度是 layout px，
  但 host 只取 handler 名、Dart `global_lookup_controller.dart:1026` 显式忽略两者，
  全链路无人消费 ⇒ 当前无后果；已在 host.js 就地加注释标明这个陷阱。）

  剪贴板面板不受影响：`measureAndReport` 在 `layoutMode === 'panel'` 直接短路（面板窗 rect 固定、
  内容在 iframe 内滚动），所以本次换算实际只作用于瞬态覆盖窗 —— 真机回归别拿面板当验证场景。

  - 爆炸半径仅限 app 外浮窗：`global_lookup_host.js` 全仓**只有一份**
    （`find` 确认，不在 `assets/browser_extension/` 或 `tools/browser-extension/` 镜像里），
    只由 app 外覆盖窗 / 剪贴板面板的 host 页加载；in-app 弹窗（走
    `definition.js` 的 `contentHeight`）与浏览器扩展都不经过它，未被触碰。



- **备注**：本机验证 = `flutter analyze` 全量（含 test）零问题 + 本 bug 用例 9/9
  + node harness `global_lookup_host_test.mjs` 全绿（含新增 Z1，并做过负向验证）
  + 全量 `flutter test` 通过（唯一失败 `floating_lyric_click_through_guard_test` 是 develop
  既有红，由 PR#460 的 `SetTimer` 改动引入，与本 PR 无关，已另立单）
  + 早前 `flutter build windows --debug` 通过（两个 COM setter 编译验证）。
  **仍缺真机目视复测**：需在 Windows 上跑原始失败路径（Anki 上方开 app 外浮窗 → Ctrl+滚轮放大）。
  与复审初期的预期不同，③ 落地后**预期卡片不再被窗口边缘裁掉**；复测要确认的是：
  放大后卡片完整可见（底部不被裁、裁口外不再露出底下的应用）、字号逐档变、重开后记住档位、
  原生 Ctrl+加减 / 触控板捏合确实已失效，以及常驻剪贴板面板同样正常
  （面板窗尺寸固定、内容在 iframe 内滚动，不走窗口收缩那条路）。
  离屏 itest 取不到原生覆盖窗的像素（见 agent 文档的离屏能力边界），故这一步必须人工目视。
