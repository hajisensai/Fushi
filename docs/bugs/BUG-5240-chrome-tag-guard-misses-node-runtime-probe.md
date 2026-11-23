## BUG-5240 · Chrome 标签守卫漏掉 `NodeTestRuntime.probe(needsChrome: true)`，7 个 SRS 卡面套件可被派到无 Chrome 机器
- **报告**：2026-11-22（审查 HBK-AUDIT-225，起因 PR #4099）
- **真实性**：✅ 真 bug。`fushi/test/tools/dist_chrome_tag_guard_test.dart:40` 只认 `CHROME_EXECUTABLE` 与旧探测函数 `chromeAvailableVia(`，统一入口 `NodeTestRuntime.probe(needsChrome: true)`（`fushi/test/helpers/node_runtime.dart:120`）起 Chrome 却不被识别。`test/srs/srs_card_{anki_dom_contract,autoplay_gate,clamp_toggle,defs_layout,design_skin,remote_audio,translation_blur}_test.dart` 7 个文件走这个入口却没打 chrome 标签，dist 会把它们派给不具 Chrome 能力的 worker（无图形会话的机器上 headless Chrome 段错误 / 本地 skip）。
- **[x] ① 已修复** — 守卫判据加上 `needsChrome: true`（拼接产生，免得守卫自己命中），7 个文件补 `@Tags(<String>['chrome'])`。
- **[x] ② 已增加自动化测试** — 守卫本身即测试：修复前对 develop 跑会列出这 7 个文件；修复后为空。
- **备注**：
