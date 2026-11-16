## BUG-4747 · 嵌套查词：macOS 查词页点释义里的字查到相邻的字（WebKit 旧 zoom 坐标系 + 沙箱取字半字偏移）
- **报告**：2026-11-17（用户：应用内反馈 lfbYCEfnt7，macOS 查词页展开明鏡国語辞典「こんにち-は」，在释义里点「昼」「訪」，
  查词历史里记下的却是「間」「問したり…」「り訪問したり…」这类相邻字）
- **真实性**：✅ 真 bug，两条同症状的独立根因。
  1. **主文档释义（明鏡走这条）**：`fushi/assets/popup/selection.js` 的 `getCharacterAtPoint`（修复前 :546）和
     `charRangeInContainer`（修复前 :331）拿事件的 `clientX/Y` 直接比 `Range.getClientRects()` 的字框。弹窗把
     「界面大小 × 词典字号/16」写成 `documentElement.style.zoom`（`popup_settings_injection.dart:1261`），zoom ≠ 1。
     Blink / Firefox / 2025-10 起开了 `GetBoundingClientRectZoomedEnabled` 的 WebKit 里，字框与客户区坐标同单位；更早的
     WebKit（macOS / iOS 旧系统的 WKWebView）按节点有效 CSS zoom 再除一遍（WebKit `Document::convertAbsoluteToClientQuads` 在
     `zoomForClient` 返回 `usedZoom` 时：rect = (client + scroll) / zoom − scroll），而 `MouseEvent` 的客户区坐标只扣页面缩放。
     于是在 caret、caret±1 三个候选里命中的是「缩过之后」盖住点的邻字（±1），或者全不命中。Windows / Android 都是新 Blink，
     复现不了；查词串跨过 ruby（「り訪問したり…」）证明明鏡这条走的是主文档、不是沙箱 iframe。
  2. **带脚本的 HTML 释义（沙箱 iframe）**：`fushi/assets/popup/popup.js` 的 `DICT_SANDBOX_HELPER_JS`（修复前 :3717-3719）
     把 `caretRangeFromPoint` 的偏移直接当起点。caret 是离点最近的字间缝，点在字的右半边就指向下一个字——所有平台都有。
- **[x] ① 已修复** —
  1. `selection.js` 新增 `clientRectsZoomed`（两个探针 zoom:1 / zoom:2 比宽，探一次缓存）、`rectSpaceZoom`（旧 WebKit 下
     节点到根、跨 shadow 宿主的 CSS zoom 乘积）、`pointInRectSpace`（把客户区点换进字框坐标系）；`getCharacterAtPoint`、
     `charRangeInContainer`、`getSelectionRect` 一律先换算再比。标准引擎换算是恒等。
  2. 沙箱辅助脚本加 `hitOffset`：与 `getCharacterAtPoint` 同一判据，在 caret、caret−1、caret+1 里取字框真包含点的字，都不包含就不算点中。
  两份浏览器扩展 vendor 镜像同步。
- **[x] ② 已加自动化测试** —
  - `fushi/test/lookup/webkit_legacy_zoom_hit_bug4747_test.js`（+ `.dart` 包装）：node 在 fake DOM 里真执行 `selection.js`，
    按旧 WebKit / 标准两种引擎规则产出字框，zoom 1 / 1.25 / 0.8 / 1.5、滚动 0 / 180，点每个字的左 / 中 / 右都命中它本身（288 次点击）。
    修复前在 `legacy zoom=1.25` 第一次点击就红。
  - `fushi/test/pages/popup_dict_sandbox_harness.mjs` 场景 11：真 Chrome 里装生产沙箱辅助脚本，点「昼間訪問」各字左 / 右半边，
    查词串必须从被点的字起。修复前红（`昼,間,間,昼,訪,問,問,し`）。
- **备注**：未在 macOS 真机复测（本机 Windows，Blink 不复现旧 WebKit 的字框单位）；判据来自 WebKit 源码与上面的 fake DOM 模型。
  `getSelectionRect` 交给宿主定位嵌套弹窗的 rect 在旧 WebKit 下仍是字框坐标系，本条没改它的单位。
