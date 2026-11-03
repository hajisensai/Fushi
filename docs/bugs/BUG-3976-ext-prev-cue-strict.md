## BUG-3976 · 浏览器扩展「上一句」进句超过 600ms 只回本句句首
- **报告**：2026-11-02（用户反馈 DudosCydv0）
- **真实性**：✅ 真 bug（根因 `tools/browser-extension/subtitle-panel.js` shortcutSeekPrev 旧 1297-1303 行 `lastCueStartBefore(videoTimeMs() - 600)`：进句超过 600ms 命中本句自己，按键间隔超过 600ms 永远到不了上一句；App 侧 BUG-3791 已撤掉该语义，扩展未同步；旧测试 subtitle-modes.test.js:219-222 只测 500ms 把错误钉绿）
- **[x] ① 已修复** — 上一句改成与 App `prevCueIndexFor` / `_prevCueIndex` 同口径的严格「当前句的前一条」：句内 → idx-1，首句内返回 false 放行，句间空隙 → 刚播完那句；删掉 600ms 阈值。新增上一句/下一句的 seek 锚点（对齐 App `_seekTargetCueIndex`，只在紧贴锚句句首前 200ms 内生效），防 seek 落在句首前几毫秒时连按跨两句（分支 claude/review-merge-bug-fixes-b183d4，未提交）
- **[x] ② 已加自动化测试** — `tools/browser-extension/subtitle-modes.test.js`（改 4.8s 断言 + 新增「句内任意位置 / 空隙 / 首句」与「seek 落在句首前 5ms 只退一句」两条）
- **备注**：
