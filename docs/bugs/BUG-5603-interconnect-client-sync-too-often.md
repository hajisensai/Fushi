## BUG-5603 · 互联 client 同步过频：切模块 / 每分钟 / 退后台都对 host 跑一轮，电脑 host 持续卡
- **报告**：2026-11-28（用户：iPhone「好像一直在做同步」「切个模块就在同步」，电脑 host 因此持续卡）
- **真实性**：✅ 真 bug（沿代码路径确认六处多余触发，见下「根因」，各带 `file:line`）
- **[x] ① 已修复** — 分支 `pr/client-sync-throttle`
- **[x] ② 已加自动化测试** — 见「测试」
- **备注**：host 侧（`fushi_sync_server.dart`、`sync_state.part.dart`、`collection_sync_engine.dart`、`local_library_host_service/`）不在本修复范围，另案处理。

### 根因

1. **进复习 tab 就整轮同步**：`fushi/lib/src/srs/srs_app_runtime.dart` `_onHomeTabChanged` 每次切到复习 tab 调
   `sync.syncThrottled()`，节流只有 60 s（`srs_sync_scheduler.dart` `kSrsSyncMinInterval`）。这一轮跑全部通道，
   要拿整轮同步锁，在 host 上发一串 PROPFIND / GET / PUT。本机改动已由推送（`SrsLocalPush`）推出，host 上的新数据
   已由长轮询即时同步，所以这一轮几乎总是空跑。
2. **定时 sweep 冷却中也登记任务**：`fushi/lib/src/sync/sync_auto_trigger.dart` `_runAutoSyncAll` 先
   `_beginSyncActivity` 在任务表开一项，再排整轮锁，拿到锁后才判失败退避和逐通道 5 分钟冷却。首页每分钟一次 tick，
   任务表就每分钟闪一项；锁被复习同步占着时，这一项一直挂在「等待中」。
3. **capabilities 探测无缓存**：视频 tab 每次切换（`home_video_page.dart` → `video_remote_targets.dart`
   `probeVideoRemoteTargets` / `filterInterconnectHostTargets`）都对每台已配对 host 打 `GET /api/capabilities`
   （`interconnect_host_client.dart` `capabilities()` 每次直接发请求）。另外 7 个 client 经
   `interconnect_host_channel.dart` `probeInterconnectCapability` 各自发请求，同样不缓存、不合并并发。
4. **地址解析失败无退避**：`interconnect_sync_backend.dart` 里 `onConnectivityError: () => _sessionResolved = false`
   连接一出错就把会话打回未解析；`_ensureResolved()` 只合并并发请求，不看上一轮是否刚失败，于是后续每个请求（每本书、
   `waitSrsChanges` 长轮询、各页读取）都把全部候选地址重探一遍。
5. **长轮询断线盲目补跑整轮**：`fushi/lib/src/srs/srs_interconnect_watch.dart` `SrsInterconnectWatcher._loop`
   失败时丢掉令牌，退避后无条件 `_onChange()` 跑一整轮复习同步。iOS 每次退后台都会掐断长轮询，回来就空跑一轮。
6. **空操作写也发表变更通知**：drift 的 insert（含 `INSERT OR IGNORE` 没插入、`DO UPDATE … WHERE` 没命中）和
   `customUpdate(updates:)` 无论改没改行都通知；UPDATE 写回同值也算命中。合集观察者（`sync_auto_trigger.dart`
   `installCollectionsSyncWatcher`）收到通知 8 s 后跑一轮合集同步。每次调用都会写的有：
   `packages/fushi_core/lib/src/database/database_tags_sync.part.dart` `getOrCreateTagByName`、
   `markMediaNsfwIfUndecided`；`database_library.part.dart` `addToCollectionRaw`（书系列归组器每轮对全部既有成员
   重调）、`_claimCollectionForUser`（`customUpdate`）、`_writeDenseCollectionOrder`（序号没变也照写）。

### 修复

1. 进复习 tab 改走 `srsSyncOnTabEntry`（`srs_interconnect_watch.dart`），分两路：
   - **经互联 host 那一路**：只有 `SrsSyncScheduler.hasHostLaneGap` 为真才跑全部通道。为真的情形：本进程还没完整
     跑成过一轮；或之后这一路（互联通道 / 本机目录）有一轮失败，包括推送、长轮询、常规同步后置步骤触发的轮次；或互联
     推送有失败退避。缺口补上就不再跑，不按时间节流。本机还没推出去的改动交给排着的推送，进 tab 时立即 `flush`。
   - **云盘 / 文件夹位置**（不经 host，也没有变更通知）：保留 60 s 节流拉取（`pullDirectLocationsThrottled`）。
     这一路失败不算 host 缺口，坏掉的云盘通道不会让每次进 tab 都去打 host。
   - 自动同步关着或首次同步没确认时，进 tab 是唯一的自动同步，保留原来的节流全量。
2. `_runAutoSyncAll` 在 `_beginSyncActivity` 之前先判 `_autoSweepCooledDown`（失败退避窗，或每条自动通道都在成功
   冷却窗里）。命中就只公布 `cooledDown` 结局，不登记任务、不排锁。锁里的逐通道判断保留，因为排队期间状态可能变化。
3. 新增 `InterconnectHostChannel.capabilities`：进程级缓存，TTL 2 分钟（单调时钟），按「host + 会话绑定」分槽。
   每次查都先比对这台 host 的配对配置签名（地址、启用、hostId、token、指纹、设备名、全局回落 token），取消配对、
   重新配对、改地址时旧条目当场作废。只缓存 200 且是 JSON 对象的应答；连不上、401、非 200、非 JSON 一律不缓存，
   但同时发出的请求会合并成一次。
   - `InterconnectHostClient.capabilities()` / `declaresCapability()` 吃这份缓存。
   - `probeInterconnectCapability` 也走同一份缓存，但缺省 `maxAge = 0`：只合并并发请求，拿到的结果写回缓存。这样
     AI 指派等会被 host 改动的能力位不会读到旧值。
4. 全部候选都探不到时记一次失败，退避从 2 s 起翻倍、封顶 2 分钟。退避期内 `_ensureResolved` 直接抛
   `SyncPeerUnreachableError`，不再探测，调用方原有处理不变。`resetResolveBackoff()` 在以下时机清零：
   - 解析成功、配置签名变化、`authenticate` / `signOut`；
   - 别的互联请求经这台 host 拿到应答（可达性观察者）；
   - 网络变化或回到前台（`interconnect_p2p_app.dart`）；
   - 手动「立即同步」：常规的 `runManualFullSync` 和复习的 `SrsAppRuntime.syncNow` 都会调。
5. 长轮询断线 / 没准备好期间不丢令牌，重连后带原令牌接着问。host 在这期间有新数据时，令牌不同、立即返回，跑一轮；
   host 重启过时令牌按启动时刻起步，也必然不同，同样跑一轮；host 没变就照常挂住，什么也不跑。
6. 上述五处改成先查后写，或者把条件放进 WHERE，已经是目标状态时不发写语句、不发通知。

### 测试

- `fushi/test/srs/srs_interconnect_watch_test.dart`
  - 断线后带原令牌重连，host 没变时不补跑；host 有新数据时同步一次；退后台期间令牌保留。
  - `srsSyncOnTabEntry` 各分支：反复进 tab 不跑全部通道；有缺口才跑；排着的推送立即推；只有互联推送失败才算缺口。
- `fushi/test/srs/srs_sync_scheduler_test.dart` `hasHostLaneGap`
  - 启动后有缺口，跑成后没有；host 那一路失败后又有。
  - 只有云盘失败时不算缺口；库没开的那一轮不算补上。
  - 直连拉取按 60 s 节流。
- `fushi/test/sync/sync_auto_trigger_lifecycle_test.dart`：冷却 / 退避窗内 sweep 不登记任务，过了冷却照常登记。
- `fushi/test/database/noop_write_no_table_update_test.dart`：五处空写在第二次调用时不发表变更通知，返回值和状态不变；
  真有变化时照常通知。
- `fushi/test/sync/interconnect_host_channel_test.dart`「能力表缓存」：TTL 命中与过期、`maxAge`、并发合并、失败不缓存、
  失效、按绑定分槽。
- `fushi/test/sync/interconnect_host_client_channel_test.dart`：连续探测只打一次。
- `fushi/test/sync/interconnect_session_reuse_test.dart`「选路失败退避」：间隔翻倍、封顶、退避期内不探测、
  重置与清零、可达性观察者。
