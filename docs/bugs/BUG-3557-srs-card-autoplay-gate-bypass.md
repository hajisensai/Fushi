## BUG-3557 · 复习：牌组关了自动播放，卡面脚本插入后再设 autoplay / 不进页面的 Audio / shadow DOM / iframe 的 play 仍会出声（BUG-3546 修得不完整）
- **报告**：2026-10-19（PR #2336 审查遗留，协调要求根本性修复）
- **真实性**：✅ 真 bug，真实 headless Chrome（--autoplay-policy=no-user-gesture-required，对应 WebView2 实际策略）复现：旧闸门关时，插入后 `el.autoplay = true`、`setAttribute('autoplay')`、`new Audio()` + autoplay、shadow DOM 里带 autoplay 的 audio、借 iframe 里的 play 调用，5 条路径仍出声。根因（修前）`fushi/lib/src/srs/srs_card_autoplay.dart` `kSrsCardAutoplayGateScript` 只守 `HTMLMediaElement.prototype.play` 与「插入时带 autoplay」，MutationObserver 只看新插入节点。
- **[x] ① 已修复** — 闸门在播放入口统一收口：`play()` 包装（手势外拒绝）、`autoplay` setter 包装、`setAttribute` / `setAttributeNS` / `toggleAttribute` 写 autoplay 拦截、页面与每个 shadow root 捕获 `play` 事件兜底 pause（`attachShadow` 钩子）；带 controls 且有用户激活时放行原生控件点按。宿主 [sound:] 与手动重播走原生播放器不受影响。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_card_autoplay_gate_harness.mjs`（真实 Chrome，11 条路径开 / 关各一遍 + 手势 / 键盘 / 原生控件放行 + 手势外拒绝，共 26 项）由 `srs_card_autoplay_gate_test.dart` 驱动；变异实测：换回旧闸门 9 项红，逐个去掉 play 包装 / setter / setAttribute / play 事件兜底 / attachShadow / 控件放行各自红。
- **备注**：仍管不到（推测）：卡片里嵌的 iframe 自己的文档；不进页面的元素用 setAttributeNode 设 autoplay；刚有用户激活（约 5 秒）时带 controls 的元素被脚本经其它途径开播会当作用户点控件放行。
