## BUG-3819 · 设置 › 同步加「自动同步复习数据」开关（复习数据后台同步无法单独关闭）
- **报告**：2026-10-27（用户：QQ 群经 fushi-bot 代提交 VNz9dsLeIy；关联 I1Bg6uMZ32、0rvPl6s6tR。分诊 `docs/reviews/2026-10-27-feedback-triage.md` 第五节第 2 项，所有者已批准推荐方案）
- **真实性**：✅ 设计缺口（不是代码错误）。复习数据的后台同步有四个自动触发口，没有一个能单独关：常规同步每条通道后的复习步骤（`fushi/lib/src/srs/srs_app_runtime.dart` 旧 `_postRun`）、本机写入后的去抖推送（旧 `srs_app_runtime.dart:90` 的 `localPush`）、互联快速通道长轮询（`SrsInterconnectWatcher`，host 有新数据立刻同步）、本机作为主机收到写入后 3 s 去抖（`fushi/lib/src/srs/srs_sync_scheduler.dart` `notifyLocalDirectoryWritten`）。互联的 `interconnect.auto_sync` 只管常规同步轮次，用户想停掉复习数据的后台同步只能整个关互联。
- **[x] ① 已实现** — 提交 `feat(srs): setting to turn off automatic review-data sync`。
  - 偏好 `srs_sync_auto`（`SyncRepository.isSrsAutoSyncEnabled`，默认开）：与 `interconnect_sync_auto` / `sync_auto_enabled` 同类的设备行为开关，存在 `preferences`、随备份恢复，不进 Profile 快照专属清单（现有同步开关都不按 Profile 分）。
  - 判据只在 `SrsSyncScheduler` 一处（`autoSyncEnabled` 注入、`isAutoSyncEnabled()` 每次触发时现读，改设置立即生效）：`autoSyncWithBackend`（通道后置步骤 + 互联快速通道 onChange）、`autoPush`（本机写入后的推送）、`notifyLocalDirectoryWritten` 到点时读；运行时的快速通道 `ready` 也加上开关（关着不挂长轮询，空闲重查时再问）。
  - 不受开关影响：牌组列表「立即同步」（`syncNow`）、AnkiConnect `sync` 动作、**进入复习页的节流同步**（`syncThrottled`，60 s 一次）——按分诊推荐保留（用户主动进复习页，看到的就该是最新数据），设置副标题写明关掉后只在这两种情况同步。
  - 设置 › 同步「什么时候同步」区加 `sync.srs_auto_sync`（复习模块开着才显示）；i18n `srs_sync_auto` / `srs_sync_auto_hint`。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_sync_scheduler_test.dart` group「自动同步复习数据开关」：关着时后置步骤 / 推送 / host 收到写入都不跑、立即同步与进复习页照跑、打开后立即生效；偏好默认开与读回；运行时接线源码守卫（自动触发口都经开关、运行时不直接调 `syncWithBackend`）。`settings_schema_coverage_test` 登记专项测试。
- **备注**：开关不阻止常规同步本身（书 / 视频进度等，由 `interconnect.auto_sync` / `sync.auto_sync` 管）；关掉后常规同步横幅照样会出现，只是不再多出复习那一行。未在真机复测。
