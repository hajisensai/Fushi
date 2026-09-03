## BUG-1721 · 后台任务历史条目无法重新刮削或手动指定作品
- **报告**：2026-08-18（用户：截图指向「后台任务」对话框的「最近任务」列表——已完成/失败条目既不能重刮，也不能手动指定刮削结果）
- **真实性**：✅ 真 bug。根因是**重刮入口的判据取错了维度**：
  - `fushi/lib/src/media/video/metadata/video_source_scrape_dialog.dart:222-238`（修复前）：历史行的重试按钮门是 `<String>{'failed','interrupted','cancelled'}.contains(run.status)`。
  - 可用户唯一想处理的那种 run 恰恰是 **`status == 'completed'` 但 `pendingConfirmations > 0 || failedWorks > 0`**——自动刮削没有确认回调，歧义作品只被计数后跳过（见 BUG-1720），批次本身照样「已完成」。按 status 判，这类 run 永远拿不到入口。
  - 同一行也没有 `onTap`：`summaryJson` 里明明存着逐条作品的失败原因（`video_source_scrape_coordinator.dart:1370-1392` 的 `_reportJson` 写入 warnings/errors），UI 只渲染三个聚合数字，用户看不到是哪几个作品、为什么失败。
  - PR#854 / BUG-1662 只给合集详情页补了重刮入口，后台任务与来源行这条路没覆盖。
- **[x] ① 已修复**：
  - 判据换成看事实不看状态的 `scrapeRunHasUnresolvedWorks(run)`（`fushi/lib/src/media/video/metadata/video_source_scrape_task.dart`）：`pendingConfirmations > 0 || failedWorks > 0 || status ∈ {failed, interrupted, cancelled}`；按钮文案由「重试」改为「重新刮削此来源」。
  - 历史行加 `onTap` → `showVideoSourceScrapeRunDetailDialog`，逐条列出该 run 的待确认/失败作品与原因，每条带「手动指定作品」（搜索资料源 → 选中 → `rescrapeWorkWithLookup`），底部带「重新刮削此来源」。
  - 手动指定与批次内确认共用同一条落库路径（`scrapeSource(confirmedLookups:)` → `VideoMetadataDatabaseStore.apply`），不是第三套绑定保存。
  - 顺手消掉重复：`video_source_scrape_dialog` 与 `media_sources_view` 各写一份的 run 状态文案合并成 `videoSourceScrapeRunStatusLabel`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_source_scrape_ui_test.dart`：
  - `unresolved-run predicate looks at works, not run status (BUG-1721)`（纯函数，逐条钉死旧白名单会漏的三种组合）
  - `completed run with pending works still offers a rescrape entry (BUG-1721)`（面板级：completed run 仍有重刮入口 + 点条目进详情看到失败原因）
  变异实测：把 `scrapeRunHasUnresolvedWorks` 改回只判 status 白名单 → 上述两条红；还原后 sha256 与变异前一致。
- **备注**：与 BUG-1720 是同一条修复路径的两个入口（导入页摘要行 / 后台任务历史行）。
