## BUG-1007 · 游戏工作台健康卡 Anki 行恒显未配置
- **报告**：2026-07-22（来源：UI/UX 巡检，非用户报告）
- **真实性**：✅ 真 bug（代码路径已验真）。根因 `hibiki/lib/src/pages/implementations/texthooker_page.dart:1239-1243`：`_HealthRow(label: t.game_health_anki, value: t.game_status_not_configured, ready: false)` 三个参数全部写死——用户配置好 AnkiConnect/AnkiDroid 后，捕获健康卡的 Anki 行仍恒显「未配置」+ 灰色未就绪图标，是永久假状态。
- **[x] ① 已修复**（PR#332）— 页面顶层 `ref.watch(ankiViewModelProvider.select((s) => s.isConfigured))` 取真实已配置判定（`texthooker_page.dart:651`），沿 `ankiConfigured` 透传给 `_CaptureHealthCard`（`:676` / `:1225` / `:1232`），Anki 行改为按真值渲染 `value: ankiConfigured ? t.game_status_ready : t.game_status_not_configured, ready: ankiConfigured`（`:1287-1291`），写死值删除。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/texthooker_page_test.dart`：注入 fake `platformServicesProvider` + `SharedPreferences.setMockInitialValues`，令健康卡走真实 `AnkiViewModel → ankiRepositoryProvider` 接线路径渲染（此前写死时该路径根本不被触达）。后续可加「强制 isConfigured=true 断言行翻到 ready」的判别性断言进一步收紧。
- **备注**：巡检报告 `docs/reviews/2026-07-22-ui-ux-survey.md` 游戏模块；随游戏模块 UI 重构 PR#332 一并修复。
