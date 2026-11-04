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
- **备注**：`n1i0ET11Ea` 日志里另外发现的 IPv6 回拼 bug 已经单独由 BUG-4070 修复。那个 bug 会让每轮同步失败，但不是内存耗尽的原因。
