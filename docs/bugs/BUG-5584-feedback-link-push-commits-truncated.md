## BUG-5584 · feedback-link-push-commits-truncated
- **报告**：2026-11-27（用户：批量合并后发现 4 条反馈没被自动标已修复）
- **真实性**：✅ 真 bug。`tool/feedback_link.mjs` `pushCommits` 只读 push 事件的 `event.commits`，而 GitHub 的 push payload 里这个数组最多 20 个提交、多出的直接截掉。2026-11-27 一次往 develop 推了 76 个提交，CI 只标了最后 20 个里的 14 条，T3n0B8tO7F（#4551）、ujt4V8GdT8（#4547）、vh4K5khfVr（#4546）、wJmcCQBVn1（#4545）漏标（已手动 `fixed --sha` 补上）。
- **[x] ① 已修复** — `compareRange`：develop 的 push 事件提交数达到 20、且 before 不是全 0 时，经 `GET /repos/{repo}/compare/{before}...{after}` 分页取全（最多 250 个），失败时 warning 后退回事件里的列表。main 不补全：main 的 push 是正式版同步，compare 会带出 develop 上早已登记的提交，而 compare 结果没有 distinct 可滤。
- **[x] ② 已加自动化测试** — `fushi/test/tools/feedback_link_script_test.dart`「push 事件只带 20 个提交时经 compare API 补全」三条：被截掉的提交的 Feedback 行照样登记、不足 20 / main / 新分支不调 compare、compare 失败退回事件列表。
- **备注**：
