## BUG-1007 · 游戏工作台健康卡 Anki 行恒显未配置
- **报告**：2026-07-22（来源：UI/UX 巡检，非用户报告）
- **真实性**：✅ 真 bug（代码路径已验真）。根因 `hibiki/lib/src/pages/implementations/texthooker_page.dart:1239-1243`：`_HealthRow(label: t.game_health_anki, value: t.game_status_not_configured, ready: false)` 三个参数全部写死——用户配置好 AnkiConnect/AnkiDroid 后，捕获健康卡的 Anki 行仍恒显「未配置」+ 灰色未就绪图标，是永久假状态。
- **[ ] ① 未修复** — 修法：接真实 Anki 配置状态（AnkiViewModel / anki repository 的已配置判定），或在真值可得前先删掉该占位行。
- **[ ] ② 未加自动化测试** — 建议 widget 测试：mock Anki 已配置态断言该行 ready/文案变化。
- **备注**：巡检报告 `docs/reviews/2026-07-22-ui-ux-survey.md` 游戏模块；计划随游戏模块 UI 重构 PR 一并修复。
