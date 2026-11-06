## BUG-4004 · 复习同步 head 引用了位置上没有的段，读者待应用永久卡住
- **报告**：2026-11-03（用户：宿主 `sync2_pending` 永久卡 2582 条，iPhone 对设备 01a173ca 的 ack 停在 647565）
- **真实性**：✅ 真 bug（根因 `native/fushi_fsrs/src/store/sync2/transport.rs` `sync2_head_if_changed`：写 head 取的是当下切法 `cut_segments(...).filter(b <= upto)`，并在写出时 `DELETE FROM sync2_rewrites ... first <= seq` 清掉重传登记；`compact_segments` 在别的位置的发件里改切后，head 引用了从没传到本位置的合并段）
- **[x] ① 已修复** — 有重传未完（`first <= upto`）就不写 head，交回 `recut`；head 不再清重传登记，过期的重传登记（不再是切段起点）在发件 / 写 head 前清掉（`prune_stale_rewrites`）；作者每轮按读 head 时列到的本机目录自检（`sync2_audit_own`，FFI `outbox` 的 `present`），水位以下却不在位置上的本机段登记重传、同名补传（分支 `pr/srs-sync2-head-segment-gap`）
- **[x] ② 已加自动化测试** — `native/fushi_fsrs/src/store/sync2/tests_head_gap.rs`（两个位置交错：L1 确认后 L2 发件合并、合并段再切出一段落在 L1 水位内；去掉修复时第 1 轮即报「L1 head references segments that were never uploaded there」；作者自检补传）；`packages/fushi_engine/test/srs/sync2/srs_sync2_head_gap_test.dart`（真实 SrsDbStore + 内存位置整轮：删掉 head 引用的段，读者收不到，作者下一轮同名补传，读者收齐、待应用 0）
- **备注**：现场位置 `sync-data/fushi-data/fushi-srs/01a13df1-…/v3/devices/01a173ca-…/`：head 362–364（10-28/29 写）引用 `seg-000000647566-000000647731-dd56035d.bin` 与 `seg-000000647989-000000647989-b7ae4b4e.bin`，位置上没有任何文件覆盖这两段 seq；v2→v3 位置迁移（10-31，`srs_location_migration.dart`）逐字节照搬并核对、v2 旧目录已空，缺口在迁移之前就有。现场的具体触发路径（同一设备两轮并发 / 后端写入静默丢失）无法在本机核实；本修复让内核不论哪条路径都不写引用未上传段的 head，已有缺口由作者设备（01a173ca）装新版本上线一轮自检补传。作者不再上线时的读者侧可见化（缺段计时、head 里报告缺段）另做。

### 根因

读者只认 head 列出的段（设计 §6.1）。`sync2_head_if_changed` 在写 head 时按**当下**的切法列段，而切法会被任何一次
`sync2_outbox`（它先 `cut_segments` 再 `compact_segments`）改掉：

1. 位置 L1 发件、确认，水位 = X；
2. 写 L1 的 head 之前，另一个位置 L2 的发件跑了合并：几个已经传到 L1 的段与新段合成一组、按体积重新切，前一段
   `[a, m]`（`m <= X`）名字是新的，只在 `sync2_rewrites` 里登记了「L1 要重传」；
3. L1 写 head：列出 `[a, m]`，并把这条重传登记删掉 → L1 上从没有这个文件；
4. 合并换下来的旧小段按 `sync2_obsolete` 过两代 + 24h 从 L1 删掉 → 缺口没有任何文件能补。

### 修复

- 写 head 前清掉过期重传登记，若这个位置还有 `first <= upto` 的重传未完：不写，返回 `HeadWrite::Recut`（FFI `{"recut": true}`，
  Dart 一轮按 `kSrsSync2OutboxRecut` 结束），下一轮发件按当前切法补传后再写。
- 作者自检：`srsSync2Pull` 读 head 时记下各设备目录的文件名，一轮的第一批发件带 `present`；内核对水位以下、不在
  列表里的本机段登记重传。
