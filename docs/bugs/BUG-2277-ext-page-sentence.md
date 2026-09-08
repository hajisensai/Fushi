## BUG-2277 · 浏览器扩展查词/制卡不取页面所在句子
- **报告**：2026-09-08（用户：「现在的浏览器拓展查词为什么不取所在句子」）
- **真实性**：✅ 真 bug。制卡例句的来源全部绑在**字幕**上，没有一级从页面正文取句：
  `tools/browser-extension/bridge-shim.js:30`
  `var sentence = ctxSentence || cueText || trackText || (args[0] && args[0].popupSelectionText) || ''`
  —— ⓪多句合一草稿、①Netflix 字幕 DOM、②当前字幕行（`fushiMineContext().window.text`）、③弹窗内选区。
  在普通网页（无字幕轨、无视频）上前三级恒空，用户又没在弹窗里选任何文本 → 例句为空。
  句子其实一直在页面 DOM 里：`tools/browser-extension/vendor/selection.js:140` 有一份与 app 阅读器
  同源的 `getSentence(node, offset)`（跨文本节点扩句、跳振假名/`.ruby-reserve`、括号配平），manifest
  把它装进了 content script，但**全仓零调用**（`grep -rn "getSentence" tools/browser-extension` 只有
  定义处）。查词命中的 `(文本节点, 字符偏移)` 就在 `content.js` 的 mousemove 处理器手里
  （`content.js:1861` 的 `hit`），发完查词就被丢掉，制卡时再也拿不回来。
- **[x] ① 已修复** — `tools/browser-extension/content.js`：查词时把命中点存成锚点
  （`fushiPendingLookupAnchor`，与 `fushiPendingCueWindow` 同一契约：每次查词刷新，不传即清空），
  制卡要句子时才惰性调 `fushiSelection.getSentence` 并缓存（Shift 悬停是每几像素一次的高频路径，
  不在那里算句），结果经 `fushiMineContext().pageSentence` 交出；`bridge-shim.js` 的例句优先级补上
  第 ④ 级（排在弹窗内选区之后 → 字幕站点与用户显式选区行为逐字不变）。无句末标点的超长块
  （> 200 字）判定为「没有可用句子」，宁可留空也不把一整段塞进 Anki 字段。
- **[x] ② 已加自动化测试** — `tools/browser-extension/page-sentence.test.js`（8 条）：在受控 vm 里真装
  bridge-shim + subtitle-adapters/providers + content.js，触发带 Shift 的 mousemove，断言
  `pageSentence` = 命中点所在整句、该句真的进了 `/api/mine` 的 `sentence`、取句惰性且同一次查词只算
  一次、换词必重算、侧栏直发词（无页面锚点）取不到句、超长块留空，以及两条不夺权守卫
  （有字幕行时仍用字幕轨；有弹窗内选区时仍用选区）。
- **备注**：只影响扩展侧；app 内阅读器/视频页走 Flutter handler，本来就有句子上下文，未改动。
