## BUG-4502 · feedback-account-seen-lost-on-relaunch
- **报告**：2026-11-15（应用内反馈 0jX0qRrwdc，iOS）：反馈中心的新回复看过后红点消失，但每次重启 app 又回到「新回复」并带红点。
- **真实性**：✅ 真 bug（只影响登录了排行榜账户、经 `/v1/feedback/mine` 列出的账户条目）。冷启动时 `feedbackServiceProvider` 与 `leaderboardServiceProvider` 各自 `load()` 并行，`FeedbackService._load`（修前 `fushi/lib/src/feedback/feedback_service.dart:320`）同步读 `_client().identity`，排行榜账户文件还没读出来就是 null → 不读账户缓存、`_accountKey` 留空。随后 `refresh()` 里 `_dropStaleAccountTickets`（修前 `:421-427`）发现身份变了只会清空列表，`_refreshAccount`（修前 `:459`）找不到旧条目，全部 `FeedbackTicket.fromAccount` 重建（`seenAt=0`），再 `_persistAccount` 把缓存里的已读时刻覆盖掉。
- **[x] ① 已修复** — `_dropStaleAccountTickets` 改为 `_switchAccount(key)`：身份变化时丢掉旧账户列表，新身份非空就从该账户自己的落盘缓存恢复（含 `seenAt`），读缓存期间身份再变 / 已被刷新填好则不覆盖。`_load`、`refresh`、`_refreshAccount` 都走它，已读状态不再取决于账户文件和反馈服务谁先加载完。
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_video_service_test.dart`「load 时身份未就绪：刷新后已读状态仍从账户缓存恢复」：读过详情后，新服务在身份为 null 时 load、身份就绪后 refresh，`hasUnseenReply` 仍为 false，`unseenCount`=0，再开一次仍为已读。
- **备注**：反馈里「已读状态跨设备同步」是新功能诉求（需服务端存已读），未实现，留待所有者拍板。
