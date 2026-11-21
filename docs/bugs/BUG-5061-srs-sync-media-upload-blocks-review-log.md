## BUG-5061 · srs-sync-media-upload-blocks-review-log
- **报告**：2026-11-21（应用内反馈 arw7eXO895「复习卡组同步问题」：一直显示准备同步 / 同步卡片媒体，另一端看不到进度，手机端同步异常耗电；3.3.0 Windows，Google Drive）
- **真实性**：✅ 真 bug（gen4 切换后的 origin/develop 2ddafb44b4 上路径仍在）。日志证据：活动面包屑两次死在 `stage=media`（11-16 rss 833 MB、11-21 rss 1.4 GB），`srs_media` 1.1 GB；`SrsSyncScheduler.mediaBeforeUpload` 报 Drive 503 / googleapis.com errno 121 超时，调用栈 `_mediaBeforeUpload → srsSyncMedia → _reconcile → srsRunPooled`；11-16 另有 `PathNotFoundException`（`srs_media/...mp3` 在上传时不在了）。根因：
  1. `fushi/lib/src/srs/srs_sync_scheduler.dart` `_mediaBeforeUpload`（原 557-588）经 `packages/fushi_engine/lib/srs/sync2/srs_sync2_round.dart:333-334`（`beforeUpload` 在发件之前 await）把本机全部没上传的媒体整份 `uploadOnly` 传完才发复习记录段，无时间预算 / 分批；媒体积压大、云盘慢时这一轮长时间停在媒体阶段，段发不出去，窗口一关（`windowClose`）就整轮白跑——另一端看不到进度。
  2. 发段之后的完整对账（同文件 `_syncWithBackend` 里 `_mediaRunner` 那段）同样无预算，在通道锁里一跑到底，新背的卡推不出去，手机端一直在传。
  3. `packages/fushi_engine/lib/srs/srs_media_sync.dart` `putContent` 读本机源文件时文件已不在（列出来之后被删）抛 `PathNotFoundException`，`srsRunPooled` 第一错即中止，整趟媒体作废、这一位置记不成已对账，下一轮从头再来。
  4. 媒体阶段只报 `SrsSyncStage.media`（`_reportMediaStart`），无 done/total，界面看不出在不在动。
- **[x] ① 已修复** — `srsSyncMedia` 加 `deferRemaining`（每开始一项前问一次，为真则剩下的记 `deferred` 留给下一轮、不做过期清理）与 `onProgress(done,total)`；本机源文件在上传时已不在的只跳过该项、记 `vanished`（文件还在却读不了照旧抛）。发段前那一步预算 `kSrsMediaBeforeUploadBudget`=15 s（云盘与文件夹两条路径），发段后完整对账预算 `kSrsMediaRoundBudget`=2 min，`deferred>0` 时不记成已对账、下一轮接着传；媒体阶段报 done/total（新文案 `srs_sync_progress_media_count`、确定进度条）；`vanished` 记一条诊断。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_media_sync_test.dart`（中途文件没了只跳过该项；`deferRemaining` 后剩下的留给下一轮、进度按项报；`srsMediaDeadline`）、`fushi/test/srs/srs_sync_scheduler_test.dart`（对账到点留下没做的：下一轮接着对账，阶段进度按项报）、`fushi/test/sync/sync_activity_visibility_test.dart`（媒体阶段计数 + 确定进度）。
- **备注**：读者在发送方媒体未传完时读到绑定会按缺失记、下一轮再取（`srsSyncMedia` 既有自愈路径），不丢数据；积压的媒体只在有同步轮次时（背卡自动推送 / 进复习页 / 立即同步）继续传，空闲时不自己跑。
