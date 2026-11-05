## BUG-4075 · iOS / Android 互联 SRS 同步中内存耗尽（SIGABRT / Scudo OOM / Dart Out of Memory）
- **报告**：2026-11-04，来自崩溃报告的整批分诊，共 4 份：
  - Android `7oF6GvM4Ii`：Xiaomi，3.3.0-debug.23213，Scudo OOM 中止，pss 约 3.3 GB，同步阶段停在 `stage=downloading`。
  - iOS `n1i0ET11Ea`、`vll_gRx-_8`、`_QErzK4JT5`：iPhone18,3，iOS 27.2，3.3.0-debug.23213，累计约 12 次 SIGABRT。
  - 最新出现版本是 23213。
- **真实性**：⚠️ 内存耗尽确实发生，**根因没有定位到**。
  - 已有证据：
    1. **发生在 BUG-4001 / BUG-3993 修复之后。** 这两个修复首个进入的构建是 23152，而这批报告来自 23213，说明它们不是同一个已修的问题。
    2. **iOS 崩溃位置。** 中止帧在 `Runner+31961832`，偏移落在静态链接的 Rust 库段内，与 `fushi_fsrs` 一致。CI 没有保留 dSYM，所以无法符号化。
    3. **崩溃前的日志尾。** 面包屑依次是 `start:heads`、`start:identity`、media 阶段、downloading 阶段，rss 在 1.0–1.4 GB 之间。
    4. **Dart 侧也耗尽了内存。** 拼接 collections-live-sync 响应体时，`StringBuffer.toString` 报出 Dart `Out of Memory`（`fushi/lib/src/sync/interconnect_sync_backend.dart:294-304` `_readBodyBounded`）。此外 rwkvReplay 报出 `SrsCoreException out of memory`。
    5. **大量 retire 报错。** 多份日志都有 `profile X is no longer the active SRS profile`，来自 `fushi/lib/src/srs/srs_profile_stores.dart:124-144` 的 `_handOver` 退役旧 store。
  - 待证伪的假设（**推测，未验证**）：
    - (a) `native/fushi_fsrs/src/store/mod.rs:281` 给每个连接设 64 MB page cache 加 256 MB mmap。读池大小为核数的一半并有上下限（`read_pool.rs`），连接数乘上去会把移动端地址空间和 RSS 推高。
    - (b) 档案切换时，被退役的 store 在进行中的同步结束前仍持有原生 core，新旧两份 core 同时驻留。
    - (c) `_readBodyBounded` 的上限按字节算，但先拼 String，大响应会在 Dart 堆上占约两倍内存。
- **[ ] ① 未修复**：根因证据不足，不应凭假设改 PRAGMA 或加上限来掩盖症状。下一步需要以下证据：
  - ① CI 归档 iOS dSYM，使 `Runner+偏移` 可以符号化；
  - ② 在同步各阶段的面包屑里记录原生 core 实例数和连接数；
  - ③ 用大库（与用户量级相当的卡片数）在移动端模拟器上跑一次完整互联同步，并记录 RSS 曲线。
- **[ ] ② 未加自动化测试**：根因确定之后再加。
- **备注**：
  - `n1i0ET11Ea` 日志里另外发现的 IPv6 回拼 bug 已经单独由 BUG-4070 修复。那个 bug 会让每轮同步失败，但不是内存耗尽的原因。
  - **2026-11-05 续报**（同一台 iPhone18,3 / iOS 27.2）：`n5OctGeoZv`、`203OplWhew`、`HGELrYwLzJ`、`-gRMoCHExn`、`qST-r751jz`，3.3.0-debug.23469 / 23480。签名同族：JavaScriptCore EXC_BREAKPOINT（`JavaScriptCore ← WebCore ← WebKit+15172248` 于 libdispatch 队列，即 WebKit 内容拦截规则编译）、`Runner+32094696` abort、liblangid / libswiftCore abort，Dart `Out of Memory` 于 `SrsCore._utf8 ← SrsCore.sync2`（media 阶段）与 `PlatformViewsService.initUiKitView` 编码创建参数；崩溃前面包屑 `srs_sync stage=downloading/uploading`、`srs_v1_migrate`，rss 0.7–2.0 GB（maxRss 2.17 GB）。**两个构建都早于 BUG-4013 修复**（PR #2834 合并点序号 23591），不能用来判 4013 是否覆盖本 bug，结论不变：等 ≥23591 的 iOS 报告。
  - 证据缺口 ① 由 BUG-4102 补上：CI 按序号存 iOS dSYM（未签名 / TestFlight 各一份），崩溃摘要带镜像 UUID、崩溃线程 32 帧，调用树超限时不再整棵丢。
  - **与 BUG-4013 的关系**（同日、同机型 iPhone18,3 的 iOS 同步闪退，4013 定位为进程虚拟地址空间耗尽，PR #2834）：
    - 4013 的修复**可能覆盖**本 bug 的 iOS 三份报告：rss 只有 1.0–1.4 GB 却在 Rust 与 Dart 堆各处分配失败，符合「地址空间满、物理内存未满」的特征；4013 去掉了重载期词典映射翻倍、media.bin 映射、逐 WebView 编译拦截规则，并开扩展虚拟地址空间 entitlement。本 bug 的报告里没有 VM 摘要，无法直接对照，需含 4013 修复的构建上再收 iOS 崩溃报告确认。
    - 4013 **不覆盖**：Android `7oF6GvM4Ii`（Scudo OOM，pss 约 3.3 GB，64 位进程，是物理内存耗尽）；假设 (a) 在 64 位上不变（4013 只给 32 位进程的次要连接关 mmap）；假设 (b)、(c) 未触及。本 bug 保持未修复，根因定位所需证据不变。
  - **2026-11-05 续报（Android，含 4013 修复之后）**：`Eg5thU2wox`，与 `7oF6GvM4Ii` 同一台 Xiaomi 23116PN5BC / Android 16，**3.3.0-debug.23853**（晚于 23591）。两次 Scudo / `mprotect ... Out of memory` SIGABRT（09:58、10:02，各在启动后约 4 分钟、前台），第二次 pss 1.9 GB / rss 2.0 GB，`memoryPressure=2x`。
    - 同一份日志里的历史段把这台机的进程内存曲线串起来了：23213 `stage=downloading` rss 1.1–1.4 GB → pss 3.3 GB；23261 `stage=start:plan heads=2` rss 3.45 GB（maxRss 3.6 GB），同轮 Dart 侧报 `SrsCoreException(-1): out of memory`（`SrsCore.sync2` ← `_coreSync2`，`srs_db_store.dart:5325`），即 Rust sync2 自己分配失败。
    - **23853 这两次崩溃没有 `srs_sync` / `srs_v1_migrate` 活动面包屑**，且 09:51 上一轮互联同步已因 `No reachable Fushi server address` 在 `srsDirectoryKeyOf` 前失败——崩溃当时 SRS 同步大概率没在跑。错误日志在这两个进程里没有任何记录（只有 popup WebView 的 `ResizeObserver` 噪声），内存涨到 1.9 GB 的来源**无证据**，不能直接归给 SRS 同步。
    - 推论：本 bug 在 Android 上不是 4013 覆盖的地址空间问题，且「只在同步中爆」的前提被这份报告削弱。证据缺口新增 ④：非活动期间也要有内存采样面包屑（周期 rss + 原生 core / 连接数 / WebView 数），否则此类前台 OOM 永远只剩 pss 一个数。
  - **证据缺口 ② / ④ 补上（取证，不是修复）**：会话标记滚动保留最近 6 次内存采样（每 30 s 一次 + 系统内存压力时一次，`fushi/lib/src/diagnostics/previous_exit_log.dart` `PreviousExitLog.startMemorySampling`），下次启动的 `Process.previousExitUnclean` 带 `memory=[HH:mm:ss rss=… max=… srs=开/存活 sess=… rd=… sqlite=当前/高水位MB; …]`。SRS 读数来自新导出 `ffsrs_store_diag_counts`（`native/fushi_fsrs/src/store/ffi.rs`）：句柄表里打开的库、还没释放的 `SrsCore`（存活 > 打开 = 退役的库还驻留，对应假设 (b)）、只读会话、只读连接池连接总数（假设 (a)）、内置 SQLite 堆用量与高水位。WebView 个数没有现成登记点，未纳入。下一份 ≥ 本 PR 构建的同机报告据此判 (a)/(b) 是否成立。
  - **2026-11-05 用户另交 issue**（同机，6 份 tombstone）：崩溃线程有 DartWorker、`1.raster`（Adreno Vulkan 驱动 calloc）、主线程（pthread shadow stack mprotect），都是内存见底时的受害者，不指向元凶；线程数稳定 94–95。新线索：同 profile 手机 App Data 15.6 GB（曾 26 GB），桌面 srs.db 2.68 GB，分项未知。为此加了启动后 20 s 的存储分项诊断（`fushi/lib/src/diagnostics/storage_footprint_log.dart`，`Storage.footprint`：App 数据根前两层 ≥50 MB 的目录与 ≥100 MB 的大文件），内存采样另带线程数与打开着的 srs.db / -wal 字节。issue 建议的「回退 Skia」违反 Impeller 硬规则、「分配失败不 abort」App 层做不到，均不采纳。
  - **2026-11-05 第一份带内存采样的报告**：`2sNhUbaEBO`（同一台 Xiaomi 23116PN5BC，3.3.0-debug.23862）。13:01:31 启动、全程前台，13:04:57 Scudo `internal map failure (Out of memory)` SIGABRT。用户补充：当时**停在 SRS 页面不动**。采样：
    - rss 1164 → 1491 → 1802 → 2255 → 2848 → 3036 MB（每 30 s，约 10 MB/s 线性涨）；
    - SRS 原生计数全程不变：`srs=1/1 sess=0 rd=3 sqlite=2/221MB db=2597MB wal=0MB`；
    - 13:01:51 那轮互联同步在 `srsDirectoryKeyOf` 就因 `No reachable Fushi server address` 失败，之后没有 `srs_sync` 面包屑。
    - 结论：假设 (b)（退役的库还驻留）**不成立**（只有 1 份 core）；假设 (a) 的「连接页缓存」部分**不成立**（SQLite 堆 2 MB、连接数不变）；同步没在跑。**但 `sqlite=` 只量 SQLite 页缓存**：连接开了 256 MB mmap，经 mmap 读的页不进页缓存，所以这个读数证明不了库在这 3 分钟里没被大块地读——涨的是谁仍无证据。
  - **证据缺口 ⑤ 补上（取证，不是修复）**：内存采样再加三样，下一份同机报告直接点名涨的是谁、谁在跑：
    - `anon= file= shm=`（`/proc/self/status` 的 RssAnon / RssFile / RssShmem，`processRssBreakdownProbe`）：file 涨 = srs.db 等文件映射页；
    - `malloc=`（bionic `mallinfo().uordblks`，`fushi/lib/src/diagnostics/native_heap_probe.dart`）：anon 涨而 malloc 不涨 = Dart 堆 / 图形映射，malloc 跟着涨 = Rust / SQLite / C++；
    - `srsops=[…] marks=[…] busy=[…]`（`packages/fushi_engine/lib/srs/srs_op_ledger.dart` `SrsOpLedger`）：每个采样窗口里 SRS 内核命令（`core:<op>`，含 RWKV 回放 / 日志尾）、srs.db 上每条 Drift 语句（`sql:<动词> <表>`，查询道与写那一路都记，带行数与读回字节）、`dart:load_stats` 整库统计装载的次数 / 用时 / 字节，正在跑超过 2 s 的操作，以及修订号 / 牌组列表 / 首页统计 / 冲突角标 provider 的重建次数。单次超过 3 s 或读回超过 32 MB 的操作另记诊断日志 `SrsOpLedger.heavy`。
  - **2026-11-05 第一份带 malloc 分项 + SRS 账本的报告**：`7ED7Jiky72`（同机 Xiaomi 23116PN5BC，3.3.0-debug.23868，即 #2916 合并点 `758bd5a`，账本已在包里）。15:06:07 启动、全程前台（`lastLifecycle=resumed`），15:11:02 Scudo `internal map failure (Out of memory)` SIGABRT（崩溃线程 AudioThread，受害者）。采样每 30 s：
    - malloc 955 → 1263 → 1535 → 1914 → 2399 → 2902 MB（约 10 MB/s 线性涨），anon 1169 → 2904 MB 同步涨，file 577 → 308 MB（内存压力下被回收）；
    - SRS 原生计数全程不变 `srs=1/1 sess=0 rd=3 sqlite=2/221MB`；**6 个窗口都没有 `srsops=` / `marks=` / `busy=` 段**——`takeSummary()` 只在窗口为空时返回 null，即这 3 分钟里没有任何 SRS 内核命令、srs.db 语句、整库统计装载，也没有修订号 / 牌组列表 / 首页统计 provider 重建；
    - 15:06:27 那轮互联同步照旧在 `resolveReachableFushiCandidate` 失败，之后无 `srs_sync` 面包屑。
  - **同日用户反馈 `6Eu_JmRboy`**（同机 23868）：「关闭 srs 模块后，在小说统计页面又崩溃了」。日志里另有 23862 的 pid 30757（13:51–14:58）：`srs=0/0` 全程（SRS 内核根本没开），maxRss 仍到 1725 MB、`memoryPressure=2x`。
  - **结论更新**：涨的是 **native malloc（anon 跟 malloc 同步，file 不涨）**，且**与 SRS 无关**——账本证明 SRS 在涨的窗口里零活动，关掉 SRS 模块照样涨照样崩。「SRS 页面不动」与「小说统计页不动」两个现场的共同点是**停在某个页面不操作、内存仍以约 10 MB/s 匀速上涨**，形态像「每帧泄漏」（120 Hz 下约 80 KB/帧）而不是某次大查询。早先 issue 里 6 份 tombstone 有一份死在 `1.raster` 的 Adreno Vulkan 驱动 `calloc`，与「渲染路径持续分配」一致，但**仍是推测**：Impeller Vulkan 后端 / 驱动、持续动画的 widget（加载指示器、图表、错峰入场）、或 Dart 侧 FFI 的 native 分配（sqlite3 native asset 堆、词典库等不在 `sqlite=` 读数里）都没排除。
  - 本 bug 标题里的「SRS 同步」已被证据否定（只剩 iOS 早期报告与 23261 那次 `SrsCore.sync2` OOM 发生在同步中，后者也可能是同一泄漏把内存吃满后 sync2 恰好是分配失败的那一个）。证据缺口 ⑥：采样里没有**当前路由**与**窗口内帧数**，无法确认「停在页面不动时是否仍在持续出帧」以及停在哪一页；下一步应补这两项，或在同机型上停在统计中心 / SRS 页用 `dumpsys meminfo` + `adb shell am dumpheap -n` 抓 native heap 分配栈。
