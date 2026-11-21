## BUG-4753 · 嵌套查词：macOS 查词页点释义里的字查到相邻的字（WebKit 旧 zoom 坐标系 + 沙箱取字半字偏移）
- **报告**：2026-11-17（用户：应用内反馈 lfbYCEfnt7，macOS 26.3（Build 25D125）查词页展开明鏡国語辞典「こんにち-は」，
  在释义里点「昼」「訪」，查词历史里记下的却是「間」「問したり…」「り訪問したり…」这类相邻字）
- **真实性**：✅ 真 bug，两条同症状的独立根因。
  1. **主文档释义（明鏡走这条）**：`fushi/assets/popup/selection.js` 的 `getCharacterAtPoint`（修复前 :546）和
     `charRangeInContainer`（修复前 :331）拿事件的 `clientX/Y` 直接比 `Range.getClientRects()` 的字框。弹窗把
     「界面大小 × 词典字号/16」写成 `documentElement.style.zoom`（`popup_settings_injection.dart:1261`），zoom ≠ 1。
     Blink / Firefox / Safari 26.4 起的 WebKit 里，字框与客户区坐标同单位；更早的 WebKit 按节点有效 CSS zoom 再除一遍
     （WebKit `Document::convertAbsoluteToClientQuads` 在 `zoomForClient` 返回 `usedZoom` 时：
     rect = (client + scroll) / zoom − scroll），而 `MouseEvent` 的客户区坐标只扣页面缩放。于是在 caret、caret±1 三个
     候选里命中的是「缩过之后」盖住点的邻字（±1），或者全不命中。查词串跨过 ruby（「り訪問したり…」）证明明鏡这条走的是
     主文档、不是沙箱 iframe。
     - **用户系统正好是旧单位的直接证据**：WebKit 官方 Safari Technology Preview 232 发布说明（2025-11-12，
       https://webkit.org/?p=17601 ）与「WebKit Features for Safari 26.4」（https://webkit.org/?p=17862 ）都写了
       「Fixed getBoundingClientRect and getClientRects to return scaled lengths according to CSS zoom」。反馈设备是
       macOS 26.3，WKWebView 用系统 WebKit，正是修复前的版本。
     - **为什么上一轮分诊复现不了**：上一轮在 Playwright WebKit（26.4）上用 0.85–1.5 的 zoom 试，26.4 已经是新单位，
       必然复现不出来；Windows（WebView2）/ Android（Chromium）同理。那次排除不了、也不能反证本根因。
  2. **带脚本的 HTML 释义（沙箱 iframe）**：`fushi/assets/popup/popup.js` 的 `DICT_SANDBOX_HELPER_JS`（修复前 :3717-3719）
     把 `caretRangeFromPoint` 的偏移直接当起点。caret 是离点最近的字间缝，点在字的右半边就指向下一个字——所有平台都有。
  3. **同根因的位置偏移**（不是点错字，是锚点偏）：旧 WebKit 下交给宿主的 `getSelectionRect`（嵌套弹窗锚点，扩展
     `content.js` 也用它锚页面弹窗）、`highlightSelection` 返回的整词 bbox（BUG-2054 重锚）、汉字卡点大字时上报的
     `onLinkClick` rect，以及语法浮层定位（BUG-2042 的换算假设元素框已是视觉 px，旧 WebKit 下会再除一次 z）都按 zoom 偏。
- **[x] ① 已修复** —
  1. `selection.js` 新增 `clientRectsZoomed`（两个挂在 documentElement 上的探针 zoom:1 / zoom:2 比宽，探一次缓存，量不出
     也按标准缓存，不反复插拔探针）、`rectSpaceZoom`（旧 WebKit 下节点到根、跨 shadow 宿主的 CSS zoom 乘积）、
     `pointInRectSpace`（客户区点 → 字框坐标系）、`rectToClientSpace` / `clientRectOf`（字框 / 元素框 → 客户区）。
     `getCharacterAtPoint`、`charRangeInContainer` 命中前先换点；`getSelectionRect`、`highlightSelection` 交给宿主前把框
     换回客户区。标准引擎下全部恒等。
  2. `popup.js` 加 `__fushiClientRect`，只转调 `fushiSelection.clientRectOf`（判据只在 selection.js 一处）；语法浮层定位
     与汉字卡上报 rect 改用它。
  3. 沙箱辅助脚本加 `hitOffset`：与 `getCharacterAtPoint` 同一判据，在 caret、caret−1、caret+1 里取字框真包含点的字，
     都不包含就不算点中。
  两份浏览器扩展 vendor 镜像同步。
  - **兼容层的影响范围与清理条件**（写在 `selection.js` 的注释里）：影响 macOS / iOS 26.3 及更早系统的 WKWebView（扩展则是
    Safari < 26.4）；app 在 macOS / iOS 的最低支持系统 ≥ 26.4（且扩展要求 Safari ≥ 26.4）时，整套探测与换算连同
    `__fushiClientRect` 删掉，调用点直接用原始坐标。
- **[x] ② 已加自动化测试** —
  - `fushi/test/lookup/webkit_legacy_zoom_hit_bug4753_test.js`（+ `.dart` 包装）：node 在 fake DOM 里真执行 `selection.js`，
    按旧 WebKit / 标准两种引擎规则产出字框，zoom 1 / 1.25 / 0.8 / 1.5、滚动 0 / 180，点每个字的左 / 中 / 右都命中它本身
    （288 次点击），且 `getSelectionRect` / `highlightSelection` / `clientRectOf` 都回到客户区坐标。修复前在
    `legacy zoom=1.25` 第一次点击就红；只去掉 `getSelectionRect` 或 `highlightSelection` 的换算也各自变红。
    注意 fake DOM 的旧 WebKit 字框公式是按 WebKit 源码写进模型的，它证明换算与该公式一致；WebKit 真实行为的证据是上面的
    Safari 26.4 发布说明。
  - `tools/browser-extension/grammar-tooltip-single-surface.test.js`「BUG-4753」条：切真 `popup.js` 的语法浮层，元素框按旧
    WebKit 报成视觉 px / zoom，断言经 `clientRectOf` 后与标准引擎同一落点；把浮层改回直接 `getBoundingClientRect` 即红。
  - `fushi/test/pages/popup_dict_sandbox_harness.mjs` 场景 11：真 Chrome 里装生产沙箱辅助脚本，点「昼間訪問」各字左 / 右半边，
    查词串必须从被点的字起。修复前红（`昼,間,間,昼,訪,問,問,し`）。
- **备注**：
  - 未在 macOS 26.3 真机复测（本机 Windows；Playwright WebKit 是 26.4，已是新单位）。
  - 沙箱 iframe 的 `hitOffset` 只修了半字偏移，没做字框坐标系换算（沙箱里没有 selection.js）。如果旧 WebKit 下宿主
    documentElement 的 zoom 会进入 sandbox iframe 内部节点的有效 zoom，沙箱这条在 26.3 上仍可能命中邻字；WebKit 的 CSS zoom
    是否跨 frame 传递未验证，属于已知边界。
  - 弹窗里另一批按钮提示 / 菜单（`showInlineHint`、`__fushiShowButtonTip`、`showNoAudioHint`）把元素框直接写进 style
    left/top，在标准引擎下本来就没按 zoom 折算，是另一个问题，未在本条改动；音频源菜单是按实测比例换算，与单位无关。
