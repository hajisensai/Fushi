## BUG-3873 · Kavita→Fushi 进度拉取失效（时间基线 + 容差吞掉服务器改动）
- **报告**：2026-10-28（用户：Fushi→Kavita 正常，Kavita→Fushi 不生效，串流与下载书都如此）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/kavita/kavita_progress_resolver.dart`（`serverMoved = server > lastSyncAt + 2 分钟容差`）：以本机时钟为基线判断「服务器动过没有」，上次推送 / 打开后 2 分钟内的 Kavita 端改动被判成没动；而 `kavita_epub_sync.dart` / `kavita_manga_sync.dart` 的 `recordSync(pulled: true)` 每次打开都把基线推到现在，那次改动从此永远拉不下来。真服务器（Kavita 0.9.1.4）上复现：Fushi 推第 3 页 → 服务器改 8 → 重开，本地仍为 3。时钟偏差实测 <0.5 s，不是原因。
- **[x] ① 已修复** — 有「上次两侧一致的页」（`lastSyncedPage`）时按页号判谁动过，不再看时钟；服务器被重置回 0 页而本机已读时改为询问；EPUB 脊柱项数与 Kavita `chapter-info.pages` 不一致时不建同步会话（避免落到错的一章）。另修两处：关书时补报最后一页（reader / manga dispose）、冲突弹窗被关掉不再覆盖服务器。提交见 `feat/kavita-two-way-sync`。
- **[x] ② 已加自动化测试** — `fushi/test/media/kavita/kavita_progress_test.dart`（页基线：服务器刚改 / 双方都动 / 仅本机动 / 重置 0）、`fushi/test/media/kavita/kavita_epub_sync_test.dart`（页数不一致不同步、一致照常）。
- **备注**：真服务器端到端（推送→外部改→重开，EPUB 与漫画各 7 个场景）已在一次性脚本里跑过，未入库（含服务器凭据）。尚未在真实 app UI 里肉眼复测；EPUB 仍是章级同步（`bookScrollId` 未用），手动导入、未绑定 Kavita 章的书不同步。
