# 2026-10-15 项目审查

## 本轮：数据完整性、SRS 集成与后台生命周期

### Scope

- 审查基线：`f56c6aa5a8208a8c8209a28c239fd9e87c32660d`（develop）。
- 用户明确排除已经完成的两项：两套内置风格一致性、CLI 操作覆盖。本轮未重复这两项。
- 按风险检查最低 schema v75 拦截、v117 迁移、Profile 身份、SRS 持久化与同步、备份合并、后台优化及关库边界。另抽查阅读器退出保存与章节恢复路径，但未做完整阅读器审查。
- 主要文件：`packages/fushi_core/lib/src/database/{database.dart,tables.dart}`、`packages/fushi_engine/lib/srs/{srs_db_store.dart,srs_optimizer.dart,srs_backup_merge.dart,srs_media_sync.dart}`、`packages/fushi_srs/lib/src/{ids.dart,field_edit.dart,valid_logs.dart,sync/sync_engine.dart}`、`fushi/lib/src/srs/`、`fushi/lib/src/sync/backup{_service,_merge_engine}.dart`、`fushi/lib/src/models/app_model.dart`。
- 三个只读子审分别负责数据库、同步备份、应用装配，主审复核源码、独立重跑隔离探针并检查优化训练筛选。只新增审查材料，未修改业务代码。

### Findings

本轮确认 **10 项：P1 三项，P2 七项**。其中六项通过真实 Dart 内核/内存数据库隔离复现，一项通过最小 SQLite 契约实验复现，三项为已追通的静态代码路径发现；后者没有冒充运行时复现。

#### HBK-AUDIT-001：第二个 Profile 的编辑 ID 与第一个 Profile 碰撞

- severity：P1
- status：open，真实 SrsDbStore + 内存 SQLite 已复现。
- 位置：`packages/fushi_engine/lib/srs/srs_db_store.dart:163–165,188–190,366–370`；`packages/fushi_srs/lib/src/ids.dart:184–185`；调用方 `fushi/lib/src/srs/srs_providers.dart:65–72`。
- 根因：每个 Profile 都使用同一设备的 `deviceId#1`，编辑序号又各自从零开始。编辑 ID 仅由 writerId/seq 派生，不含 Profile；数据库却使用全库唯一 ID。第二个 Profile 的编辑被 `_store` 当成重复事件忽略。
- 触发与影响：同库、同设备 ID 打开两个不同 Profile，各建一条笔记；第二条的正文变空、卡片隐藏，操作不报错。会影响多 Profile 的正常使用，不能只靠页面刷新修复。
- 隔离输出：`PROFILE_COLLISION writers=device#1/device#1, a=first, b=, b hidden=true`。
- 修复建议：统一设计全库唯一且按 Profile 隔离的 writer/编辑身份，兼顾已有事件和同步目录；不要只在重复检测处绕过碰撞。
- 验证方式：同库两个 Profile 分别创建、编辑、重开、同步，断言内容完整且事件 ID 无碰撞。

#### HBK-AUDIT-002：备份恢复会复用旧写入者化身并重新从零分配编辑序号

- severity：P1
- status：open，真实 SrsDbStore + 内存 SQLite 已复现。
- 位置：`packages/fushi_engine/lib/srs/srs_db_store.dart:117–121,163–165,1805–1811`；`packages/fushi_srs/lib/src/field_edit.dart:326–327`。
- 根因：备份不含本机状态；重开时 incarnation 默认 1，`afterRestore` 总得到 `deviceId#2`，并重建序号为零的编辑 writer。对已恢复事件调用 `apply` 只并入因果上下文，不恢复已用序号；设备 ID 在恢复时仍保持本机值。
- 触发与影响：恢复后编辑一次，再恢复包含该旧化身事件的数据并继续编辑，会重复使用已存在的编辑 ID，新修改被静默忽略。重新从同一旧备份恢复时，也可能在远端撞上前次恢复发出的批次和事件。
- 隔离输出：`RESTORE_COLLISION writers=device#2/device#2, expected=restored twice, actual=restored once`。
- 修复建议：恢复时分配不可复用的新化身标识，不能依赖会被清空的本机计数器。身份恢复和编辑序号必须作为同一协议处理。
- 验证方式：连续两次恢复、恢复含旧 `#2` 事件的备份、恢复后接回已有远端目录，验证新编辑和批次都不会覆盖或碰撞。

#### HBK-AUDIT-003：冻结批次落盘前先清发件箱，异常退出后事件漏发

- severity：P1
- status：open，真实同步内核加持久化提交故障注入已复现；数据库实现顺序已核对。
- 位置：`packages/fushi_srs/lib/src/sync/sync_engine.dart:207–208`；`packages/fushi_engine/lib/srs/srs_db_store.dart:1680–1689`。
- 根因：`markPublished` 先提交 `outbox_seq=NULL`，下一步 `saveSyncState` 才保存 frozenBatch，两者不在同一事务内。内存里已有冻结内容不能代替持久化。
- 触发与影响：两步之间进程退出、掉电或保存失败，重启后 pending 和 frozen 都为空，本机事件仍在，却不会再由增量通道投递。若以后没有其他写入触发完整快照，对端会持续缺数据；不把这种漏发夸大为本机实体已被删除。
- 隔离输出：`After restart: pending=0, frozen=null, localEntities=(lost-from-outbox)`；随后三轮均 `published=0, B entities=()`。
- 修复建议：冻结信封与发件箱状态使用同一持久化事务，或先持久化可恢复的冻结信封，再做幂等清理。
- 验证方式：在两步之间及分块清发件箱中途注入失败，重启后断言全部事件最终到达对端，且批次号/内容稳定。

#### HBK-AUDIT-004：对端只剩快照时，已初始化设备无法追上数据

- severity：P2
- status：open，真实同步内核已复现。
- 位置：`packages/fushi_srs/lib/src/sync/sync_engine.dart:288–295`。
- 根因：没有 batch 时将 firstExisting 设为 cursor+1，缺口判断必为假；已经 bootstrapped 的设备也不会再执行起步快照合并。
- 触发与影响：B 已同步起步但从未发布批次，离线超过退役期；A 在快照后清掉全部批次。B 自己没有发布批次，目录不满足退役删除条件，回归时仍是 bootstrapped=true，却读不到 A 的快照。默认参数涉及 90 天退役和 20 批快照阈值，实验缩短参数复现相同状态。
- 隔离输出：A 目录仅 `[cursor, probe, snapshot-0000000001]`；B 连续三轮 `applied=0, entities=(), cursors={A#1: 0}`。
- 修复建议：所需下一批不存在时，检查最新快照的覆盖版本；不能仅由首个现存 batch 推断缺口。
- 验证方式：只保留快照，旧设备连续重连，断言事件和 cursor 追上；同时覆盖从未发布的只读设备。

#### HBK-AUDIT-005：备份合并照搬设备本地 source_id，导致失败或错绑来源

- severity：P2
- status：open，最小 SQLite 契约实验已复现；尚未运行完整 BackupMergeEngine 或 App 恢复 E2E。
- 位置：`fushi/lib/src/sync/backup_merge_engine.dart:573–586,599–605`；外键 `packages/fushi_core/lib/src/database/tables.dart:491–493,717–719`。
- 根因：合并明确跳过设备本地的 media_sources，却在书籍和视频的全列 INSERT/SELECT 中原样复制 source_id。两台设备的自增来源 ID 没有共同身份语义。
- 触发与影响：来源库扫描导入的内容带 source_id=7，目标无该 ID 时外键失败，整个合并事务回滚；目标恰有无关来源 7 时，内容错绑到另一个来源库。
- 隔离输出：`Fresh target merge: FOREIGN KEY constraint failed`；同号来源反例：`[('source-book', 'UNRELATED target device library')]`。
- 修复建议：合并时清空设备本地来源外键；如需保留关系，先按明确来源身份映射，不能照搬 row ID。
- 验证方式：在真实 BackupMergeEngine 测试覆盖目标缺该来源和同号无关来源两种情况，分别验证合并成功且归属正确。

#### HBK-AUDIT-006：补齐服务器时间后没有刷新字段编辑对应缓存

- severity：P2
- status：open，真实 SrsDbStore + 内存 SQLite 已复现。
- 位置：`packages/fushi_engine/lib/srs/srs_db_store.dart:1723–1733`；字段胜者选取 `packages/fushi_srs/lib/src/field_edit.dart:257–275`。
- 根因：S(e) 更新会改变字段寄存器的胜者，但 observeServerTimes 只让复习日志对应卡片失效，没有标记字段编辑对应的笔记、笔记类型或卡片。重复字段事件补充 S 时也需要同样处理。
- 触发与影响：两个并发 suspended 编辑先由快时钟的 true 获胜，补充该事件的服务器时间后，实际应由 false 获胜；缓存仍为 true，卡片继续被排除，直到额外重建缓存。
- 隔离输出：`STALE_CACHE before=true, afterServerTimes=true, afterRebuild=false`。
- 修复建议：S 变化时按事件类型统一标记其实体失效，重建所有受影响的物化状态。
- 验证方式：补 S、重复事件补 S、快照携带 S 后，卡片/笔记缓存必须与完整 rebuildCaches 的结果一致。

#### HBK-AUDIT-007：重置过的卡片被永久排除出优化训练

- severity：P2
- status：open，真实 srsPrepareOptimization + 内存 SQLite 已复现。
- 位置：`packages/fushi_engine/lib/srs/srs_optimizer.dart:117–126`；历史截断 `packages/fushi_srs/lib/src/valid_logs.dart:180–205`。
- 根因：训练输入只保留最近重置后的评分，但时间异常校验却与全部 effectiveRatings 的数量比较。存在重置前评分时，数量必定不同，被误判成时间不可信并整卡跳过。
- 触发与影响：卡片学过后重置，再正常学习足够多次，该卡仍不贡献任何训练样本；会低估训练量、延后自动优化，并排除本来有效的新历史。
- 隔离输出：`beforeResetTrainingItems=1, afterResetTrainingItems=0, allEffectiveRatings=4, postResetMemoryReviews=2, postResetHistoryComplete=true`。
- 修复建议：训练输入与时间可信度过滤使用同一段重置后历史，显式保留来源日志映射，不能用不同历史窗口的长度推断异常。
- 验证方式：重置前两次评分、重置后两次评分，断言新历史产生一个训练条目，且旧历史不混入。

#### HBK-AUDIT-008：在途优化覆盖用户刚恢复的默认参数

- severity：P2
- status：open，静态代码路径已确认，尚未运行调度竞态复现。
- 位置：`fushi/lib/src/srs/srs_optimization_scheduler.dart:238–242`；`packages/fushi_engine/lib/srs/srs_optimizer.dart:224–274`；入口 `fushi/lib/src/pages/implementations/srs/srs_deck_settings_page.dart:383–388` 的恢复默认参数按钮。
- 根因：异步训练返回后只检查 disposed/cancel，未核对训练期间参数组或相关设置是否改变。恢复默认参数不取消后台任务，页面的 _optimizing 只追踪自己发起的手动优化。
- 触发与影响：后台自动优化进行中点击恢复默认参数；重置刚写入空参数和新基线，旧结果随即又写回参数与基线，用户选择失效。
- 修复建议：训练输入携带设置版本，写回做事务/CAS 校验；用户重置或改动优化设置时取消相应任务。
- 验证方式：阻塞假优化 job，执行 srsResetParams，再返回 adopted 结果，断言默认参数和重置基线保留。

#### HBK-AUDIT-009：同步中切 Profile，会混用旧 store 与新媒体目录

- severity：P2
- status：open，静态代码路径已确认，尚未运行界面切换复现。
- 位置：`fushi/lib/src/srs/srs_sync_scheduler.dart:121–143`；`fushi/lib/src/srs/srs_app_runtime.dart:109`；媒体 provider `fushi/lib/src/srs/srs_providers.dart:87–96`。
- 根因：本轮开始捕获 A 的 store，事件传输 await 后才实时读取媒体 provider。切到 B 会重建该 provider，媒体阶段因此组合了 A 的事件/远端命名空间和 B 的本地目录。
- 触发与影响：A 同步等待网络时切到 B；A 媒体被下载进 B 目录，A 卡片仍缺图和音频，B 多出不属于自己的媒体缓存。
- 修复建议：媒体目录按本轮 store.profileUid 解析，或原子获取绑定同一 Profile 的上下文，不能分别读取实时 provider。
- 验证方式：completer 阻塞事件 runner 后切换媒体 resolver，再恢复，断言媒体 runner 仍使用 A 的目录。

#### HBK-AUDIT-010：关库边界没有终止或排空 SRS 后台任务

- severity：P2
- status：open，静态代码路径已确认，尚未运行恢复/迁移 E2E。
- 位置：`fushi/lib/src/models/app_model.dart:8058–8070`；`fushi/lib/src/srs/srs_app_runtime.dart:42–45,74–80`；`fushi/lib/src/srs/srs_optimization_scheduler.dart:136,238–242`。
- 根因：关库通知和后台写手排空均未接入 SRS runtime；runtime 只依赖模块启用状态并由根容器保活。正在训练或同步的任务仍持旧连接，运行结束后继续写回。
- 触发与影响：优化或同步在飞时恢复备份、迁移数据目录或关闭数据库，任务返回后访问已关闭连接。自动优化 Timer 又使用无错误处理的 unawaited 调用，可能产生未捕获后台异常。
- 修复建议：将 SRS 停止接收新任务、取消与排空接入数据库生命周期；关库前等写阶段退出，重开后失效并重建 store。
- 验证方式：阻塞优化和同步任务，触发关库，断言取消/排空先于关闭，且旧任务不能在关闭后写入；重开后只用新连接。

### 验证与证据边界

- 主审独立重跑五个隔离探针，命令均退出 0：database_probe.dart（3 个场景）、snapshot_probe.dart、freeze_crash_probe.dart、optimizer_reset_probe.dart、backup_source_probe.py。退出 0 代表反例脚本执行完成，**不是业务通过或修复验证通过**。
- 本机证据目录：独立 worktree 下 `.codex-test/runtime-review-1015/`。Dart 使用 `D:/flutter_sdk/flutter_3.47.6/bin/cache/dart-sdk/bin/dart.exe`；临时 package config 仅将既有路径绝对化并补齐 fushi_srs 映射，没有修改仓库依赖。
- 数据库实验使用 NativeDatabase.memory；同步实验使用现有测试 MemorySyncDirectory 和真实 SrsSyncEngine；崩溃实验用包装副本在冻结保存时注入失败；备份来源问题仅执行保留真实外键与 INSERT/SELECT 结构的最小 SQL 实验。
- 未操作用户数据库、真实云盘或正在运行的 App；未跑全量测试、全量 analyze、设备 UI、真实备份恢复或双设备验收。最低 schema 拒绝和 v117 迁移本轮未确认新缺陷，但不等于已完成迁移全套验收。
- 已复现问题另记入本 worktree 的本地 `docs/REGRESSION_BUGS.md`。本轮没有修复业务代码，也没有创建已修复 bug 记录。

### Next Scope

- 先修复并验证 HBK-AUDIT-001～003 的身份与发件箱原子性，再核查跨 Profile、恢复和重启组合场景。
- 下一轮继续阅读器分页/滚动/VN 的退出恢复、音频 cue 跨章与后台续播、词典导入/FFI 资源生命周期、WebView 缓存与错误恢复。继续排除风格一致性和 CLI 覆盖。
