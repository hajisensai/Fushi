## BUG-4434 · 同步基线不带远端身份：多 host 共用互联 live 基线，换 host 后静默导入旧值
- **报告**：2026-11-10（用户：审计 sync-live 修复包 V-A1 / D12 / D11 作用域部分）
- **真实性**：✅ 真 bug（行号以 7f00ae0a6c0 为准）：
  - live 基线键 `(assetKey, dimension)` 不带 host：`fushi/lib/src/sync/interconnect_book_progress_sync.dart:272-278,292-298,315-328`、`fushi/lib/src/sync/interconnect_playback_position_sync.dart:146-149,183,196,212-215` 只按通道类型的固定维度（`progress_live` / `video_position_live` / `audiobook_position_live` 及 `_pending`）读写；`fushi/lib/src/sync/sync_backend.dart:383` `syncChannelScopeOf` 把互联一律映射成 `fushiServer`。
  - 会话可在中途换 host：`fushi/lib/src/sync/interconnect_sync_backend.dart:521` 掉线即 `_sessionResolved = false`，`:534-579` `_ensureResolved` 下次请求重新选路，可能落到另一台 hostId 的 host，基线照用上一台的。
  - 结果：client 配了 A、B 两台 host，与 A 达成一致（基线 = X）后会话切到 B（B 在 Y）——本端仍是 X = 基线、B ≠ 基线 → `applyRemote`，B 的进度静默覆盖本机（新测试修复前实测本端 sectionIndex 被改成 7，期望 2）。
  - sweep 的播放位置阶段拿 host 清单值直接判定（`fushi/lib/src/sync/sync_orchestrator/books.part.dart:328-333`），清单可能取自另一台 host 的缓存。
- **[x] ① 修复** — aa76ab16c86：
  - `packages/fushi_engine/lib/sync/sync_channel_scope.dart`：`syncRemoteTag`（sha256 前 16 位十六进制，不把 hostId 明文写库）、`remoteScopedKey`（`<维度>@<tag>`）。
  - `interconnect_sync_backend.dart`：`_scopeHostId` / `_hostScopeSerial`（`_ensureResolved` 选定候选后按其 hostId 维护，老条目无 hostId 都是 null、换地址不算换 host）；`InterconnectHostPin` / `InterconnectHostScope` / `LegacyBaselineAdoption` / `InterconnectHostChangedException`；`liveHostScope()`、`checkHostPin()`、`debugSwitchHostScope()`；带 pin 的 `getLiveBookProgress` / `getLiveBookProgressSnapshot` / `getLiveVideoPosition` / `getLiveAudiobookPosition`，`putLive*` 加 `pin`。pin 经 zone 下传，live 端点在 `_ensureResolved` 之后、`buildRequest` 之前同步核对（兼容层的每次 GET / PUT 各自核对），换了 host 在发请求前抛。
  - 新文件 `fushi/lib/src/sync/sync_baseline_scope.dart`：`baselineStorageDimension`、`ensureBaselinesAdopted`（单 host → 旧无后缀行覆盖后搬走；多 host → 删除；有老条目 → 不动；一个事务、进程内按 (db, 存储维度) 只做一次）。
  - `InterconnectBookProgressSync` / `InterconnectPlaybackPositionSync`：去掉 `const`，`bind()` 绑一台 host（领养 + 存储维度 + pin），所有基线读写走存储维度、host 读写带 pin；公开 `dimension` 仍是逻辑名。推送前记「待确认」行前先核对 pin。`LivePositionReporter` 遇 host 变更换一个绑新 host 的实例，把该值按新 host 重新判定一次。
  - sweep（`books.part.dart`）：阶段开头 `bind()`；播放位置未收敛条目一律在锁里经带 pin 的读取重读 host 再判定（清单只用来跳过）；逐条遇 `InterconnectHostChangedException` 原样抛，阶段报一条 `live progress: host changed mid-round` 后结束。`videos.part.dart` / `audiobooks.part.dart` 随之去掉不再使用的锁代数参数。
  - 弹窗：`loadPlaybackPositionConflicts` 同一次加载每种条目共用一个实例（应用用同一实例）；对比弹窗 `SyncCompareEntry.liveHostPin` 记加载时的 host，应用时新绑的 host 不是它就抛、不落地。
- **[x] ② 加自动化测试** — `fushi/test/sync/interconnect_live_baseline_host_scope_test.dart`（两台真 server + 真 client backend）：V-A1 主场景（修复前红：本端 sectionIndex 7 ≠ 2）、绑定后换 host 读写在发请求前抛且不写 host / 不留待确认行、sweep 第二条起换 host 只报一条且 B 作用域无行、老条目多地址不算换 host、领养五种（单 host 搬走 / 多 host 删除且首轮判冲突 / 混配保留 / 降级再升级覆盖 / 并发绑定不倒退）；`fushi/test/sync/sync_channel_scope_test.dart` 加 `syncRemoteTag` / `remoteScopedKey` 形态。假互联后端经 `fushi/test/helpers/interconnect_legacy_host_scope.dart` 落老条目作用域，既有断言不变。
- **修复提交**：aa76ab16c86
- **备注**：
  - 不动 Drift schema；新增的只是带 `@<tag>` 后缀的 `dimension` 取值。
  - 影响范围（升级 / 降级）：单 host 且带 hostId 的用户旧行整体搬到该 host 名下，判定不变；全是老条目（无 hostId）的用户继续用无后缀行，判定不变；多 host 用户旧行被删，各 host 首轮两端有戳且不同的书判一次冲突（播放位置在 BUG 步骤 9「缺基线不再比墙钟」之后同理）。装回旧版后旧代码读无后缀维度：单 host 用户书籍判一次冲突、播放位置走旧 LWW 一次；再升级时按「覆盖后删除」吸收。不丢进度，只多问一次。
  - 残留：无 hostId 的多 host 用户仍共用一份基线（URL 不是 host 身份，取舍 T6），学到 hostId 或重新配对后分槽；单地址组不核对 hostId（V-B4）时同一 URL 上换了 host 会套用旧基线（归 client-routing）。
  - 云通道 / 互联文件箱的 `progress` 基线分槽见下方「文件箱进度基线」一节。

### 文件箱进度基线（云通道 + 互联文件箱，计划步骤 8 + 跨包 X3）
- **真实性**：✅ 真 bug（行号以 7dea39fc846 为准）：`fushi/lib/src/sync/sync_manager.dart:46-51` `progressBaselineDimensionOf` 对全部云后端返回 `'progress'`、互联返回 `'progress__fushiServer'`，不带远端身份；`sync_manager.dart:159,171` 构造时定死，`:576`（读基线）、`:630`（synced 写）、`:886-890`（导入写）、`:990`（导出写）全用它；`fushi/lib/src/sync/sync_compare_dialog.dart:475-478` 同读这一行。换云类型 / 账号 / 服务器后，旧远端上的共同祖先被拿去判新远端：本地 == 基线、新远端 ≠ 基线 → `resolveProgressSync`（`sync_progress_resolver.dart:27-48`）判「只远端动了」→ 新远端的旧进度静默导入（orchestrator-3）。新测试修复前实测：远端 A 同步后换 B（B 是更早的进度），B 作用域不存在、旧维度被 A 的基线占着。
- **[x] ① 修复** — 31ab247de2a：
  - `fushi/lib/src/sync/sync_baseline_scope.dart`：`SyncRemoteIdentified`、`SyncRemoteIdentityUnavailableError`（`SyncBackendError` 子类）、`SyncRemoteScope`、`syncRemoteScopeOf`（剥混淆包装 → 自报身份 → 互联 `liveHostScope` → 云「类型 + 账号 + 服务器」→ 认不出不分槽）、`cloudRemoteScopeOf`（账号取 `currentEmail` 规整值并记进设备本地偏好 `sync_remote_account__<type>`，为空回退记下的值，都没有就抛；WebDAV 取规整 URL、FTP 取主机；其它云类型有带后缀冷却戳 → 旧行删除，否则搬走）、`progressBaselineStorageFor`（存储维度 + 领养 + 互联 host pin）、`clearSyncRemoteAccount`。
  - `sync_manager.dart`（跨包 X3）：`_progressDimension` 改为惰性 memo 的 `progressBaselineStorageFor`；四个读写点用存储维度，`conflictDimension` 仍报逻辑名；`syncAllBooks` 开轮先取作用域（认不出远端整段抛出，编排器记一条 `books:` 错误）；互联文件箱在判定前、synced 写基线前、导入落地前、上传后写基线前各调 `checkHostPin`，`InterconnectHostChangedException` 从 `syncBook` 原样抛、`syncAllBooks` 结束本阶段。
  - `sync_compare_dialog.dart`：文件箱基线循环外取一次存储维度；认不出远端时按无基线展示。
  - `interconnect_sync_backend.dart`：`checkHostPin` 文档写明文件箱调用约定。
- **[x] ② 加自动化测试** — `fushi/test/sync/sync_baseline_remote_scope_test.dart`（作用域工具：邮箱缺失一轮不换槽、从未取到抛错、换账号 / 换 WebDAV 服务器换槽、真 `DropboxSyncBackend` 单例类型识别并回退记下账号、`clearSyncRemoteAccount`、云领养搬走 / 删除、真互联 backend 单 hostId 带后缀 + pin / 无 hostId 不带后缀、自报身份 fake / 普通 fake）；`fushi/test/sync/sync_progress_baseline_remote_scope_test.dart`（SyncManager：A 上一致后换 B 判冲突不导入、回 A 导出、旧 `progress` 行被首个远端领养且判定不变、认不出远端不落地且整段抛出、互联文件箱读远端进度 / 上传时换 host 不导入不写基线；修复前 5 条全红）。
- **修复提交**：31ab247de2a
- **备注**：
  - 登出时忘掉 `sync_remote_account__<type>`：已接。没有放进各后端的 `signOut`（它们只拿得到 `SyncRepository`，且每个后端各写一遍会漏），而是把应用里仅有的两处登出（设置页「退出登录」`sync_settings_schema/account.part.dart`、鉴权失效自动登出 `manual_sync_ui.dart`）收成共用入口 `signOutSyncBackend`（`sync_baseline_scope.dart`）：先忘账号，再后端登出、清内存缓存、清该通道目录缓存。记账号与忘账号共用 `cloudBackendTypeOfChannel` 这一张对照。测试：`sync_baseline_remote_scope_test.dart`（真 Dropbox 单例登出后邮箱缺失即抛、只清自己通道的目录缓存与账号）、两条源码守卫改钉共用入口。未运行（重活队列让给别的会话）。
  - `sync_remote_account__<type>` 应列入 `deviceLocalPrefKeys`（归 client-routing，未接；未列入时随备份到新设备只在邮箱缺失时被用作回退）。
  - 同类型下换过账号 / 服务器而持久化状态看不出来的老用户，按「只用过当前云类型」领养，首轮仍可能出现一次旧式导入（T4 残留）。

### 评审修正（af3281328dd，2026-11-10）
- **compat-1 / correctness-3**：作用域按「选中候选自己的 hostId」定，同一台 host 一条地址带 hostId、一条手输老条目（常态：学习只给锚点补 hostId，手输条目只在 URL 恰被公布时补标）就落两槽，换网各用一份旧基线反复判冲突、实时上报 held，两条地址互切被当成换 host；`liveHostScope` 恒 keep。修复：新增纯函数 `interconnectScopeHostIdOf`（`interconnect_sync_backend.dart`）——老条目与某条带 hostId 的候选两边都钉指纹且相等，或（未都钉指纹时）实际凭据 `interconnectTokenFor` 相同，即认领那台的 hostId；指纹不同不认；对上多台 → 认不出。`_scopeHostIdOf` 与 `liveHostScope` 的领养判定都用它，只有认不出的老条目才 keep。残留：两台 host 手动配了同一个 token 且都没钉指纹时被当成同一台。`_adoptOne` 的 move 改为：目标行不存在或相等 → 照搬；已存在且不同 → 两行都删（来源不可考，首轮无基线判冲突、不丢数据），取代「旧行一定更新、覆盖目标」的假设（降级再升级的用例随之改断言）。
- **correctness-2**：`sync_remote_account__<槽位>` 列入 `SyncRepository._perChannelDeviceLocalBases`（键基名 `SyncRepository.syncRemoteAccountPrefBase`），并在 `kKnownPreferenceKeyPrefixes` 登记前缀；不再随备份 / 设置同步到登着别的账号的设备（原「归 client-routing、未接」的备注作废）。
- **compat-2**：`syncAllBooks` 开轮 `await _progressBaseline()` 遇 `SyncRemoteIdentityUnavailableError` 整段抛出，这一轮所有书的内容 / 统计 / 有声书断点都不传。修复：`SyncManager._progressBaselineIfKnown` 认不出时返回 null 并记下错误；自动路径只判不需要共同祖先的情形（单边、两端一致），两端都有戳且不同的书本轮 skipped + error（不报冲突），所有基线写入跳过；手动路径照旧必须认出远端。`syncAllBooks` 跑完后带逐本结果抛 `SyncBooksIncompleteError`，`sync_orchestrator.dart` 书阶段收下结果（冲突 / 内容错误照常）并记一条 `books:` 错。
- **compat-3**：`LivePositionReporter` held 时只读本地基线、从不经网络，host 变更永远发现不了。修复：held 分支先 `InterconnectPlaybackPositionSync.verifyBoundHost()` → `InterconnectSyncBackend.verifyHostPin`（会话被掉线置脏时先重新选路；已解析不发请求），换了 host 就抛，`_send` 换绑并作废 held，按新 host 作用域重判这次上报。
- **tests-1**：「并发绑定」用例测不出按 (db, 存储维度) 只做一次的缓存（第一次领养后无后缀行已空，重跑读到空集）。改为领养后再放一条无后缀行、第三次绑定后它原样保留、已推进基线不变；去掉缓存时这条会被搬动 / 冲掉 → 红。
- 测试：`interconnect_live_baseline_host_scope_test.dart`（混配认不出 / 同一台 host 混配归同槽并领养、互切 pin 不变 / 目标槽冲突两行删 / 缓存可观测 / `interconnectScopeHostIdOf` 五条纯函数）、`sync_baseline_remote_scope_test.dart`（账号键全部设备本地）、`sync_progress_baseline_remote_scope_test.dart`（认不出远端：两端都动 → 该书 skipped、整段带结果抛 `SyncBooksIncompleteError`；单边本机 → 照常导出；单边远端 → 照常导入；均不写基线）、`interconnect_remote_playback_session_test.dart`（held 中换 host → 换绑后在新作用域记基线）。未运行（重活队列让给别的会话）。
