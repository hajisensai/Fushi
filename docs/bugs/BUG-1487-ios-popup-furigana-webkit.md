## BUG-1487 · iOS 查词弹窗振假名渲染异常
- **报告**：2026-08-10（用户：振假名有 bug，iOS 端 / 确认是查词弹窗内的振假名；用户附的两张截图哈希文件名未落盘，调查时**没有视觉证据**，全靠沿真实渲染路径复现）
- **真实性**：✅ **真 bug（真机复现 + 双引擎对照测量定位）**。根因不在 iOS 特有代码，而在一条**只有 Blink 才认**的 CSS 契约：`fushi/assets/popup/popup.css` 原 `:where(.glossary-group, .glossary-content, .expression) rt { position: absolute; left:0; right:0; top:0 }`（改前 948-957 行）把振假名的定位职责压在 `<rt>` 元素上。**WebKit 在渲染器层面对 `<rt>` 无条件强制 `position: static`，作者 CSS 覆盖不掉**，于是这条规则在 iOS / macOS（两个 WKWebView 平台）被整条静默丢弃，而 Windows WebView2 / Android WebView（均 Blink）照常生效——同一份资源，两种渲染。
  - 真机测量（macOS 15.7 WKWebView + iOS 18.6 模拟器，同一份 DOM）：`getComputedStyle(rt).position === "static"`、`.display === "inline"`；`.ruby-unit` 的 `position: relative` / `padding-top: 8.25px` **正常生效**，证明不是选择器问题、被特判的只有 `rt` 这个标签。
  - 后果：读音掉回内联流，以半角小字排在**汉字右侧**、与基字**共用同一条基线**，渲染成 `将しょう棋ぎ`；`.ruby-unit` 宽被读音撑大约 60%（37.5px vs Blink 的 22.5px），词形被打断；而 `padding-top: 0.55em` 预留出来的上方空白**全空**。
  - 对照：Blink 同一 markup 量得 rt 盒 = (unit.x, unit.y, 22.5×7.5)，正确落在预留带内；WebKit 量得 (unit.x+15, unit.y+13.25)，在汉字旁边。
  - WebKit 源码侧佐证：`Source/WebCore/style/StyleAdjuster.cpp` 里针对 `rtTag` 的 `position` 重置在 17.x / 18.x / 26.x / main **全部在位**；2024-03 的 ruby 重写（Safari 17.4，commit `18e217e0c199` 删除 `RenderRuby*`）并未改变这一点。
- **[x] ① 已修复** — 定位职责从 `<rt>` 移到中性的 `<span class="ruby-rt">` 包裹层：`fushi/assets/popup/popup.css:984`（`.ruby-rt` 承担 `position/left/right/top` + `font-size: 0.5em` 的 em 链）、`:998`（`rt` 只剩 `display:inline` + fallback 字号 + `line-height:1`）、`:1012`（`.ruby-rt rt { font-size: 1em }` 防叠乘）；JS 侧 `fushi/assets/popup/popup.js:3418` 的 `postProcessRuby` 建 wrapper 并把 `<rt>` 搬进去。
  **为什么不是别的修法**：
  - ❌ 在 `rt` 上加 `display: block` 再定位——实测无效**且有害**：WebKit 接受 `display: block`（computed 变 block）但 `position` 仍是 `static`，读音改为落在汉字**正下方**（ruby 高 23.25→31，下振り仮名），方向反了。证明这个重置**不是 display 驱动**的。
  - ❌ 把 `<rt>` 换成普通 span——虽然定位能生效，但会丢掉语义、`selection.js` 的 `closest('rt, rp')` 查词选区（BUG-110/123/125/129）、`.expression rt` 的 user-select 规则和词典自带的 `rt {}` 自定义 CSS。
  - ❌ 退回原生 ruby 布局——会同时回退 BUG-108/363（行盒 leading 预留）与 BUG-345/850（逐字 ruby 横向紧凑），这些正是当年放弃原生布局的原因。
  - ✅ 外层 wrapper 是唯一同时满足「两引擎都尊重」「`<rt>` 语义保留」「读音仍完全脱流（不撑宽 base，BUG-345/850 不回归）」的解。注意**内层** span（塞在 `<rt>` 里面）不行：那样 `<rt>` 自身仍在流内，会重新撑宽 `.ruby-unit`。
  - 提交：见本分支 commit。三镜像（`fushi/assets/popup/` + `fushi/assets/browser_extension/vendor/` + `tools/browser-extension/vendor/`）已同步，两份 `content.css` 走 `tools/browser-extension/scripts/generate-content-css.mjs` 重新生成（未手改产物）。
- **[x] ② 已加自动化测试** —
  - `fushi/test/pages/popup_glossary_ruby_lineheight_guard_test.dart`：新增「绝对锚点**不得**声明在 `<rt>` 上」（`position` / `top|left|right|bottom` 一律不许出现在 rt 规则体里），原「注音盒 absolute + top:0 + 无 bottom:100%」断言迁到 `.ruby-rt`。
  - `fushi/test/pages/popup_glossary_ruby_per_base_anchor_guard_test.dart`：断言 `postProcessRuby` 真的建 `.ruby-rt`、把它挂到 `.ruby-unit`、并把 `<rt>` 搬进去（三段都钉死）。
  - `fushi/test/pages/popup_glossary_ruby_element_base_test.js`：新增 Case 7（BUG-1487），对裸文本 base 与 `<rb>` 元素 base 两种形态断言 `rtBoxes == 2` 且 `rtBareInUnits == 0`；原 BUG-733/722 的 rt 计数改为子树计数（语义不变，`rtDirectlyUnderRuby == 0` 这条抓 bug 的断言原样保留）。
  - `test/js/popup_ruby_selection.test.mjs`：fixture 换成新的真实 DOM（带 `.ruby-rt`），jsdom 实跑确认查词选区行为不变——BUG-110/123/125/129 不回归的直接行为证据。
  - `fushi/test/pages/popup_headword_ruby_reserve_bug1098_test.dart`：作用域清单与 content.css 生成物核对加入 `.ruby-rt`。
  - **变异实测**（两轮，均反向替换还原，未对未提交文件用 `git checkout --`）：① 把 `position: absolute; top: 0` 加回 `rt` 规则 → lineheight guard 的 BUG-1487 条变红；② 把 JS 还原成 `unit.appendChild(sib)`（精确重现修复前行为）→ per-base anchor guard 变红（Dart）、element_base 行为测试变红（node 真实退出码 1，报 `each reading needs its own .ruby-rt positioning box (BUG-1487); got 0`）。
- **备注**：
  - **验证证据**：四轮探针，全部在真 WKWebView 上跑（macOS 15.7 无头 Swift + WKWebView，另在 iOS 18.6 模拟器 Safari 截图复核，两侧 computed 值逐字段一致），Blink 侧用 headless Chrome 151 做对照。最后一轮 probe4 用的是**真实发货产物**——整份真 `popup.css` 内联 + 从真 `popup.js` 原样抽出的 `postProcessRuby()`，不是手写复刻。结果：`domShape {units:2, rtBoxes:2, rtStillDirectChildOfRuby:0, rtInsideAnnBox:true}`、`annPosition: absolute`、`annAboveBase: true`、`annOffsetFromUnitTop: 0`、`annOverlapPx: 0`、`unitWidths: [22.5, 15]`，与 Blink 逐项一致（唯一差异是注音盒高 7px vs 7.5px，7.5px 字号下 `line-height:1` 的 strut 取整 + 字体度量差；两侧都稳落在 8.25px 的 padding 带内，WebKit 余量反而更大）。
  - **两条如实观察（不是缺陷，但记下来免得被当成回归重查）**：
    1. `教法` 这类逐字 ruby，两个读音在视觉上零间隙、连成一串「きょうほう」。因为注音盒宽恒等于 unit 宽（`left:0;right:0`），而 `きょう` = 3×7.5 = 22.5px 恰好填满 22.5px 的盒、`ほう` = 2×7.5 = 15px 填满 15px 的盒，两盒**相切**——`annOverlapPx: 0` 是相切不是重叠。**Blink 侧盒宽逐项相同，两引擎表现一致，不是 WebKit 回归**。要让同一 ruby 内相邻读音恒有视觉分隔是另一个产品决策，不在本次范围。
    2. `将棋` 行 `annCollidesPrevLine` 通过但字面余量 0.0px（`prevLineBottom = 27`，`ann[0].y = 27`）。27 是上一行**行盒**底边（含下沉空间），注音是绝对定位在 ruby 自己行盒顶部的，结构上不会越界；真正的安全余量是「注音盒 7px vs `padding-top` 8.25px」的 1.25px。
  - **影响面**：`macOS` 与 `iOS` 同为 WKWebView，所以 macOS 端本应同症；用户只报 iOS，推测只是没在 macOS 上用查词弹窗。Windows / Android 不受影响（Blink），本次改动在 Blink 上实测像素级零变化。**阅读器正文的振假名不受此 bug 影响**——`fushi/lib/src/reader/reader_content_styles.dart:1108` 走的是原生 ruby 布局（`rt { display: ruby-text !important }`），从不给 rt 加 position，是独立机制。
  - **⚠️ 已知次级风险，本次未处理（无用户证据，不做投机修改）**：iOS 的 text autosizing（`TextAutosizingEnabled` 在 iOS WKWebView 为 true、macOS 全线 false）只放大**直接含文本子节点**的元素，且写的是 `computedSize`——而 `em` 正按 `computedSize` 解析。`<rt>` / `.ruby-reserve` 直接含文本会被放大，`.ruby-unit`（子节点全是元素）不会，理论上能让 em 链脱钩。此风险**修复前后完全相同**（不是本次引入），且探针页因文本量太小未触发 legacy 聚簇门槛，故未复现。若日后出现「iOS 上振假名字号忽大忽小/横向预留算不准」，先查这里：解法是给弹窗文档显式写 `-webkit-text-size-adjust: 100%`（写 `none` 会禁掉用户缩放）并确保 `<meta name="viewport" content="width=device-width">`。
  - **未验证缺口**：没有在**真机 iPhone**（只有 iOS 18.6 模拟器）、没有在 iPad（idempotent autosizing 曲线与 iPhone 不同）上验证；没有在真实 app 内跑完整查词弹窗（探针是隔离页面，但用的是真实 CSS+JS 产物）。用户若仍报问题，请让其说明是「叠印 / 错位 / 被裁切 / 完全不显示 / 读音跑到汉字旁边或下方」中的哪一种，并重发截图。
