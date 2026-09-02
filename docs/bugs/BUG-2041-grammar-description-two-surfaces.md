## BUG-2041 · 语法说明有 hover 浮层和点击全屏卡片两套呈现，交互不统一
- **报告**：2026-09-02（用户：「查词弹窗语法说明浮层 到底用不用点击，点击和不点击的统一改一下吧」。此前 BUG-2037/2038 两张截图正好各是其中一套。）
- **真实性**：✅ 真 bug。同一段 `data-description` 有两套完全独立的呈现：
  | | 点击 `.overlay` | hover `.grammar-tooltip` |
  |---|---|---|
  | DOM | `popup.html` 静态节点 | JS 懒创建 |
  | 定位 | `position:fixed; inset:8px` 铺满弹窗 | fixed + JS 按锚点算 |
  | 标题 | 有（`.overlay-title` 26px） | 无 |
  | 关闭 | X 按钮 | mouseleave / scroll / pointerdown |
  | 背景 / 字号 | `--background-color` / 15px | `--surface-container-high` / 12px |
  - 入口：`popup.js` `createDeinflectionTag` 的 `onclick → showDescription` 与 `onmouseenter → showGrammarTooltip`。`showDescription` / `closeOverlay` / `.overlay` 三者**只服务这一处**，无其它消费者（已全仓核实）。
  - **附带的既存缺陷**：`.overlay` 是 `popup.html` 顶层静态节点，**不在 `.entry` 内**，所以点它正文会一路落到 `popup.js` 末尾 document click 的 `tapOutside` 分支 —— 点说明正文就把整个查词窗（或后代层）关掉。
  - 对照：原生弹窗 `dictionary_popup_native.dart:_showGrammarDescription` 只有点击一种语义（对话框：变形名标题 + 可选中说明 + 关闭），本来就是干净的。
- **[x] ① 已修复** — 收成**一套呈现**：hover = 预览（不钉住、`pointer-events:none`、移开即收），click = 钉住（`.is-pinned`：可交互、可选中复制、字号回正文档位、显示变形名标题与关闭按钮），再点同一枚 = 收起（toggle）。
  - 触屏无 hover，只走 click 分支 → 原 `.overlay` 的职责由钉住态承接；hover 能力门只挡预览，不挡钉住。
  - 原 `.overlay` 存在的唯一理由是「窄屏放不下浮层」，改由 `showGrammarTooltip` 按视口现算 `max-width`（`min(460, 视口-16)`）承担，窄屏自己收成贴边卡片。
  - 删除 `showDescription` / `closeOverlay` / `popup.html` 的 `.overlay` 节点 / `popup.css` 的 `.overlay*` 五条规则；两处渲染清理只留 `hideGrammarTooltip()`（它已接管清空语义）。
  - document click dismiss 分支显式豁免 `.grammar-tooltip`，根除上面那条附带缺陷。
  - 三镜像（`assets/popup` + 两份 `vendor/`）已同步，`content.css` 已重生成。
- **[x] ② 已加自动化测试** — 两层，分工明确：
  - **行为层**（能抓逻辑退化）`tools/browser-extension/grammar-tooltip-single-surface.test.js`：切 popup.js 真源码（浮层三函数 + `createDeinflectionTag`）丢进 `vm` 真执行，17 条覆盖 点击=钉住 / 再点=收起 / hover=预览 / 钉住后 hover 与 mouseleave 不动摇 / 无说明标签不可点 / 触屏预览被抑制但点击可用 / 点浮层自身与钉住锚点不收起 / 点别处收起。
  - **结构层** `fushi/test/dictionary/grammar_description_single_surface_guard_test.dart`：钉「旧那套没复活、三镜像没漏同步、dismiss 豁免还在、窄屏自适应还在」，注释遮罩走 `test/helpers/source_guard.dart` 的 `maskJsComments/maskCssComments`。
  - **变异实测**：6 个变异逐个让对应测试变红（点击不钉住 / 钉住被 hover 门挡住 / pointerdown 不豁免浮层 / 不折算 zoom / 删 dismiss 豁免 / 删钉住态样式），还原后 `popup.js`、`popup.css` 的 sha256 均回到基线。其中「点击不钉住」第一轮**没被抓到**，暴露出行为测试漏切 `createDeinflectionTag`（用户问题的正主），已补测试后重测通过。
- **备注**：同一轮顺带修了 BUG-2042（浮层定位未按 zoom 折算）。变形名（`-ちゃう` / `causative`）是语言学标签，不翻译；说明文字的本地化见 BUG-2038。
