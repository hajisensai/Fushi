## BUG-1827 · 查词弹窗释义里的不可断短语溢出词典卡
- **报告**：2026-08-24（用户：「查词的字出了框」，截图为三栏并排查词结果，某栏有内容画到栏外、压在左边那栏的正文上。用户先后澄清：不是嵌套弹窗、是正常查词；「那就不叫音标，可能是斜体的单词之类的」）
- **真实性**：✅ 真 bug。根因 `fushi/assets/popup/popup.css` 的 `.glossary-group` 从未声明断词规则，卡内**找不到断点的短语**会画到卡片外。

### 根因（实测取证）

典型样本是释义里的 `somebody/something` 这类 `词/词` 短语：UAX #14 把 `/` 归为 **SY** 类，而 **`SY × AL`（斜杠后紧跟字母）不允许断行**，整个短语于是是一个不可断单元。它的 min-content 宽度就是整串宽度：

- CSS grid 回落模式下撑破 `.glossary-section > .category-body` 的 `minmax(0, 1fr)` track；
- masonry 模式下更直接——卡片是 `position:absolute` + JS 硬设 `width: columnWidth`（`popup.js layoutMasonry`），盒子宽度钉死撑不大，于是**内容整条溢出到卡外**，而 `.glossary-group` 没有任何 overflow 裁剪，溢出部分正好压在相邻列的正文上。

headless Edge 实测（载入**完整** popup.css，复刻 `layoutMasonry` 的几何 + `DICT_COLUMN_MIN_WIDTH`=170px 最窄列宽，用 `getClientRects()` **逐换行片段**量右边界与卡片内容盒之差）：

| `resting on the surface of <i>somebody/something</i>` | 片段数 | 最差片段越界 |
|---|---|---|
| 未修（`.glossary-group` 无断词规则） | 1 | **+1.91px** |
| 加 `overflow-wrap: anywhere` | 2（折行） | **−15.41px**（框内） |

BUG-860 当时只给 `<a>` 加过这条规则（那次的长串恰好是裸 URL），但「找不到断点」与元素是不是链接无关——释义里的斜体词组、结构化内容里的长词一概漏在保护外。

### 三次测量教训（本条的主要成本都花在这里）

1. **`scrollWidth - clientWidth` 量不出文字出框**：溢出的**内联文本**不增加块元素的 `scrollWidth`（它只反映滚动区域），修复前后都得 0 —— 恒为 0 的无效测量。是「修复前必须为真」的对照法暴露了它，否则会拿到假绿。
2. **`getBoundingClientRect()` 对跨行 inline 元素返回所有片段的并集**：一个占满整行的片段会让并集右边界贴住容器右缘，读起来像越界却不是任何单行的真实越界量。必须用 `getClientRects()` 逐片段量。
3. **拿一个能自然断行的样本否定了整个假设**：第一轮反例用的是 IPA 串 `/ˌɪntəˈnæʃn̩ˈoʊvər.../`，它含 `(` `)`（OP 类，前面可断）所以自行折成 2 行、出框 0px，据此曾错误地写下「假设 A 已排除」并提交过一版（`3a832ebef1`）。实际 `词/词` 短语才是不可断的那类。**样本能断 ≠ 该类内容都能断。**

另外排除了一条：曾怀疑「弹窗宽度变化后 masonry 不重排」（`ResizeObserver` 确实只观察 item 不观察容器）。否定理由：app 内查词弹窗**整个 WebView 就是弹窗**，宽度变化即 viewport 变化，`window.addEventListener('resize', scheduleMasonry)` 会正常触发重排。该假设只在浏览器扩展形态下才可能成立。

- **[x] ① 已修复** — `.glossary-group` 加 `overflow-wrap: anywhere`（继承属性，一次声明覆盖卡内全部后代，消除「哪些元素受保护」这个特殊情况，而不是再给某类内容补选择器）。用 `anywhere` 而非 `break-word`：两者都只在没有其它断点时才任意处折行（正常带空格文本与 CJK 不受影响），但只有 `anywhere` 同时**缩小 min-content**，卡片才不会被撑宽。已同步三份 popup.css 镜像并重跑 `generate-content-css.mjs` 生成两份 content.css。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/popup_glossary_overflow_wrap_guard_test.dart`（4 tests）。断言全部跑在剥 CSS 注释之后（修复注释里就有 `overflow-wrap` / `anywhere` 字样，朴素匹配会被注释假阳性命中）。覆盖三份 popup.css + 两份 content.css，并交叉断言 BUG-860 的 `a{}` 规则未被当作冗余删掉。
- **备注**：**遗留未解决**——斜体另有 2~3px 的 **ink overflow**（字形墨迹超出 advance width，canvas `actualBoundingBoxRight` 实测 `formal` 3.31px vs 正体 0.63px）。它不受 `overflow-wrap` 影响，只在文本正好顶满行宽时露出几像素。试过给斜体加 `padding-inline-end` 补偿，实测反而把 layout 越界从 +1.91px 推到 **+3.09px**（padding 加宽了 inline 盒），故**不采用**，留待需要时再解。本条**未做真机复测**，证据是 headless Edge 对同一份完整 popup.css 的 before/after 几何测量。
