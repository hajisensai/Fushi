## BUG-3874 · srs-sync-review-lag
- **报告**：2026-10-29（用户：手机上复习同步完成 / 快完成时画面卡一两秒；背卡时按下评分键有时要等一两秒才出下一张）
- **真实性**：✅ 真 bug，沿代码路径定位三处根因：
  1. 同步的只读命令被包进本机写锁：`packages/fushi_engine/lib/srs/srs_db_store.dart` `sync2Command` 只放行纯计算（`derive_key` / `seal` / `open`），其余一律 `runExclusive`。其中 `digest` 是全库扫描（内核注释：100 万次复习约数秒，设计上「不占写锁，复习照常写」），版本向量变了且距上次满 10 分钟就重算——边背卡边推送时每 10 分钟必轮到一次，`answer()` 排在它后面，评分键等一两秒。`status` / `media_known` 同理（短）。
  2. 摘要扫描期间攥着内核读连接的锁：`native/fushi_fsrs/src/store/mod.rs` `scan_connection` 把读锁守卫随扫描连接一起交给调用方，`sync2_digest_due` 整段扫描都持着它，走读连接的命令全被挡住。
  3. 同步收尾的媒体对账在 UI isolate 上一口气跑完：`fushi/lib/src/srs/srs_sync_scheduler.dart` 的 `mediaDue` 把「这一轮上传 / 应用过操作」算作要对账，边背卡边推送的每一轮都整套对账；`srs_media_sync.dart` 又把每个引用的媒体名都送进 `syncOne`，两边都有的名字没有真正挂起的 IO，上万个在一串微任务里跑完、整段不回事件循环（BUG-3865 只去掉了同步 stat，微任务链还在）。
- **[x] ① 已修复** — ① 只读已提交快照的命令（`status` / `media_known` / `conflicts` / `checkpoints` / `history` / `digest`）不进写锁（`SrsDbStore.kSrsSync2LockFreeOps`）；② 摘要扫描改用登记过的扫描会话（`SrsCore::scan_session`），只在开连接那一下拿读锁，关库照样等在途扫描并关掉它；③ 媒体对账只在内容指纹（`contentFingerprint`，复习日志不推进）变了 / 首次 / 到期 / fork / 用户主动同步时跑，且两边都有的名字在进并发池之前同步筛掉。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/sync2/srs_sync2_lock_free_test.dart`（写锁被占时状态 / 摘要照样跑完、写连接命令仍排队）；`packages/fushi_engine/test/srs/srs_media_sync_test.dart`「两边都有的媒体不进逐个异步流程」（微任务数与该类名字数量无关，撤修复实测 76 → 1071）；`fushi/test/srs/srs_sync_scheduler_test.dart` 媒体对账节奏（只发复习日志的一轮不对账）；Rust `store::tests::scan_session_leaves_the_reader_free_and_closes_with_the_store`。
- **备注**：未在真机上复测（本机无手机在线验证）。仍存在的同类延迟：收一批对端段（`ingest_batch`，每批 8 MiB 预算）时解压 / 解密 / 验签都在内核写锁内做，对端积压大量复习时单批可能占写锁一两秒，作答排在其后；根治要把段的解码 / 验签挪到写锁外（内核 `ingest_segments` 拆成锁外预处理 + 锁内投递），未在本修复内。
