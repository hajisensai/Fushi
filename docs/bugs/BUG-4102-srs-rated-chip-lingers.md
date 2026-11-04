## BUG-4102 · srs-rated-chip-lingers
- **报告**：2026-11-05（用户：开发者本人，反馈 vKGS1y9-v2「这个提示太久了，我觉得闪一下甚至都可以」，截图为复习页问题面底部的「已评：重来 · 15分钟后到期」胶囊）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/srs/srs_review_page.dart` 的 `SrsRatedFeedbackChip`（原 StatelessWidget）没有自己的停留时长，可见性完全绑在 `_lastRated`（约 :997 评分时设、:758 / :1014 换卡 / 撤销时清）和「问题面」（:2441 `_showingAnswer || detail == null ? null : _lastRated`）上——评分后只要不翻面，胶囊就一直挂着；全仓也没有「提示停留多久」的统一出处（`fushi_toast.dart` 里 2000 / 3500 / 2400 / 4000 都是调用处现写的毫秒数）。
- **[x] ① 已修复** — 新增 `fushi/lib/src/utils/misc/notice_dwell.dart` 的 `FushiNoticeDwell`（按提示类别给停留时长的单一真相源：`flash` 动作结果回显 1.2 s、`short` / `long` 普通 toast、`mineResult` / `minePending` 制卡卡），`FushiToast.show` / 制卡结果卡改读它；`SrsRatedFeedbackChip` 改成 StatefulWidget，每次新评分（新 serial）出现后停留 `FushiNoticeDwell.flash` 自行收起，同一次评分重建不再冒出，翻面 / 撤销照旧立即收起。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_rated_feedback_test.dart` 新增 MD3 / Apple 两套「只闪一下」用例：停留未满仍在、满 `FushiNoticeDwell.flash` + 退场后自行收起且仍在问题面、下一次评分重新闪；原用例改成出现即断言（不再多推时间）。
- **备注**：真机复测本轮未做。
