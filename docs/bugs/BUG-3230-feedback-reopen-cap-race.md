## BUG-3230 · 反馈重新提交次数上限先 COUNT 再 INSERT 并发可超、重新提交跳过同来源判重
- **报告**：2026-10-10（PR #2021 审查遗留疑点）
- **真实性**：✅ 真 bug。根因 `services/leaderboard/src/feedback.js` `reopenParent`（原 :300-301）先 `SELECT COUNT(*) ... WHERE parent_id = ?` 判 `reopensPerFeedback`，再在 `createFeedback` 末尾单独 INSERT——两步之间并发的重新提交都读到同一个旧计数，一起越过上限（测试里 4 个并发请求在差 1 次到上限时全部 201）。另外 `createFeedback`（原 :309）`if (!parent)` 整段跳过「同来源同内容 1 小时」判重，同一来源用同样内容把同一条原反馈连交两次（双击 / 重试）会建出两条。
- **[x] ① 已修复** — 见提交「fix(feedback): make the reopen cap atomic」：INSERT 改成 `INSERT … SELECT … WHERE ?13 IS NULL OR (SELECT COUNT(*) FROM feedback WHERE parent_id = ?13) < ?14`，`changes !== 1` 回 429 `too_many_reopens`（`reopenParent` 里的 COUNT 只留作提前拒收）；重新提交改用按原反馈分开的判重桶 `feedback:dup:<来源>:<内容>:reopen:<原 id>`，不撞原反馈当初提交时的桶，但同一条原反馈的同内容重复提交照样 409。
- **[x] ② 已加自动化测试** — `services/leaderboard/test/feedback.test.js`「BUG-3230 次数上限是原子的」（`d1DelayMs` 真实往返延迟下 4 个并发请求只成功 1 个）与「BUG-3230 同一来源对同一条原反馈用同样内容连交两次」；未修复时两条均红。
- **备注**：
