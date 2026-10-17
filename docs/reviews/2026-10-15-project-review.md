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

## 第二轮：阅读器退出与恢复、有声书和词典导入

### Scope

- 基线：`e941b75f5a4e0fe4c5dd033780fc7666ec445e94`。用户要求继续审查；仍排除风格一致性和 CLI 覆盖，不实施首轮发现的修复。
- 检查阅读器退出保存、导航代际、双页文档回执、资源路径和缓存；有声书音轨解析、按章 cue 装配及后台会话；词典文件/目录导入、后台下载更新、暂存和替换生命周期。主审另沿 EPUB 导入原语检查并发发布与失败清理。
- 文件范围：`reader_fushi_page.dart`、`reader_fushi/{navigation,webview,audiobook}.part.dart`、`base_source_page.dart`、`fushi/lib/src/media/audiobook/{audiobook_session,audiobook_session_launcher,audiobook_controller}.dart`、`packages/fushi_audio/lib/src/audiobook/audiobook_playback_files.dart`、`packages/fushi_engine/lib/epub/{epub_parser,epub_importer,epub_storage,epub_book}.dart`、`dictionary_import_manager.dart`、`dictionary_download_controller.dart`、`dictionary_dialog_page.dart` 及相关仓库/FFI 调用者。

### Findings

新增 **8 项：P1 一项、P2 七项**。三项使用真实组件隔离复现，两项通过抽取生产代码的控制流探针确认反例，三项为静态路径发现；不将抽取探针视为真实播放器/WebView/native 验收。

#### HBK-AUDIT-011：并发导入同名 EPUB，失败任务会删除成功任务的正文目录

- severity：P1
- status：open，真实 EpubImporter + 内存 SQLite + 临时文件已复现。
- 位置：`packages/fushi_engine/lib/epub/epub_importer.dart:134–145,160–165,227–239`；数据库插入 `packages/fushi_core/lib/src/database/database_content_misc.part.dart:209–225`。
- 根因：重复名检查使用未预留身份的库快照，两条导入都能选到同一 bookKey。各自依据旧快照判断目标目录是否属于活跃条目，第二条把第一条刚发布的目录当作孤儿替换；随后主键插入失败，catch 又无条件删除共享的 extractDir。
- 触发与影响：同库两条导入同时处理标题相同、内容不同的 EPUB，例如手工导入与后台入库重叠。入口各自的串行措施不能代替共享导入原语的所有权。唯一临时目录只避免解包互撞，没有解决最终目录互撞。可出现第一条已成功、数据库仍有该书，但正文目录被失败任务删掉。
- 真实入口包括 `book_import_dialog.dart:1206–1219` 与 `packages/fushi_engine/lib/media/discovery/import/discovery_engine_importers.dart:33–40`；两者均直接调用共享原语。探针使用默认 suffix 策略，通过覆写数据库读取方法，在真实查询返回后设置 barrier，确定性制造两次查重均先于插入的合法交错，不更改导入器实现。
- 隔离输出：一条 success、另一条 UNIQUE constraint failed；最终 `dbRows=1, directoryExists=false, chapterExists=false`。
- 修复建议：对共享存储的身份预留、目录发布、数据库提交建立统一所有权/串行边界；失败只能清理本任务拥有的目录，不能按最终路径猜测所有权。
- 验证方式：同标题并发 suffix/skip/ask 导入、手工和后台混合导入；所有成功返回的数据库条目必须保有自己的完整正文，失败不能破坏另一个任务。

#### HBK-AUDIT-012：文件名中的字面 # 被误当 URI fragment，章节地址被截断

- severity：P2
- status：open，真实 EpubParser + 临时 EPUB 已复现。
- 位置：`packages/fushi_engine/lib/epub/epub_parser.dart:907–911`；`packages/fushi_engine/lib/epub/epub_book.dart:1266–1273`；消费 `fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart:46–50,499–509`。
- 根因：manifest 的编码路径正确解码成磁盘文件名后，_relHref 又对真实磁盘相对路径调用 normalizeHref；后者无条件按 # 和 ? 切断，把文件名字符误当 URL 分隔符。
- 触发与影响：归档中含 `OEBPS/chapter#one.xhtml`，manifest 使用合法转义 `chapter%23one.xhtml`。解析能找到文件并生成一章，但记录的 href 变成 `OEBPS/chapter`，正文请求指向不存在的文件；同前缀资源还会碰撞。
- 隔离输出：普通章节 `routedFileExists=true`，# 章节 `hrefs=[OEBPS/chapter], routedFileExists=false`；字面百分号文件作为对照仍可正确定位。没有将 Windows 不允许的 ? 文件名当作产品反例。
- 修复建议：区分 URI 引用和已解码磁盘路径；只在 URI 层剥离 fragment/query，路径持久化和 URL 编码必须保留合法文件名字符。
- 验证方式：真实导入带 %23、%25 编码路径和实际 fragment 的 EPUB，验证章节/资源身份、持久化 href、构造 URL 与磁盘文件往返一致。

#### HBK-AUDIT-013：退书时先清控制器引用，关闭后台续播也可能不停播放

- severity：P2
- status：open，生产方法抽取的控制流反例已确认；未运行真实播放器/WebView E2E。
- 位置：`fushi/lib/src/pages/implementations/reader_fushi_page.dart:3328–3329,3417–3420,3458,3481–3483,3809–3812`。
- 根因：退出原语发起持久化后立即 pop，而 onSourcePagePop 先 await 探针和落库。dispose 开头将 _audiobookController 清空，导致同一 dispose 后面的停止条件永远为假；迟到的 onSourcePagePop 也无法再匹配原控制器。
- 触发与影响：退出后续播关闭，播放中退书；WebView/DB 等待超过路由退出时间，两条停止路径同时错过，会话继续在书架播放。detachReader 仅卸 reader 回调，不负责停止。
- 抽取探针输出：`READER_EXIT backgroundPlay=false, stopCalls=0, expected=1`。以可控 Future 模拟慢 flush，执行生产 onSourcePagePop、退出原语和相关 dispose 原句。
- 修复建议：在异步退出前捕获原控制器并按身份发起应有的停止；卸监听不能先抹掉停止判据。继续保留身份核对，避免旧页误停新页会话。
- 验证方式：真实播放器下延迟退出 flush，覆盖续播关闭/开启、快速重开另一书，断言只停止应停会话且不误停新会话。

#### HBK-AUDIT-014：旧双页文档的 spreadReady 可完成新章节的恢复

- severity：P2
- status：open，生产 callback 抽取的状态机反例已确认；未在原生 WebView 复现迟到投递。
- 位置：`fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart:2608–2625`；发送端 `reader_fushi_page.dart:815`；装载 `reader_fushi/navigation.part.dart:1010–1018`。
- 根因：正文恢复回执有导航 generation 校验，spreadReady 却不携带或核对代际，也不检查当前是否仍为 spread 文档，直接完成当前 completer、撤遮罩并取消超时。
- 触发与影响：双页 A 的图片就绪回执已发出但尚未处理时，用户转到正文 B；迟到的 A 回执会把 B 的未完成恢复当作成功，提前放行翻页和进度采样。该投递时序尚需真实 WebView 验证。
- 抽取探针输出：`currentGeneration=2, currentDocumentIsSpread=false, newRestoreSucceeded=true, ready=true, timeoutCancelled=true`。
- 修复建议：双页文档同样烘入并返回导航 generation，复用恢复所有权校验；失配或当前非双页的回执不能修改状态。
- 验证方式：真实桥接或可注入桥接测试中延后旧回执，在新导航开始后投递，断言新 completer、遮罩及超时保持不变。

#### HBK-AUDIT-015：缺失音轨被过滤后，cue 仍使用原下标，播放错轨

- severity：P2
- status：open，真实音轨 resolver + 临时文件已复现；未启动音频解码器。
- 位置：`packages/fushi_audio/lib/src/audiobook/audiobook_playback_files.dart:23–29`；接收入口 `fushi/lib/src/media/audiobook/audiobook_session_launcher.dart:42–49`。
- 根因：显式 audioPaths 过滤不存在的文件并压缩列表，却没有重映射 AudioCue.audioFileIndex；启动入口只检查结果非空。
- 触发与影响：登记三轨，第一轨被移动/删除后，列表变成后两轨；原 cue 下标 1 从第二轨变成第三轨，最后一轨 cue 还可能越界，跳句和字幕不再对应音频。
- 隔离输出：`requested_count=3 actual_count=2`；`cue_index_1_expected=track1.mp3 actual=track2.mp3`。
- 修复建议：保留轨道身份；缺轨时明确拒绝启动并引导修复，或返回并统一应用原下标到播放下标的映射。
- 验证方式：分别缺第一轨、中间轨、最后一轨，验证保留 cue 和恢复位置不会指向其他文件。

#### HBK-AUDIT-016：退书后台播放仍使用最后一章的局部 cue 列表

- severity：P2
- status：open，静态代码路径确认，未完成 session/UI 运行复现。
- 位置：`fushi/lib/src/media/audiobook/audiobook_session.dart:321–332`；装配 `reader_fushi/audiobook.part.dart:543–548`；消费 `fushi/lib/src/media/audiobook/audiobook_controller.dart:186–189,1657–1659`。
- 根因：普通 SMIL/JSON selector 对齐 EPUB 在 reader 内使用当前章节 cue 子集，detachReader 只清回调，不恢复控制器全书工作集合。全书列表虽然另有缓存，后台显示和更新实际仍消费局部集合。
- 触发与影响：启用后台续播，第一章退书后播入第二章/下一音轨，局部列表找不到该轨 cue，当前句和悬浮字幕可能停在旧章；通知下一句也因边界回调已卸而无法跨章。不将本来已经用全书 cue 的 SRT 路径算入反例。
- 修复建议：detach 时切回全书工作集合，或分离后台句子解析与 reader 局部高亮范围；重新 attach 再套用章节约束。
- 验证方式：两章两轨的真实会话，attach→第一章局部 cue→detach→推进下一轨，验证当前句、悬浮字幕、通知及下一句均更新。

#### HBK-AUDIT-017：本地词典导入绕过共用锁，可能删除后台更新的暂存目录

- severity：P2
- status：open，静态调用路径确认，未操作用户词典或运行 native 并发导入。
- 位置：`fushi/lib/src/models/dictionary_import_manager.dart:587–590`；本地入口 `dictionary_dialog_page.dart:976–998,1047,1647,1692`；App 委托 `app_model.dart:6529–6577`。
- 根因：下载/更新受 DictionaryDownloadController.run 约束并允许收后台，本地文件、文件夹和拖放入口却直接调用导入原语。双方共用固定 import_temp，进入时都会删除已有目录；共享原语本身没有写侧所有权。
- 触发与影响：更新收后台、native 正在写暂存目录时，再本地导入另一包，后者删除前者输出。除失败外，交错还可能让发布阶段把另一任务的暂存内容放进错误的词典目录。
- 修复建议：在共享服务统一串行导入/替换/删除生命周期，并让每个任务使用独立暂存；避免只禁用某一个页面按钮或重复嵌套上锁。
- 验证方式：后台更新在 native 返回前/发布前挂起，再从文件、目录、拖放导入另一包，验证任务排队或拒绝且不互删目录。

#### HBK-AUDIT-018：词典替换先永久删旧，发布或提交失败后没有回滚

- severity：P2
- status：open，静态失败路径确认，尚未运行文件系统/metadata 故障注入。
- 位置：`fushi/lib/src/models/dictionary_import_manager.dart:628–675,699–705,1027–1052`。
- 根因：native 成功后先删除旧 metadata 与目录，之后才发布新目录、复制 CSS/字体和写入新 metadata；catch 仅记录/重抛，没有恢复旧版本。页面宣称的失败保留仅对更早的解析失败成立。
- 触发与影响：旧版本已删后，最终目录发布/复制遇磁盘空间不足、附件复制失败或 metadata 提交失败；更新报错，但原词典文件和记录已丢失。新暂存也可能被下次导入清除。
- 修复建议：保留旧目录和元数据，完整准备新版本后协调发布与提交；失败恢复旧版本，全部成功后再清理备份。仍需先释放引擎映射，不能简单颠倒旧版释放顺序。
- 验证方式：分别在发布、copy fallback、附件复制和 metadata 提交处注入失败，验证旧词典、用户设置、重启后查词均保持可用。

### 验证与证据边界

- 主审独立执行 `epub_concurrent_probe.dart`、`epub_href_probe.dart`、`missing_track_probe.dart`、`reader_exit_controller_probe.dart`、`reader_stale_spread_ready_probe.dart` 并复核输出。证据留在本 worktree 的 `.codex-test/runtime-review-round2/`，汇总见 `results.txt`。
- EPUB 并发实验调用真实导入器、解析器、目录发布和内存 SQLite，仅读取阶段用 barrier 固定交错；没有改生产业务。# 路径实验调用真实解析器；音轨实验调用真实 resolver，但不代表已听到错误音轨。
- 退书和 spreadReady 是原方法/回调抽取探针，不包含真实 Flutter 路由动画、native WebView 消息投递或播放器。因此没有把这两项写成真机复现。
- 本轮不跑全量测试。音频子审尝试临时 Flutter session 用例时，既有 package_config 缺 fushi_srs，编译阶段失败、零测试执行；没有修改依赖，也没有将其算作产品失败或测试通过。纯 Dart 探针使用临时包映射运行。
- 未修改用户词典、书库、音频或云端数据。新增隔离复现另记本地 `docs/REGRESSION_BUGS.md`。首轮十项仍为 open，本轮没有验证或实施其修复。

### Next Scope

- 优先处理 HBK-AUDIT-011 的共享身份/目录发布与回滚所有权；随后核查其他格式导入器是否共享同类查重和失败清理缺口。
- 下一轮继续视频进度恢复与字幕状态、下载取消/重试后的入库幂等、云同步删除墓碑和资源回收。风格一致性、CLI 覆盖继续排除。

## 第三轮：视频异步状态、下载取消与删除传播

### Scope

- 基线：`4355d6420c2526a09f03cebbc13a7f55d48a59cf`。继续审查，排除风格一致性、CLI 覆盖，不实施前两轮修复。
- 检查视频 seek/退出持久化、播放器复用和 YouTube 字幕异步结果；发现直链队列的缓存归属、销毁及入库；torrent 创建/取消；普通云与互联删除墓碑的发布、过滤、确认和 host 应用；本地视频资源删除与其他格式导入清理。
- 主要文件：`video_player_controller.dart`、`video_fushi/subtitle.part.dart`、`discovery_download_queue.dart`、`video_download_pipeline_service.dart`、`sync_orchestrator.dart` 及 `sync_orchestrator/tombstones.part.dart`、`deletion_prompt.dart`、`app_model.dart`、`interconnect_sync_backend.dart`、引擎 `local_library_host_service/books.part.dart`、`epub_importer.dart`。

### Findings

新增 **9 项：P1 一项、P2 八项**。四项有真实组件的隔离反例，四项有生产方法抽取反例，一项为静态调用链发现；host 与队列实验的具体边界见各项说明。累计编号至 HBK-AUDIT-027，未重复计算先前的导入身份/目录冲突。

#### HBK-AUDIT-019：历史删除推送丢失墓碑时刻，可能误删 host 上重新加入的新条目

- severity：P1（历史同步可删除新版本正文，并生成新墓碑继续传播）。
- status：open，真实 host 服务 + 内存 SQLite 反例已确认；client→HTTP→host 完整链路仅静态核对。
- 位置：`fushi/lib/src/sync/sync_orchestrator/tombstones.part.dart:169–170,223–224`；`fushi/lib/src/sync/interconnect_sync_backend.dart:1426–1435`；`packages/fushi_engine/lib/sync/local_library_host_service/books.part.dart:336–365`。
- 根因：本地墓碑带 deletedAt，但分派和 DELETE 请求只传 itemKey。host 按同键当前行直接删除，不核对其 importedAt/存在起点；普通的用户即时删除 API 被拿来应用历史事件，仲裁上下文丢失。
- 触发与影响：client 于 100 离线删除旧书，host 于 200 重加同键书；例如客户端关闭内容传输、旧墓碑仍待推送时重连，就会补发旧删除。纯仲裁 helper 明确判定旧墓碑不适用，新书仍被 host 删除，且 host 以当前时间生成新墓碑，可能继续传播。host 的生产实现还会清理该条目的正文目录及关联数据。
- 隔离输出：`before importedAt=200, tombstoneApplies=false`；`after identity-only DELETE: present=false, hostTombstones=1`。探针调用真实 LocalLibraryHostService.deleteBook，并非实际发送网络请求。
- 修复建议：历史墓碑应用端点传递事件版本/时刻，由 host 在写锁内按存在起点条件删除；保留即时用户删除和历史事件应用的不同契约。未真正应用的旧墓碑不得生成新的传播墓碑。
- 验证方式：真实协议测试覆盖 host 重加早于、等于、晚于墓碑三种情况；后两种保留内容且不产生新删除事件，再做三设备传播回归。

#### HBK-AUDIT-020：本地删除失败仍被确认为已处理，后续不再提醒

- severity：P2
- status：open，两个生产方法抽取的控制流反例已确认；未注入真实磁盘/数据库故障。
- 位置：`fushi/lib/src/sync/deletion_prompt.dart:478–484`；`fushi/lib/src/models/app_model.dart:1024–1026`。
- 根因：_applyConfirmedDeletions 逐项捕获异常后只 debugPrint，正常返回；确认框据此无条件推进整批 high-water，调用契约不能表达部分失败。
- 触发与影响：用户确认删除，但一项因文件占用或数据库错误未删掉；确认框正常关闭、水位越过该墓碑，下轮失败项不再出现。
- 抽取输出：`after failed confirmed deletion: present=true, baseline=200, promptClosed=true`，同时有注入的 FileSystemException 日志。
- 修复建议：返回逐项执行结果，成功删除和明确保留可确认，失败继续待处理并向用户显示错误；任何批量确认机制都不能越过未完成项。
- 验证方式：同批一项成功、一项失败；确认失败项保留、可重试且下轮仍能收到，重试成功后才确认。

#### HBK-AUDIT-021：离线设备迟到发布的墓碑被时间水位当成旧闻

- severity：P2
- status：open，生产 syncDeletionTombstones 抽取 + 真实纯决策 helper + 假传输/持久化反例已确认。
- 位置：`fushi/lib/src/sync/sync_orchestrator.dart:1165–1175`；互联消费也使用同类标量水位。
- 根因：各端的删除发生时刻不是全局发布序列；将 deletedAt 最大值当作已复核水位，无法区分已处理的旧事件和第一次出现、但发生较早的离线事件。完整列出当前远端标记也不能解决尚未发布的问题。
- 触发与影响：A 在 100 离线删除，B 在 200 在线删除另一项；C 先确认 B，水位到 200。A 随后发布 100 的墓碑，C 即使完整读到，也因 at<=baseline 永久跳过，跨设备删除静默缺失。
- 抽取输出：第一轮 `candidates=[online-later], highWater=200`；第二轮 `cloudMarkers=2, candidates=[], baseline=200, errors=[]`。
- 修复建议：按墓碑身份/版本保存处理状态；如需增量游标，应使用有顺序保证的服务端发布序列，而非设备删除时间。与 HBK-AUDIT-020 一起重审确认模型。
- 验证方式：先确认晚事件，再发布早事件，第二轮必须出现新候选；覆盖离线和跨设备时钟差异，不能只测列出后读取失败。

#### HBK-AUDIT-022：不同直链同名文件被视为同一缓存，导入错误内容

- severity：P2
- status：open，真实 DiscoveryDownloadQueue + 假网络/importer + 临时文件已复现；未做真实站点下载。
- 位置：`packages/fushi_engine/lib/media/discovery/discovery_download_queue.dart:353–363`；共用目录装配 `fushi/lib/src/models/app_model.dart:6294–6297`。
- 根因：下载路径只取净化 basename；目标文件存在便直接当作本任务已下载，不核对 sourceId/itemId/URL 或归属。不同资源的完成文件和续传 .part 都可能共用路径。
- 触发与影响：A、B 两个源分别提供 book.epub 或 download.zip，先完成 A，再下载 B；B 跳过网络并导入 A 内容，界面却显示本次任务完成。
- 队列输出：`networkCalls=1 imports=[A:source-a.example, B:source-a.example] skippedSecond=true`。
- 修复建议：用稳定资源身份隔离完成文件与续传路径，并记录 URL/资源归属；仅同一资源的已完成产物允许重导复用。
- 验证方式：异源异 ID、同 basename 必须取两次各自内容；取消留下 .part 后换资源，也不能混合续传。

#### HBK-AUDIT-023：发现队列销毁不排空入库，关闭后仍可继续发布

- severity：P2
- status：open，真实队列行为已复现；接入关库后的影响为静态路径确认。
- 位置：`packages/fushi_engine/lib/media/discovery/discovery_download_queue.dart:372–374,556–567`；`fushi/lib/src/models/app_model.dart:8037–8038`。
- 根因：dispose 仅置取消标志并关网络，不能取消/等待已经 await 的 importer。关库排空函数直接 dispose 后继续关闭数据库，导入器却仍可能处于解压或准备提交阶段。
- 触发与影响：入库执行期间恢复备份、迁移数据根或销毁队列；关闭返回后导入继续发布文件/写旧连接。任务可能最终显示 cancelled，却实际已经入库。
- 队列输出：`disposeReturned: published=false taskStatus=running`；释放阻塞 importer 后 `published=true taskStatus=cancelled importedCount=1`。published 在假 importer 中记录，不冒充真实关库写入已复现。
- 修复建议：提供可 await 的停止/排空接口，禁止新任务并等待在途提交安全结束；取消状态必须与实际是否提交一致，关库必须等待该边界。
- 验证方式：阻塞 importer 后关队列/关库，断言关闭不会先于安全退出；关闭后不再发布或使用旧数据库。

#### HBK-AUDIT-024：种子添加请求在飞时取消，后端任务仍可能继续下载

- severity：P2
- status：open，静态调用链确认，未执行真实后端或故障注入。
- 位置：`packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart:1568–1585,2229–2249,2269–2273`。
- 根因：cancelJob 仅当 backendTaskId 非空才暂停后端；enqueue 先保存 torrentHash，后执行 addTorrent，最后才登记 backendTaskId。添加在飞时取消会使持久行/租约失效，但没有等待添加结果并补偿暂停的边界。
- 触发与影响：后端添加 RPC 未返回时取消，UI 行已 cancelled；RPC 后来成功，后续阶段 CAS 失败退出，已创建种子仍耗带宽和磁盘。
- 修复建议：取消与在途后端创建协调，取得确定任务身份后暂停；创建路径发现取消/租约丢失时必须执行补偿，并将取消完成状态绑定实际停止结果。
- 验证方式：使用既有 pauseAdd 假后端，等待 addEntered 后取消再释放 add；断言最终种子被暂停、任务仍取消且无无人管理下载。

#### HBK-AUDIT-025：seek 在途退出，用滞后的原生位置覆盖目标断点

- severity：P2
- status：open，生产方法抽取的控制流反例已确认；未运行真实播放器/数据库。
- 位置：`fushi/lib/src/media/video/video_player_controller.dart:4682–4691,6132–6141`；对照 tick 处理 `3903–3907,4189–4202`；退出入口 `video_fushi_page.dart:7038–7046`。
- 根因：tick 会把普通 seek 在途的旧 position 调和成目标位置，flushPosition 和 dispose 兜底却保存裸 positionMs；首次恢复保护 _isRestoringPast 不覆盖普通用户 seek。各持久化入口的事实口径不一致。
- 触发与影响：暂停/缓冲时从 10 秒跳到 60 秒，原生位置尚未追上；tick 已保存 60 秒，立刻退出却又写回 10 秒，重开落到旧断点。
- 抽取输出：`pendingTarget=60000, raw=10000, writes=[60000, 10000, 10000], expectedFinal=60000`。
- 修复建议：所有保存入口统一消费已调和位置/待落地目标的所有权规则，同时修正 flush 和 dispose；明确确认 seek 失败后再退回真实位置。
- 验证方式：慢 seek/暂停 seek 后立即退出或换集，断言最后数据库写仍为有效目标；再覆盖 seek 失败、首次恢复、向后跳转。

#### HBK-AUDIT-026：YouTube 手选字幕请求的迟到结果可覆盖新集或重新开启已关闭字幕

- severity：P2
- status：open，生产方法抽取的控制流反例已确认；未运行真实 YouTube/Flutter。
- 位置：`fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart:289–294,2160–2196`；控制器复用 `video_fushi_page.dart:5116–5117`。
- 根因：手选不传可选 loadSeq，下载后跳过媒体代际检查，只核对 mounted；另无字幕选择意图代际，关闭和选择另一轨也不能作废旧请求。加载指示条并未禁止这些用户操作。
- 触发与影响：A 集选择未缓存的轨道，下载中切到 B 或关闭字幕，A 返回后仍 setCues 并改 currentSubtitleSource；复用控制器的新一集会显示旧字幕，关闭状态也可能被反转。
- 抽取输出：`currentEpisode=episode-B, source=old-A-track, cues=[A subtitles], expected=B subtitles`。
- 修复建议：每次字幕选择捕获媒体代际、选择意图代际、控制器/客户端身份；所有异步边界后校验。换集、关闭、手选统一作废旧意图，自动选择也不能抢占后来的用户操作。
- 验证方式：两条可控字幕请求反序完成、下载中关闭、下载中换集，断言只有仍拥有当前选择意图的结果可以提交。

#### HBK-AUDIT-027：EPUB 解析失败没有清理解包目录，重复失败持续占用书库空间

- severity：P2
- status：open，真实 EpubImporter/解析器 + 临时文件 + 内存 SQLite 已复现。
- 位置：`packages/fushi_engine/lib/epub/epub_importer.dart:41–49,79–87`；清理仅在后续 _persistParsed 的 `227–239`。
- 根因：创建 .tmp 目录后，在调用 _persistParsed 的 try/catch 之外 await 解析 isolate。XML、CRC、缺结构文件或字符计数阶段抛错时，流程未进入清理逻辑，已经解出的内容留在正式书库根。
- 触发与影响：含大资源、结构损坏的 EPUB 导入失败，书架无新增行，却留下整份或部分解包内容；同包重试使用新临时目录，空间继续累积。该失败路径未清理，不声称所有外部清理工具都无法移除它。
- 隔离输出：两次 `XmlTagException` 后 `failedImports=2, dbRows=0, leftoverTempDirectories=2, leftoverBytes=4194348`；最小包每次只含 2 MiB 资源。
- 修复建议：从建立暂存目录开始就覆盖整个解析/持久化生命周期，失败统一清理本任务暂存；成功发布后按明确所有权移交，避免修复重现 HBK-AUDIT-011 的误删。
- 验证方式：坏 container、坏 OPF、CRC/解压中途失败，分别验证无新行且无残留任务目录；已有成功书和其他在途任务目录保持完整。

### 验证与证据边界

- 主审独立重跑第三轮七份入选探针：stale_live_delete、failed_delete_ack、late_tombstone、discovery_download、video_pending_seek_exit、video_youtube_subtitle_generation、epub_parse_cleanup；均得到预期反例输出。真实组件、抽取代码及假依赖的层次已在各项注明，退出 0 不代表产品正确或问题已修复。
- 证据目录为本 worktree 的 `.codex-test/runtime-review-round3/`，同步输出另见 sync_results.txt，队列输出另见 discovery_download_probe.log，统一摘要见 results.txt。
- 主审第一次单跑 failed_delete_ack 忘记传临时包映射，编译失败、没有执行反例；补上同一 sync_probe_packages.json 后独立执行退出 0。没有将编译失败算产品回归或验证通过。
- 同类导入检查还读到 Manga/PDF 的查重与失败清理共享 HBK-AUDIT-011 所述风险。Manga 并发探针本轮出现 Windows 建目录/句柄交错，但未得到“活库行正文目录消失”的输出，因此不计作新增缺陷或新的数据丢失复现。
- 本地视频删除后端 skip 失败继续删除是源码明确记录的 best-effort 取舍，本轮未把这项既有取舍另报为缺陷。没有全量测试、真机/native 播放器、真实网络下载、真实云端或双设备验收；未修改用户数据。
- 已复现/抽取反例另记本地 docs/REGRESSION_BUGS.md。前两轮十八项状态未变，仍未修复业务代码。

### Next Scope

- 优先修复历史墓碑应用的条件删除与逐项确认，再统一检查离线发布、重加和三端传播；同名下载缓存与异步字幕也需绑定明确任务身份。
- 下一轮检查制卡队列/媒体导出失败后的恢复与幂等、Profile 切换中的异步写回、来源库扫描与重扫删除、导入格式转换的原子性。继续排除风格一致性与 CLI 覆盖。
