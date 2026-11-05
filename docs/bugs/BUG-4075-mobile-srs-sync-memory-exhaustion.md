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
