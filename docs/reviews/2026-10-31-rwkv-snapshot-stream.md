# RWKV 快照流式保存 / 恢复接入正式路径（2026-10-31）

起因：对照 kuma3-anki-app 的 RWKV 实现时确认 Fushi 的快照缓存是「Rust 先生成整份状态 → 复制进 Dart → 跨 isolate 传给主 isolate → 写文件」（恢复反向再来一遍），kuma3 是分块直接读写文件。前一轮实验分支（`snapshot-streaming` feature，未进 PR）实测 5 万卡时保存 / 恢复耗时降两到三成、测试进程峰值内存从约 529 MiB 降到约 155 MiB。用户拍板「你做一个吧，然后测试后准备 PR」，本轮把它接进正式路径。

## 改了什么

- **`native/fushi_rwkv`（ABI 3 → 4）**：新增 C ABI `frwkv_runtime_snapshot_to_file(runtime, path, path_len)` / `frwkv_runtime_restore_from_file(runtime, path, path_len)`，路径是无 NUL 结尾的 UTF-8 字节。
  - 编码侧：大 / 小模型都改成 `write_snapshot(&mut impl Write)`，字节 API `snapshot()` 退化成「写进 `Vec`」，文件 API 写进 256 KiB `BufWriter` + `flush` + `sync_all`。**同一份编码器出两种产物**，不再各维护一份；旧的整包编码器只在 `#[cfg(test)]` 下保留（`legacy_snapshot`），当「磁盘格式没变」的对拍基准。
  - 解码侧：新的 `SnapshotReader<R: Read>` 有界读取（每个 count 先按剩余字节数校验、末尾 `expect_end` 拒绝多余尾字节），scratch 缓冲最多装一条状态或一份 feature cache，**不把整个文件读进内存**。所有状态先解进局部变量，全部校验过了才一次性替换 `self.stores / self.features`——任何 I/O 或格式错误都不碰旧状态。字节 API `restore_snapshot()` 现在也是这条解码器套 `Cursor`，两条路径的拒绝判据一字不差。
  - `RwkvRuntime::restore_from_file` 成功后的收尾与 `restore(bytes)` 相同：解除 poisoned、清撤销日志、清分数表。`snapshot_to_file` 在 poisoned 时拒绝；写失败只可能留下半个文件，runtime 不变。
  - `tests/journal.rs` 里写死的 `assert_eq!(frwkv_abi_version(), 3)` 改为比 `ABI_VERSION` 常量（与 `tests/c_abi.rs` 同口径），以后升 ABI 不用再手改它。
- **`packages/fushi_rwkv`**：`RwkvNativeRuntime.snapshotToFile / restoreFromFile`（同步 FFI，只在后台 isolate 调）；`RwkvWorker.snapshotToFile / restoreFromFile`——**isolate 之间只传路径字符串**，不再搬 `TransferableTypedData`。`kFushiRwkvAbiVersion = 4`。
- **`packages/fushi_engine/lib/srs/srs_rwkv_service.dart`**：`SrsRwkvBackend` 接口加这两个方法；`_saveSnapshot` 改为让 worker 直接写 `.tmp`，Dart 只负责成功后 `rename` + 写元数据（临时文件 / 提升协议不变）；`_restoreSnapshot` 改为 `restoreFromFile(path)`。顺手修了 `close()`：以前关闭时最后一次存快照抛异常会跳过 `_status.close()`，状态流控制器泄漏；现在外层 `try/finally` 保证一定关。
- **兼容性**：快照文件名、字节格式、`.json` 元数据全部不变，用户现有 `rwkv-<profile>-small-int4.snap` 缓存直接命中，不需要迁移。测试里专门交叉验过「旧字节 API 存的文件用新文件 API 恢复」和「新文件 API 存的文件用旧字节 API 恢复」。

## 验证

全部在本 worktree（`origin/develop@061dab784b` + 本分支）上跑，Flutter 3.47.6、Rust 1.93.0、Windows x64。

- **Rust**：`cargo test --release --locked -- --nocapture`（与 `native-rwkv-gate.yml` 同命令）全绿：lib 单测 8（含新增 `snapshot_tests` 4 条）、`c_abi` 4、`forecast` 3、`journal` 7、`long_history` 2、`parity` 7、`small_model` 4。第一次跑 `journal::c_abi_round_trip` 红在写死的 ABI 3，改成比常量后绿。新增的 4 条覆盖：
  - 大 / 小模型 × 全部精度（小模型 f32 / int8 / int4，大模型 f32 / int8）：流式文件与旧整包编码器逐字节相同；恢复后 `query` 逐位相同；恢复后继续 `replay` 与从没停过逐位相同。
  - 13 种坏文件（6 个截断点、多一个尾字节、坏 magic、错精度、count 溢出、重复 id、NaN / 翻位的状态、坏 slot 长度、小模型错权重指纹）、不存在的路径、目录：文件 API 与字节 API 都拒绝，且状态 / poisoned 标记 / 撤销日志 / 分数表逐项不变。
  - 注入式读失败（读到一半、读到最后一字节再失败）：两种模型都不提交半解析的状态。
  - C ABI：中文路径往返；空 runtime / 空路径 / 非法 UTF-8 返回错误码而不崩，状态不变。
- **符号面**：`native/fushi_rwkv/verify_abi.sh` 对本机编出的 DLL：26 个 `frwkv_*` 全部导出（期望集自动取自 Rust `extern "C"` 与 Dart 字面量的并集，新增两个符号两侧都在）。
- **clippy**（`cargo clippy --release --locked --all-targets`）：退出 0，16 条 warning 全在存量的上游数值内核与旧测试里，本次新增 hunk 零 warning。
- **Dart，真库真权重**：`packages/fushi_rwkv` 下 `dart ../../fushi/tool/heavy.dart --here -- flutter test test/fushi_rwkv_test.dart --no-pub` → **8 passed，exit 0**。新增用例（小 / 大模型各一）：原生流式文件 == 字节快照；worker 用字节 API 恢复文件、用文件 API 恢复旧字节、后台保存再由前台恢复，三种交叉全部预测逐位相同；不存在的路径、截断、多尾字节、含 NUL 的路径在原生与 worker 两层都抛 `RwkvNativeException` 且状态不变；dispose / close 之后调用抛 `StateError`。
- **Dart，服务层**：`packages/fushi_engine` 下 `flutter test test/srs/srs_rwkv_service_test.dart --no-pub` → **28 passed，exit 0**。新增两条：
  - 流式保存失败（注入 `FileSystemException`）：旧快照与旧元数据原样保留、`.tmp` 留下半个文件、backend 照常关闭、`statusChanges` 照常关闭；下一次启动从旧快照恢复不重建，`refresh()` 对齐时把没存进去的那条作答按日志尾巴追加。
  - 快照文件被改坏：拒绝后从日志全量重建，并重新写出可恢复的快照。
  - 既有「快照命中」用例加了断言：保存走 `.tmp` 路径、恢复走正式路径且文件存在。
- **推送门**：`fushi/` 下全量 `flutter analyze --no-pub`，见本分支 PR 描述。

## 基准（正式 DLL）

同一 harness、同参数复测前一轮实验：Windows x64 / i5-12450H、4 线程、SM56 int8 权重 + int4 状态、合成库（每卡 2 条复习、2 卡 / 笔记、20 牌组、5 预设）、每组每路径 7 次独立 AOT 子进程、交替 AB/BA、热文件缓存。「原」= 现有整包经 Dart 的路径，「流式」= 本 PR 的 worker 直写 / 直读。DLL SHA-256 `c0aa2e09…bef096d`。**测量期间本机另有多个 agent 在跑，5 万卡的原路径 p95 明显比前一轮实验抖；各组的最小值与前一轮实验一致（5 万卡保存 410 → 288 ms、恢复 299 → 199 ms）。**

| 卡数 | 快照大小 | 保存 p50：原 → 流式 | 恢复 p50：原 → 流式 |
|---|---:|---:|---:|
| 1,000 | 2.92 MiB | 20.5 → 15.0 ms（−27%） | 7.9 → 4.9 ms（−38%） |
| 10,000 | 25.44 MiB | 152.2 → 99.8 ms（−34%） | 63.2 → 42.1 ms（−33%） |
| 50,000 | 125.52 MiB | 585.8 → 379.9 ms（−35%） | 489.6 → 359.3 ms（−27%） |

| 卡数 | 保存 p95：原 → 流式 | 恢复 p95：原 → 流式 |
|---|---:|---:|
| 1,000 | 23.4 → 18.6 ms | 8.3 → 5.1 ms |
| 10,000 | 163.8 → 115.0 ms | 64.4 → 45.0 ms |
| 50,000 | 786.6 → 431.5 ms | 694.1 → 440.0 ms |

测试进程采样峰值工作集中位数（含模型、runtime、Dart VM，不是整个 app）：

| 卡数 | 保存峰值：原 → 流式 | 恢复峰值：原 → 流式 |
|---|---:|---:|
| 1,000 | 30.4 → 21.9 MiB | 29.9 → 20.9 MiB |
| 10,000 | 122.5 → 46.8 MiB | 122.5 → 47.1 MiB |
| 50,000 | 528.4 → 154.7 MiB | 536.6 → 160.5 MiB |

5 万卡时相对 ready 的工作集增量中位数：保存 376.1 → 2.4 MiB，恢复 519.2 → 143.2 MiB（恢复后的常驻状态本来就要占这么多，不能全算临时内存）。

正确性对照（harness 内）：3 个规模的流式文件与字节快照逐字节相同；恢复后全部卡的原生预测分数逐位相同；截断文件恢复失败后旧 runtime 的快照 hash 不变。原始逐次数据在本地 `.codex-test/rwkv-snapshot-stream/full.json`（不入库）。

## 边界

- 这是无损全量快照的 I/O 改法，**不是增量快照**，不改模型计算、卡片记忆、排序或分数表；平常出下一张卡的速度没有变化。收益集中在启动恢复缓存、空闲 / 关闭时后台保存的耗时与瞬时内存。
- 恢复仍要把最终常驻状态全部分配出来；保存仍为每个 stream 建一份按 id 排序的索引，所以不是严格恒定的额外内存。
- 只在 Windows 测了；绝对毫秒不能套到手机，Android 上的收益未测。
- worker 侧是同步文件 I/O，但它本来就在后台 isolate，不碰 UI isolate。

## 与 PR #2711 的碰撞

[#2711](https://github.com/hajisensai/Fushi/pull/2711)（历史检查点）同样把 `ABI_VERSION` / `kFushiRwkvAbiVersion` 从 3 升到 4、新增 `frwkv_runtime_rewind_from`，但它的快照仍是整包经 Dart。两个分支的 ABI 号撞了、符号集不同。**后合入的那个要把两处版本号再 +1（5），保留两边新增的符号、绑定与测试**；预期文本冲突在 `native/fushi_rwkv/src/lib.rs`（ABI 历史注释）、`README.md`（符号表）、`tests/journal.rs`、`packages/fushi_rwkv/lib/src/{fushi_rwkv_library,rwkv_native,rwkv_worker}.dart`、`packages/fushi_engine/lib/srs/srs_rwkv_service.dart` 与它的测试。本分支的 `journal.rs` 已改成比常量，合并后只需改常量本身。

## 复现

```powershell
# Rust 门（同 CI）
cd native/fushi_rwkv; cargo test --release --locked -- --nocapture
# 本机 DLL + 符号面
powershell -ExecutionPolicy Bypass -File native/fushi_rwkv/build_windows_dll.ps1
bash native/fushi_rwkv/verify_abi.sh native/fushi_rwkv/prebuilt/windows-x64/fushi_rwkv.dll
# Dart 定向
cd packages/fushi_rwkv; dart ../../fushi/tool/heavy.dart --here -- flutter test test/fushi_rwkv_test.dart --no-pub
cd packages/fushi_engine; dart ../../fushi/tool/heavy.dart --here -- flutter test test/srs/srs_rwkv_service_test.dart --no-pub
```
