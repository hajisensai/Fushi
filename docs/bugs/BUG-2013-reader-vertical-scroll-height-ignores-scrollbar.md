## BUG-2013 · 竖排滚动模式 body 高度未扣水平滚动条，末行文字被裁
- **报告**：2026-09-01（用户：滚动模式下「文字到滚动条底下了」，附桌面截图——竖排日文书每列底部的字只剩上半个）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/reader/reader_pagination_scripts.dart:3354`（`var contHeight = dartH || window.innerHeight;` → `:3356` 写进 `--fushi-continuous-height`）与 `:3389`（`updatePageSize` 用 Dart 传来的 `cssHeight`），消费方是 `fushi/lib/src/reader/reader_content_styles.dart:1098`（`_continuousLayoutCss` 竖排分支 `height: var(--fushi-continuous-height, 100vh)`，配 `:1119 box-sizing: border-box`）。

  竖排连续模式是**横向**滚动（`:1085` `hiddenOverflowAxis` 竖排取 `overflow-y`，于是 html 的 overflow-x 算成 auto、html 成为水平滚动容器）。桌面 WebView2 的水平滚动条是**占位式**的，从视口底部吃掉约 15px；移动端是不占位的 overlay 滚动条，所以这条只在桌面复现。

  而 `window.innerHeight` 与 Dart 传来的 MediaQuery 高度（`dartPageHeight` / `updatePageSize` 的 `cssHeight`）都是视口**外框**高度，**不扣**滚动条那条。body 是 border-box 且高度就取这个值 → body 最底部那 15px 落在滚动条之下 → 末行文字被裁掉大半。

  一句话根因：**「视口外框高度」和「可视内容高度」是两个概念，被当成了同一个数。**

  **实测证据**（Chromium 1200x800，复刻 `_continuousLayoutCss` 竖排分支的同一份 CSS + 同一段赋值逻辑）：
  ```
  innerHeight 705 / clientHeight 690 / 水平滚动条 15px / hasHScroll true
  喂 705 → maxTextBottom 705 > clientHeight 690   → textOverflowsVisible: true   ← 被裁
  喂 690 → maxTextBottom 690                       → textOverflowsVisible: false
  再量一轮 → 仍 690                                 → 不震荡
  内容短到无滚动条 → clientHeight 回到 705           → 不误缩
  ```
  文字底部超出可视区的量**正好等于水平滚动条高度**（15px），与截图里字被切掉大半吻合。

  横排连续不受此影响：横排是纵向滚动，滚动条占的是宽度不是高度，且横排分支用的是 `width: 100vw / min-height: 100vh`（`:1099-1101`），body 随内容长高。

- **[x] ① 已修复** — 连续 shell 新增 `_visibleViewportHeight(fallback)`（`reader_pagination_scripts.dart`，挂在连续 shell 的 `window.fushiReader` 对象字面量上，必定先于 `initialize`/`updatePageSize` 存在），取 `document.documentElement.clientHeight`——唯一扣掉滚动条的可视高度——并在未布局（`clientHeight` 为 0/undefined）时回退到外框高度，避免 body 高度塌成 0。两处写 `--fushi-continuous-height` 的赋值都改经它。

  刻意**不**改 `__fushiApplyReaderMargins` / `_contH` 的入参：那两处要的就是视口外框高度。既然根因是两个概念被混成一个数，修法就是把它们分开，而不是把另一处也一起改掉。

  已核 `__fushiApplyReaderMargins`（`reader_fushi/webview.part.dart:772-784`）只是把高度乘边距百分比算 `--reader-margin-top/bottom`：按 705 而非 690 算，5% 边距下差 0.75px；且 border-box 下 padding 计入那 690 之内，文字仍不会溢出可视区。改它没有收益，却会波及**共用**这个函数的分页模式，故不动。

  不会震荡：竖排水平滚动条的有无只由内容宽度（列数）决定，与 body 高度无关；高度调小只让每列变短、列数变多，滚动条照样在，`clientHeight` 保持稳定（已实测两轮）。

  爆炸半径：改动全部落在 `continuousShellSource`（行号 ≥2833），分页 shell（1958–2807）零改动；`--fushi-continuous-height` 本就只被连续模式竖排分支消费。

- **[x] ② 已加自动化测试** — `fushi/test/reader/continuous_vertical_scrollbar_height_test.dart`（4 条）：
  - 行为层 1 条：把**生产 JS** 里的 `_visibleViewportHeight` 函数字面量原样抽出，在 node 真跑（与既有 `reader_production_js_behavior_test.dart` 同一套做法，不在测试里另抄实现，否则抄的那份会和生产代码漂开）。四个场景：有滚动条(690)→690、无滚动条(705)→705、未布局(0)→回退、`clientHeight` 缺失→回退。
  - 源码层 3 条：`--fushi-continuous-height` 的赋值**一处不漏**都经过 `_visibleViewportHeight`（正则允许换行，避免 dart format 换行造成锚点漂移假红；同时钉住赋值点数量=2，新增/删除赋值点会要求复核）；`_visibleViewportHeight` 确实读 `documentElement.clientHeight` 且带 fallback；分页 shell 不得出现该变量或该 helper（防修复误扩散进分页几何、动到 `pageStep` 不变式）。
  - **变异实测**：把 `initialize` 那处赋值退回 `contHeight` → 守卫红并打印「实际写的是: contHeight」；还原后 `sha256` 回到 `07050a95…f1b2`。
- **复核补充（2026-09-01，审查轮）**：初版修复在两处各写各的 CSS 变量，审查时发现两个缺口，都已根因修掉。
  - **① 加定义域夹子**：`_visibleViewportHeight` 现在返回 `visible <= fallback` 时才取实测值。可视内容高度按**定义**不可能超过视口外框高度，超出就说明读到的不是本次布局的值。这不是保险起见的兜底，而是两个真实场景：iOS 上 `initialize` 里共用的 viewport meta 重写（`sharedInitViewportJs`）刚删掉并重建 `meta[name=viewport]`，隔 5 条语句就读 `clientHeight`，而 **BUG-1688 实测** WKWebView 在这次重写生效前按默认 980 CSS px 布局（`innerHeight=1743`，Dart 权威值 667）——若 WebKit 的重排不是同任务同步生效，这里会量到 1743，竖排 body 高度爆到 2.6 倍；而 iOS 是**不占位**的 overlay 滚动条，本修复在 iOS 上收益为零，不能让零收益的平台替桌面的修复背回归。quirks（书自己没写 doctype，Fushi 全程不补，见 `webview.part.dart:345 _buildSanitizedChapterHtmlBytes`）下 `clientHeight` 退化成 html 自身 padding box 高度，同理。桌面竖排正常值 690 ≤ 705，夹子不改变本 bug 的修复效果。
  - **② 收成唯一写入点并补上换字号路径**：新增 `_applyContinuousHeight(fallback)` 作为该变量的**唯一** `setProperty`，调用方三个：`initialize` / `updatePageSize` / `beginStyleReanchor`（两条分支各一次，插在 `_resetImageMaxVars()` 之前，与 `initialize` 里「先定高度再量图片盒」的顺序一致）。**为什么必须补**：改动之前这个变量只由**视口外框高度**决定，而外框高度只在 resize 时变，两个写入点就够；改取**可视高度**后它变成**内容相关**量——水平滚动条的有无由内容宽度（列数）决定，而改字号正是改列数。于是「首屏内容短 → 无滚动条 → 写 705」的书，用户放大字号后滚动条出现、变量仍是 705，末行照旧被裁，要等下一次 resize 才自愈。**这个失效源是本次改动新引入的**，不是存量问题，故在同一 PR 内补齐。
  - **变异实测**（各自按唯一锚点还原，sha256 均回到 `d512603b…6cd19`）：① 去掉 `<= fallback` → node 里真跑生产 JS 的行为用例红（`clientHeight(1743) 超过外框(667) 时应回退 667，实际 1743`）**且**源码守卫红；② 删掉 `beginStyleReanchor` 提前 return 分支的那次调用 → 调用点计数守卫红（`Expected: <4> Actual: <3>`）。
  - 另：初版注释里写了 `$_sharedInitViewport`，而连续 shell 是**插值字符串**，整段 viewport JS 被插进 `//` 注释行、把对象字面量打断——`reader_production_js_behavior_test` 与 `reader_engine_static_source_guard_test` 当场以 `SyntaxError: Unexpected token 'var'` 抓住。已改写掉该 `$`；这两条既有守卫的价值就在这里。
  - **兜底阶梯对齐 `initialize`**：`beginStyleReanchor` 里用 `this._contH || C.dartPageHeight || window.innerHeight`。`_contH` **只**在 `updatePageSize` 里赋值、对象字面量里没有初始化，而 `updatePageSize` 只在视口真变时才由 Dart 调 —— 「开书后不改窗口、直接改字号」是最常见路径，此时 `_contH` 全程 undefined。补 `C.dartPageHeight`（`C` 是连续 shell 的闭包入参 `window.__fushiShells.continuous = function(C)`）才与 `initialize` 的 `dartH || window.innerHeight` 同阶梯。**刻意不**在 `initialize` 里补 `this._contH = contHeight` 来让兜底精确：那会把首次 `updatePageSize` 的 `changed` 由 true 翻成 false、跳掉一次重锚，是行为改变，不在本条内顺手做。
  - **已知固有限制（不修，记账）**：三个写入点读 `clientHeight` 时 body 都还带着**旧**高度（`beginStyleReanchor` 里更是「新 CSS + 旧高度」），所以这是**一趟近似**，不保证一次到不动点。实测的「再量一轮仍 690」只覆盖了不动点场景，「一屏宽 ↔ 多屏宽」的临界章没覆盖。不要把它写成「一次即收敛」。
  - **全仓消费面已复核**：`--fushi-continuous-height` 全仓只有 1 个读点（`reader_content_styles.dart:1098` 竖排连续分支），写点收敛后为 1 个。

- **备注**：与 BUG-467（竖排「文字去到底栏」）不同域——那条是**分页**模式首载 chrome inset 偏小，结论明确写「CSS 本身正确」；本条是**连续**模式的视口高度取值，与 chrome inset 无关，把底栏完全隐藏也照样裁。另：横排连续分支的 `width: 100vw`（`:1100`）对垂直滚动条有同构隐患（`100vw` 同样不扣滚动条），但 html 那侧设了 `overflow-x: hidden`，表现与本条不同，未复现用户可见症状，**不在本条内顺手改**。
