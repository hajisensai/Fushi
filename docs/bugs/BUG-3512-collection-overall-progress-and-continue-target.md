## BUG-3512 · 合集「整体进度」2/4 读完显示 100%，读完第二卷「继续」回到第一卷
- **报告**：2026-10-18（用户：iPad 漫画合集「志乃と恋」共 4 项、已读完 2/4，整体进度 100%，「继续 · 志乃と恋」指第一卷；期望 50%、指最后看的那本）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/collections/collection_member_view.dart`：
  - `summarizeCollectionMembers` 只把「有 info」且「读完 / 有进度 / 从没读过」的成员计入分母——没有 info 的成员（resolver 认不出：未下载 / 远端占位）与「在读但进度未知」的成员被整个剔除，2 本读完 + 2 本无 info → 2/2 = 100%，与 hero 上「已读完 2/4」的总数不一致。
  - `pickContinueIndex` 的回落链只看未读完成员，最近读的那本已读完、其余没有 info 时一路落到下标 0（第一卷）。
- **[x] ① 已修复** — d6e6cf32c9：进度分母改为全部成员（没有进度真值的按 0 计入，一个 info 都没有时仍不画进度条）；续读目标改为「最近在读未读完 → 最后读过的那本（即使已读完）→ 第一本未读完 → 首本」。书架系列卡封面共用 `pickContinueIndex`，同步改为显示最后读的那本。
- **[x] ② 已加自动化测试** — `fushi/test/media/collections/collection_continue_pick_test.dart`（两条纯函数用例）+ `fushi/test/pages/media_collection_grid_detail_page_test.dart`「整体进度分母是全部成员」「读完第二卷后『继续』指向最后读的第二卷」。
- **备注**：第 3、4 卷为何 resolver 返回 null（截图中卡片是本地书角标）未在真机上确认；按截图数值只有「这两卷无 info」能同时解释 100% 与「继续第一卷」。修复不依赖这一点。
