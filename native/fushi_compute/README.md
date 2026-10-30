# fushi_compute

Fushi 的 Rust 计算内核：CPU 密集操作（哈希 / 图像 / 文本匹配 / 信号处理）的薄 C ABI，给 Dart FFI
（`packages/fushi_compute/`，纯 Dart，无 Flutter / 插件依赖）用。五个平台 app、
`packages/fushi_engine` 与无头服务端都调这一份 Rust。

**硬依赖，没有 Dart 回退**（所有者 2026-10-18 拍板「不维护两份实现，直接用 Rust」）：

- 五个平台 app 与无头服务端的构建都必须产出并随包本库，缺产物**构建失败**（CMake /
  Gradle / Xcode 构建阶段都会报出要先跑哪个脚本），不是静默跳过；
- Dart 侧加载失败抛 `FushiComputeUnavailableError`（逐个候选路径的失败原因：不存在 / 打不开 /
  ABI 不符 / 缺公共符号），某个域的符号缺失（库比绑定旧）同样抛；不返回 null；
- 从 Dart 迁过来的内核，删 Dart 实现之前先用旧实现冻结「确定性输入 → 输出」向量做回归测试。

## ABI 约定

见 `src/lib.rs` 文件头：符号 `ffc_<域>_<动作>`、原始缓冲区不走 JSON、`i32` 状态码
（0 成功，负数失败，panic 由 `guard` 接住转成 -100）、Rust 分配的缓冲区用 `ffc_free_bytes`
释放、新增符号不升 ABI 版本。

| 符号 | 作用 |
|---|---|
| `ffc_abi_version() -> i32` | ABI 版本（当前 1）；Dart 侧不一致即抛加载异常 |
| `ffc_free_bytes(u8*, usize)` | 释放本库分配并交给调用方的缓冲区 |
| `ffc_hash_ed2k_new() -> ctx*` | 新建 AniDB ED2K 上下文（panic 时 NULL） |
| `ffc_hash_ed2k_update(ctx*, const u8*, usize) -> i32` | 追加字节 |
| `ffc_hash_ed2k_finish(ctx*, u8 out[32], i32* has_alt) -> i32` | `out[0..16]` 红变体；`*has_alt=1` 时 `out[16..32]` 为蓝变体（长度恰为 9728000 的非零整数倍） |
| `ffc_hash_ed2k_free(ctx*)` | 释放（NULL 无操作） |
| `ffc_hash_sha256_new / _update / _finish(ctx*, u8 out[32]) / _free` | SHA-256，同上形态 |
| `ffc_hash_crc32(u32 crc, const u8*, usize) -> u32` | CRC-32（zip / IEEE），在上一段结果上续算，首段传 0 |
| `ffc_hash_uuid_v5_batch(const u8* ns[16n], const u8* names, const u64* offsets[n+1], usize n, u8* out[16n]) -> i32` | 批量 RFC 9562 UUIDv5（SHA-1）；名字是打包的 UTF-8（第 i 个 = `names[offsets[i]..offsets[i+1]]`） |
| `ffc_hash_hash53_batch(const u8* data, const u64* offsets[n+1], usize n, u64* out[n]) -> i32` | 批量 53 位确定性正整数（SHA-256 前 7 字节大端取低 53 位，0 记作 1） |
| `ffc_hash_pow_solve(const u8* prefix, usize, u32 bits, u64* out_nonce) -> i32` | 工作量证明：最小的十进制 nonce 使 SHA-256(prefix ‖ nonce) 至少 `bits` 个前导零位（`bits ≤ 64`） |
| `ffc_hash_pow_check(const u8* prefix, usize, const u8* nonce, usize, u32 bits) -> i32` | 校验：1 满足 / 0 不满足 / 负数参数错 |
| `ffc_hash_bytes_equal(const u8*, usize, const u8*, usize) -> i32` | 两段字节是否相同：1 / 0 / 负数 |

`finish` 之后再 `update` / `finish` 返回 -2（INVALID_ARGUMENT）。Dart 侧 lookup 名都写成字符串
字面量，`verify_abi.sh` 递归抓 `packages/fushi_compute/lib/` 下所有 `'ffc_*'` 作期望符号集，
新增域自动跟上。

## 哈希域

| 调用方 | 之前（纯 Dart） | 现在 |
|---|---|---|
| `packages/fushi_engine/lib/media/video/metadata/anidb_ed2k.dart`（AniDB 整文件 ED2K，worker isolate） | `_Md4` + `AnidbEd2kAccumulator`，64 KiB `readInto` | `FfcEd2kHasher`：1 MiB 异步 `readInto` 直接读进原生缓冲区；取消 / 进度 / 「读的过程中文件被改」判定不变 |
| `fushi/lib/src/media/video/video_source_fingerprint.dart`（制卡来源视频整文件 SHA-256，`Isolate.run`） | `sha256.bind(file.openRead())`（`package:crypto`） | `ffcSha256FileSync`（1 MiB 同步读） |

Rust 侧用 RustCrypto 的 `md4` / `sha2` 0.10（MIT OR Apache-2.0；`sha2` 运行时检测 SHA-NI /
ARMv8 SHA 扩展）。回归向量：`packages/fushi_compute/test/ffi_hash_test.dart`，由删除前的 Dart
实现对确定性输入生成（空、1、63/64/65、1000、块大小 -1 / 恰好 / +1、两块、两块 + 12345、三块）。

基准（`packages/fushi_engine/benchmark/file_hash_benchmark.dart`；现场生成伪随机文件、预热页缓存、
3 次取中位数；2026-10-18，i5-12600KF / Windows 11，Dart 3.13.5）：

| 文件 | 路径 | 改动前（Dart） | 改动后（Rust） | 倍数 |
|---|---|---|---|---|
| 1 GiB | ED2K，AOT（`dart compile exe`） | 20,955 ms（49 MiB/s，3 次 17.4 / 21.0 / 69.9 s） | 2,294 ms（446 MiB/s） | ≈ 9× |
| 1 GiB | ED2K，JIT（`dart run`） | 12,593 ms（81 MiB/s） | 2,304 ms（444 MiB/s） | 5.5× |
| 1 GiB | SHA-256，AOT | 17,716 ms（58 MiB/s） | 955 ms（1,072 MiB/s） | 18.5× |
| 1 GiB | SHA-256，JIT | 19,447 ms（53 MiB/s） | 3,803 ms（269 MiB/s） | 5.1× |
| 256 MiB | SHA-256，AOT | 4,508 ms | 213 ms | 21× |
| 256 MiB | ED2K，AOT | — | 544 ms（471 MiB/s） | — |

（ED2K 的 Dart 基线只在删除前测过；SHA-256 的 `package:crypto` 对照仍在基准里跑。）

### 其余 CRC-32 / zip 写出 / 备份媒体池

| 调用点 | 改动 |
|---|---|
| `fushi_engine/lib/utils/archive/native_zip.dart` 的 `nativeDeflatedArchiveFile` / `addFileNativeDeflate` | `ffcCrc32`（后者 4 MiB 读块链式） |
| 新增 `addFileStored`（native_zip）：分块读 + `ffcCrc32` 增量 CRC、真流式写 STORE 条目 | `fushi/lib/src/sync/backup_service.dart` 与 `fushi_engine/lib/sync/sync_asset_package_service.dart` 原来的 `ZipFileEncoder.addFile(..., STORE)`（archive 包内部纯 Dart CRC）改走它；现有恢复路径读回测试 `fushi/test/sync/store_zip_native_crc_roundtrip_test.dart` |
| 备份 meta 条目 | `ArchiveFile(meta)` → `nativeDeflatedArchiveFile`（原生 deflate + Rust CRC） |
| `fushi_engine/lib/srs/srs_backup_store.dart` `_deflateFile` | 逐块 `ffcCrc32` + `FfcSha256Hasher`；回归 `packages/fushi_engine/test/srs/srs_backup_zip_crc_test.dart` |
| 同文件媒体池入池 / 恢复时的 `sha256.bind(f.openRead())`（两处） | `ffcSha256File`；`srs_backup_restore_test.dart` 用 `package:crypto` 对拍池文件名 |
| `fushi_engine/lib/media/video/bluray/aacs_configuration.dart` KEYDB.cfg 校验 | `ffcCrc32` |

基准（`packages/fushi_engine/benchmark/zip_crc_callsites_benchmark.dart`，AOT，3 次中位数）：

| 调用点 | 输入 | 改动前 | 改动后 |
|---|---|---|---|
| `nativeDeflatedArchiveFile` CRC | 64 MiB | 485 ms | 9 ms |
| `addFileNativeDeflate` 链式 CRC | 4 MiB × 64 | 2,197 ms | 47 ms |
| 备份 / 音频同步包 STORE 写出（端到端，含读写盘） | 4 × 128 MiB | 6,188 ms | 1,899 ms |
| 备份 meta 条目（小对象） | 32 KB JSON × 200 | 219 ms | 238 ms（3 次 148 / 238 / 262，与旧值在噪声内持平） |
| 复习备份 `_deflateFile`（端到端） | 64 MiB JSONL | 2,471 ms | 969 ms |
| AACS KEYDB.cfg CRC | 16 MiB × 1 / 256 KiB × 64 | 89 / 113 ms | 2 / 1 ms |

### SRS 确定性 ID、同步摘要与安装工作量证明

- `packages/fushi_srs/lib/src/ids.dart`：`uuidV5`（SHA-1）与 `hash53`（SHA-256）只剩 Rust 一份算法；
  Dart 只做 UUID 解析 / 格式化。单个调用走不分配的 `ffcUuidV5` / `ffcHash53`（`ffc_hash_*_batch`
  的 n = 1）；批量入口 `uuidV5Batch` / `SrsIds.importedRevlogs`（apkg 导入时整张卡的 revlog id，
  `srs_apkg_import.dart`）一次 FFI 调用；`hash53Batch` / `SrsIds.ankiNumericIds`（`srs_db_store.dart`
  重建数字索引）走 `ffcHash53Batch`，整批一次 FFI、循环在 Rust：字符串直接编码进一块原生内存
  （ASCII 项逐码元写入，不先攒整批 Dart 字节数组；`anki-id/` 前缀打包时拼入，不为每个 id 拼串）。
  原先逐个走 `ffcHash53`（HBK-AUDIT-008）；`hash53_batch_benchmark.dart` AOT 10 万个 id 端到端
  （含编码 / 打包 / 拷回）24.7 → 11–13 ms。`fushi_srs` 因此依赖 `fushi_compute`（纯 Dart FFI，不违反「不依赖
  Flutter / 插件 / 数据库」）；`style_dedup.dart` 的 css SHA-1（小数据）仍用 `package:crypto`。
- `fushi_srs/lib/src/sync/sync_files.dart` 批文件 body 摘要、`fushi_engine/lib/srs/srs_backup_store.dart`
  events body 摘要：`ffcSha256Bytes`。
- `fushi_engine/lib/leaderboard/install_identity.dart`：`solveInstallPow` 一次 FFI 调用解完
  （`ffc_hash_pow_solve`），`installPowValid` 走 `ffc_hash_pow_check`；删掉 Dart 的逐 nonce 循环与
  `_leadingZeroBits`。冻结向量（删除前 Dart 求出）在 `install_identity_test.dart`。

基准（`packages/fushi_engine/benchmark/srs_ids_pow_benchmark.dart`；旧实现在删除前同一进程对比；
AOT，中位数；本机同时跑着别的构建，绝对值有波动，比值可参考）：

| 调用点 | 规模 | 改动前（Dart） | 改动后（Rust） |
|---|---|---|---|
| `uuidV5` 单个（`SrsIds.importedRevlog` 等全部单点） | 10 万次 | 600 ms | 386 ms（同轮另一次 996 → 651 ms） |
| `uuidV5` 批量（`SrsIds.importedRevlogs`，apkg 导入） | 10 万个 | 600 ms | 218 ms（996 → 344 ms） |
| `hash53` 单个（`SrsIds.ankiNumericId`） | 10 万次 | 287 ms | 73 ms（392 → 66 ms） |
| `hash53` 批量（`SrsIds.ankiNumericIds`，重建索引） | 10 万个 | 287 ms | 132 ms（392 → 137 ms）；改整批一次 FFI 后见上文 |
| 安装 PoW 18 位（`solveInstallPow`） | `test-install`（nonce 97403） | 333 ms | 9 ms |
| | 32 位 hex id（nonce 615991） | 3,120 ms | 87 ms |
| SHA-256 body（同步批文件 / 备份 events） | 4 KiB × 16384 | 2,002 ms | 135 ms |
| | 1 MiB × 64 | 1,972 ms | 66 ms |
| | 16 MiB × 4 | 1,545 ms | 61 ms |

### CRC-32 与其它大文件 SHA-256

`ffc_hash_crc32(u32 crc, const u8*, usize) -> u32`（`crc32fast`，MIT OR Apache-2.0）：与 `package:archive`
的 `getCrc32(data, crc)` 同语义、可链式。Dart `ffcCrc32` 按 1 MiB 一段拷进原生暂存区（FFI 不能借用
Dart 堆数组；`.address` 只对 `@Native` 叶子函数可用，而本库走 `DynamicLibrary`）。

| 调用点 | 改动 |
|---|---|
| `fushi_engine/lib/epub/epub_parser.dart` 三处 `ZipDecoder().decodeBytes(bytes, verify: true)` | `_decodeVerified`：`verify: false` 解码后逐条解压并 `ffcCrc32` 核对，不符抛同一个 `ArchiveException('Invalid CRC for file in archive.')`，核对完才落盘 |
| `fushi_engine/lib/media/manga/manga_archive_importer.dart` 两处 `getCrc32(content)` | `ffcCrc32(content)` |
| `fushi_audio/lib/src/matching/epub_builder.dart` 手写逐字节 `_crc32` | 删除，改 `ffcCrc32` |
| SHA-256 整文件重读：`manga_panel_model_service` / `panel_model_manifest`（漫画分格模型）、`bluray_java_runtime`（JRE 包）、`migration_manifest`（迁移文件，isolate 里同步读）、`recommended_pack`（推荐词典包）、`font_sync`（字体）、`update_checker_download`（更新安装包）、`segmented_downloader` 整包校验（注释里的 9.5 GB 场景） | `ffcSha256File` / `ffcSha256FileSync` |
| `asr_host/gpu_runtime_pack.dart` 解压成员时边写边算 | `FfcSha256Hasher` |

不动的：小数据（字符串键、PKCE、签名、字幕 / NFO / 封面这类小文件）；下载过程中边收边算的
（`segmented_downloader` 分片摘要，瓶颈是网络）；Anki 媒体去重（BUG-1491 实测瓶颈是 HTTP）；
galgame helper / hook 相关（Windows 专属规则域，另开任务）。

基准（`packages/fushi_engine/benchmark/crc32_sha256_benchmark.dart`，AOT，同一台机器，3 次中位数）：

| 调用点 | 输入 | 改动前（Dart） | 改动后（Rust） | 倍数 |
|---|---|---|---|---|
| epub_parser `decodeBytes(verify: true)` + 取全部内容 | 合成 EPUB 43.3 MB（200 个 deflate XHTML ≈ 40 MiB 文本 + 40 张 1 MiB 图） | 752 ms | 234 ms | 3.2× |
| manga_archive_importer `getCrc32` | 200 页 × 2 MiB | 2,788 ms | 80 ms | 35× |
| epub_builder `_crc32` | 同上 400 MiB | 3,470 ms | 80 ms | 43× |
| 内存 SHA-256 | 64 MiB | 1,173 ms | 43 ms | 27× |
| 整文件 SHA-256（异步读，UI isolate 可用） | 256 MiB | 4,829 ms | 408 ms | 11.8× |

## 字体域

`ffc_font_woff2_to_sfnt(const u8*, usize, u8** out, usize* out_len) -> i32`：WOFF2 → 裸 sfnt
（Brotli 解压 + 逆转 glyf / loca / hmtx 变换 + 按标签排序重组、4 字节对齐、重算
`head.checkSumAdjustment`）。成功时输出由本库分配，`ffc_free_bytes` 释放；不是可解码的 WOFF2
（含字体集合 `ttcf`）返回 -3（BAD_INPUT），Dart 侧 `FushiFont.woff2ToSfnt` 映射成 null。表校验和见下面「表校验和」。

| 调用方 | 之前（纯 Dart） | 现在 |
|---|---|---|
| `fushi/lib/src/models/app_font_loader.dart`（App UI 自定义字体，`Isolate.run`） | `Woff2Decoder.toSfnt`（`package:brotli` + 手写 glyf 重建） | `FushiFont.instance.woff2ToSfnt` |
| `fushi/lib/src/reader/font_vertical_baseline_flag.dart`（阅读器字体请求，BUG-3420 缓存的后台 isolate） | 同上 | 同上 |

`fushi/lib/src/models/woff2_decoder.dart` 与 `package:brotli` 依赖已删除。Brotli 用
`brotli-decompressor`（Dropbox，BSD-3-Clause / MIT，纯 Rust）。

**逐字节一致**：删除前用 Dart 实现给 10 份字体生成 sfnt SHA-256（`packages/fushi_compute/test/font/woff2_vectors.json`）。
4 份小字体入库（Roboto 两种变换、Noto Serif JP 可变字体子集 + hmtx 变换、Noto Sans JP CFF 子集，共 ≈ 90 KB）；
6 份 5–9 MB 的 CJK 语料不入库（Windows 11 系统字体经 fontTools 4.65 `woff2.compress` 生成），设
`FUSHI_WOFF2_CORPUS` 指向语料目录时额外比对。唯一有意的差异：glyf 变换头 `optionFlags` 第 0 位
（overlapSimpleBitmap）——Dart 版把它误读成多一个 u32 长度、整条流错位解不出；Rust 按规范读位图并给
对应字形首个 flag 置 `OVERLAP_SIMPLE`。语料与入库样本都不带这一位。

基准（AOT `dart compile exe`，同一进程先 Dart 后 Rust，7 次取中位数；Rust 含拷入原生内存、拷出与释放；
2026-10-18，i5-12600KF / Windows 11，本机同时有 3 个其它重任务在跑，绝对值偏高）：

| 字体（WOFF2 → sfnt） | Dart 合计 | 其中 Brotli | 其中 glyf 重建 | Rust | 倍数 |
|---|---|---|---|---|---|
| Noto Sans SC VF（7.4 → 17.0 MB） | 1,102 ms | 349 ms | 742 ms | 327 ms | 3.4× |
| Yu Mincho（5.0 → 12.5 MB） | 1,536 ms | 294 ms | 1,174 ms | 269 ms | 5.7× |
| SimSun-ExtB，hmtx 变换（8.6 → 20.9 MB） | 2,083 ms | 350 ms | 1,671 ms | 412 ms | 5.1× |
| Microsoft YaHei（8.4 → 18.7 MB） | 1,829 ms | 659 ms | 897 ms | 565 ms | 3.2× |
| Noto Serif JP VF，hmtx 变换（5.7 → 13.0 MB） | 2,058 ms | 726 ms | 1,444 ms | 582 ms | 3.5× |
| Noto Sans JP（CFF，3.2 → 4.3 MB，只有 Brotli） | 354 ms | 325 ms | — | 180 ms | 2.0× |

glyf 重建是 Dart 的大头（Rust 里只剩几十毫秒）；Brotli 本身只快约 2×（`brotli-decompressor` 比 C 版
libbrotli 慢约 1.5×），所以只走 Brotli 的 CFF 字体收益最小。

### 表校验和

`ffc_font_table_checksum(const u8*, usize, i32 head_table, u32* out) -> i32`：OpenType 表校验和（大端 u32
回绕求和，尾部补零；`head_table != 0` 时偏移 8 的 `checkSumAdjustment` 按 0 算）。Dart 侧
`FushiFont.tableChecksum(data, offset:, length:, headTable:)`，按区间拷进原生内存再算（`isLeaf`）。

| 调用方 | 之前（纯 Dart） | 现在 |
|---|---|---|
| `fushi/lib/src/reader/font_vertical_baseline_flag.dart`（清竖排基线位后重算 head 表与整字体校验和，sfnt / TTC / WOFF） | `_tableChecksum`：逐字节拼大端字 | `FushiFont.instance.tableChecksum` |
| `fushi/lib/src/models/font_decoder.dart`（WOFF 1.0 → sfnt 的 `checkSumAdjustment`） | `_checksum`：`ByteData.getUint32` | 同上 |

两个 Dart 版都已删除。回归向量（`packages/fushi_compute/test/font/fushi_font_test.dart` 的 `tableChecksum` 组）由删除前的
`_tableChecksum` 对确定性输入生成，覆盖补零尾字与「偏移 8 恰是补零尾字」；`FontDecoder._checksum` 只丢弃不足 4 字节的尾部，
而它的输入总是 4 字节对齐，所以和补零语义等价（基准里对 8 份字体逐个核对三者相等）。

基准（整字体一次求和，AOT，9 次取中位数，新实现含 malloc + 拷入；同上机器、同样有别的重任务在跑）：

| 字体（sfnt） | 旧 `_tableChecksum` | 旧 `_checksum`（ByteData） | Rust | 倍数（对两者） |
|---|---|---|---|---|
| SimSun-ExtB（20.9 MB） | 54.2 ms | 17.0 ms | 9.2 ms | 5.9× / 1.8× |
| Noto Sans SC VF（17.0 MB） | 56.0 ms | 15.5 ms | 8.2 ms | 6.9× / 1.9× |
| Yu Mincho（12.5 MB） | 38.1 ms | 12.8 ms | 6.5 ms | 5.9× / 2.0× |
| Microsoft YaHei 第 0 个（18.7 MB） | 50.1 ms | 14.5 ms | 8.6 ms | 5.8× / 1.7× |
| Noto Serif JP VF（13.0 MB） | 42.0 ms | 18.4 ms | 11.3 ms | 3.7× / 1.6× |
| Noto Sans JP（CFF，4.3 MB） | 11.3 ms | 3.4 ms | 1.8 ms | 6.3× / 1.9× |

Rust 这边的时间大半是把 Dart 堆上的字节拷进原生内存（`DynamicLibrary` 绑定拿不到 Dart 数组的地址）。

## 信号域

`src/signal.rs`，Dart 绑定 `packages/fushi_compute/lib/src/signal/ffc_signal.dart`。每个导出函数一次处理一整批
（整条包络 / 整段 PCM），不逐元素跨 FFI。

有声书转录 cue 的能量吸附 / 修边 / 句内碎片合并 / 跟读显示余量（原 `ffc_signal_cue_*` 与 fushi_audio
的 `CueEnergySnapper` / `CueFragmentMerger` / `CueDisplayMargins`）已迁到上游
[hajisensai/fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) 的 `native/asr_cue_post`：
`Cargo.toml` 把 crate `fushi_asr_cue_post` 当 git 依赖编进本库（rev 与 pubspec 七处 ref 同一个 sha），
`fcp_*` 随本库导出（清单 `packages/fushi_compute/lib/src/linked_crates.dart`，`verify_abi.sh` 一起核对），
Dart 绑定是上游 `fushi_asr_subtitles` 的 `AsrCuePostProcessor`，接线在
`packages/fushi_engine/lib/media/audiobook/asr_cue_post_host.dart`。回归向量与测试在上游。

| 符号 | 调用方（之前的纯 Dart 实现已删） |
|---|---|
| `ffc_signal_xcorr_best_shift(audio, n, cue, m, bin_ms, max_shift_ms, *has_data, *shift_bins, *confidence)` | fushi `subtitle_auto_align.dart` `bestOffsetMsByCrossCorrelation`（字幕自动对轴，视频页 UI isolate 同步调） |
| `ffc_signal_pcm_rms_db(pcm, len, rate, channels, bits, is_float, window_ms, silence_db, out, cap, *out_len)` | fushi `galgame_waveform.dart` `pcmToEnergyEnvelope`（galgame 制卡波形弹窗 `initState`；纯计算，与 hook / helper 无关） |
| `ffc_signal_parse_rms_log(utf8, len, silence_db, **out, *out_len)` | fushi `audio_energy_probe.dart`：`file=` 写出的逐帧 RMS 文件直接按字节解析（原来 `readAsStringSync` + `RegExp.allMatches`），stderr 兜底走同一函数 |
| `ffc_signal_db_to_amplitude(db, out, n)` + `ffc_signal_downsample_peaks(amp, n, buckets, percentile, out, cap, *out_len)` | `downsampleEnergyEnvelope` 与 `FfcEnergyEnvelope`：字幕对轴波形面板 / galgame 波形弹窗缓存线性振幅，改宽度只重跑降采样，不再每次重算 6 万次 `pow` |

一致性：回归向量 `packages/fushi_compute/test/fixtures/signal_vectors.json` 由删除前的 Dart 实现生成
（`test/signal/signal_vector_inputs.dart` 造输入）。互相关、日志解析（含 JS 正则 `\s` 的 Unicode 空白、
`-inf` / 超长数字 / 非法 UTF-8）是整数与四则运算，**逐位一致**；`num.clamp` / `List<double>.sort`
的 NaN 与 −0.0 语义在 Rust 里照抄。逐窗 RMS 用 `sqrt` / `log`、降采样用 `pow`，走 libm：`log` 实测逐位一致，
`pow` 不是——Dart VM 链的 CRT 与 Rust 调到的 `ucrtbase` 不是同一份（60000 个 dB 值里 dart.exe 有 11 个、
flutter_tester 有 94 个差 1 ULP，旧实现自己在两个宿主上也不一致），所以这两类按 ULP 容差（≤ 64）比，
冻结向量里实测最大偏差 5 ULP（归一化后的 0..1 波形桶，约 1e-15）。

基准（`packages/fushi_audio/benchmark/signal_benchmark.dart`，AOT，旧 Dart 实现原样复制在文件里对拍，
5 次中位数；2026-10-18，i5-12600KF / Windows 11，Dart 3.13.5）：

| 调用点 | 输入 | 改动前（Dart） | 改动后（Rust） | 倍数 |
|---|---|---|---|---|
| 字幕自动对轴互相关 | 20 分钟 @100 ms = 12000 格，±15 s（301 个 shift） | 13.5 ms | 5.6 ms | 2.4× |
| galgame 波形逐窗 RMS | 10 s 48 kHz 立体声 float32 | 7.6 ms | 2.1 ms | 3.6× |
| 同上 | 30 s | 24.3 ms | 7.2 ms | 3.4× |
| ffmpeg 逐帧 RMS 日志解析 | 60000 帧（5.1 MB） | 96.5 ms | 14.2 ms | 6.8× |
| 波形降采样 | 60000 帧 → 1366 桶，一次性（含 dB → 振幅） | 1.97 ms | 1.92 ms | 1.0× |
| 同上 | 改宽度重算（振幅已缓存） | 1.97 ms | 0.15 ms | 13.6× |

本机同时有多个会话在跑重活，绝对值有 ±30% 噪声（同一份旧实现两次运行 2645 / 3415 ms），倍数更可信。
互相关的累加次序要与旧实现一致，不能向量化重排，只跳过 `audio[i] ≤ 0` 的项（本来就不加）；
降采样一次性调用基本持平（主要成本是 6 万次 `pow`，两边调的都是 CRT），收益在面板改宽度时不再重算。

## 解析域：EPUB 章节 DOM 派生量（BUG-3433）

`ffc_parse_epub_chapter`（`src/parse/epub.rs`，Dart 绑定 `EpubChapterScanner`）一次解析一章 XHTML，
按请求位产出纯文本（ruby 剥离、`\s+` 折叠）+ 学习字数、ruby 读音轨（块尾 / 场景分隔）、目录锚点偏移、
带位置的插图扫描、整份文档的图片引用、全书搜索坐标系文本。调用方是 `EpubBook` 的
`chapterPlainText` / `chapterPlainTextWithRuby` / `chapterCharacterCount` / `chapterAnchorCharOffsets` /
`isImageOnlyChapter` / `chapterImageSrcs` / `images` / `chapterSearchText`，原 Dart 遍历已删除。

**建树是 `package:html` 0.15.6 的逐行移植**（`src/parse/html5lib/`），不是任何现行规范实现：学习统计、
阅读位置、有声书 cue 偏移都建在这些数上，结果必须与旧实现逐码元相同，而 `package:html` 停在旧版
WHATWG 算法（没有 `<template>` 内容文档、`<rb>` / `<rtc>` 不隐含结束、外来内容里调整过名字的属性排到
属性表末尾……），html5ever 在畸形输入上与它分叉。旧实现 `parse()` 会抛异常的输入（数字字符引用超出
64 位）返回 `BAD_INPUT`，Dart 侧抛 `FormatException`。唯一的已知差异（所有者 2026-10-19 接受）：
畸形的超深嵌套上旧实现抛 `StackOverflowError`（阈值随运行时变：JIT 约 5000 层、AOT 约 1–2 万层），
这里深树换到按深度定栈的线程上遍历，照常给出结果，不设人为深度上限；旧实现能算出结果的输入，结果相同。

对拍（2026-10-19）：61 本真书 1923 章（無職転生 1–26 卷等）树转储逐字节相同、全部派生量相同；固定种子
标签汤 / 突变语料约 30 万份的树转储与派生量都相同。回归向量（旧实现生成）：树级见 `src/parse/html5lib/tests.rs`，
派生量级见 `packages/fushi_engine/test/epub/chapter_scan_vectors_test.dart`。

| 项（55 本书 1649 章、2357 万 UTF-16 码元，整书一遍） | Dart DOM + Rust 字数（迁移前） | Rust | 倍数 |
|---|---|---|---|
| 纯文本 `chapterPlainText` | 5,986–6,261 ms | 2,767–3,085 ms | 2.0–2.2× |
| 学习字数 `chapterCharacterCount` | 6,403–6,412 ms | 2,688–3,389 ms | 1.9–2.4× |
| 插图索引 `images` | 4,492–4,589 ms | 2,746–2,986 ms | 1.5–1.6× |
| 锚点偏移 `chapterAnchorCharOffsets` | 4,153–4,196 ms | 2,605–3,314 ms | 1.3–1.6× |

基准脚本 `packages/fushi_engine/tool/bench/epub_chapter_scan_bench.dart`（Windows x64，同机交替跑两轮）。

## 解析域：视频文件名 / 字幕时间轴 / Fribb 映射

| 符号 | 作用 |
|---|---|
| `ffc_parse_filename_parse_batch(units, units_len, lens, count, ext_units, ext_units_len, ext_lens, ext_count, current_year, u8** out, usize* out_len) -> i32` | 一批名字（UTF-16 池 + 每条长度）按 anitomy 式规则解析；扩展名表与「今年」由调用方给（结果与运行日期无关、可冻结向量） |
| `ffc_parse_filename_candidates_batch(同上) -> i32` | 一批完整路径 → 有序候选（父目录名优先，跳过 Downloads / 新建文件夹 / 盘符等非标题目录），每条带 `inputIndex` |
| `ffc_parse_filename_trailing_season_batch(units, units_len, lens, count, i32* out) -> i32` | 「标题尾部裸数字季号」判定，每条输出 季号 + 标题区间（无 = -1） |
| `ffc_parse_subtiming_summarize(const u16*, usize, …) -> i32` | srt / vtt 的 `起 --> 止` 与 ass/ssa `Dialogue:` 扫描，给 cue 数 / 最早起点 / 最晚终点 |
| `ffc_parse_fribb_entries(const u8*, usize, u8** out, usize* out_len, i32* err_kind, usize* err_offset) -> i32` | Fribb `anime-list-full.json` 一遍扫描 + 按 anidb_id 归并；非法 JSON / 顶层非数组分别报错 |

| 调用方 | 之前（纯 Dart） | 现在 |
|---|---|---|
| `fushi_engine/lib/media/video/scraper/filename_parser.dart` `FilenameParser`（`parse` / `parseAll` / `candidatesForPath` / `takeTrailingNumericSeason`） | 几十条 `RegExp` 规则引擎 | `MediaNameNative`；批量一次 FFI，Dart 只剩结果对象适配 |
| `fushi_engine/lib/media/video/subtitle/subtitle_timing_check.dart` `summarizeSubtitleTiming` | 两条正则 + `_parseClock` | `SubtitleTimingNative` |
| `fushi_engine/lib/media/video/metadata/anime_identity_mapping.dart`、`discovery/anime_tmdb_cross_reference.dart` | `jsonDecode` 整表 + `fromRows` 归并 | `animeIdentityEntriesFromJsonUtf8` → `FribbNative`，Dart 只建三张索引 |

口径：原正则大量用先行断言，且 Dart `RegExp` 是逐 UTF-16 码元、`\s` 为 JS 空白集合、`\d` 只有 ASCII、
不区分大小写走 JS Canonicalize（非 ASCII 永不折叠到 ASCII）——`regex` crate 在这些边界上不一致，所以
`src/parse/media_name/js_regex.rs` 实现了本域用到的那部分 ECMAScript 回溯语义，`dart_str.rs` 复现
Dart `trim` / `int.tryParse`，`toLowerCase` 用 crate 共用的冻结表（见下「Dart `toLowerCase` 口径」；只用于与常量比较、不进输出）。JSON 语法与 `jsonDecode` 一致（重复键后者生效、
孤立代理照收等，见 `fribb.rs` 文件头）。

回归：删旧实现前用旧 Dart（原文件副本）与新链路逐条对拍——本机视频库 1697 条真实路径（1698 个路径段）、
10 万条按真实词表拼的模糊名 + 2.5 万条模糊路径、76 个真实字幕文件（2534 万码元）+ 10 万条模糊时间轴、
Fribb 全表（7.5 MB）+ 1 万份模糊 JSON，**0 处不一致**。冻结摘要与代表样例在
`packages/fushi_engine/test/media/video/native_media_parse_vectors_test.dart`（语料生成器
`native_parse_corpus.dart`，固定种子：2 万名字 / 5 千路径 / 2 万字幕 / 5 千 Fribb 文档）。

基准（AOT，2026-10-19，i5-12600KF / Windows 11，同一进程 5 轮取最好；旧 Dart vs Rust + FFI 含结果重建）：

| 输入 | 旧 Dart | Rust + FFI |
|---|---|---|
| 文件名 1698 个真实路径段 | 60.6 ms | 32.1 ms（批量） |
| 文件名 21698 条（真实 + 模糊） | 1,938 ms | 887 ms（批量）/ 1,339 ms（逐条调 `parse`） |
| 字幕时间轴 76 个文件 / 2534 万码元 | 7,390 ms | 2,738 ms |
| Fribb 全表 7.5 MB（含 `utf8.encode` 49.5 ms） | 278 ms | 198 ms（FFI + 记录解码本体 102 ms，余为 Dart 重建条目对象） |

## 解析域：种子元数据 bencode 与 Anki 媒体引用扫描

| 符号 | 作用 |
|---|---|
| `ffc_parse_bencode_inspect_torrent(const u8*, usize, u8** out, usize* out_len) -> i32` | 严格校验 .torrent 的 bencode、算 info hash（v1 SHA-1 / v2 SHA-256，取 `info` 值的原始字节）、读 name 与文件清单；结果是定长头 + 16 字节文件记录 + UTF-16 池（布局见 `src/parse/bencode.rs`），`ffc_free_bytes` 释放 |
| `ffc_parse_anki_matcher_new(const u16*, usize, const u64* offsets, usize count, Matcher** out) -> i32` / `ffc_parse_anki_matcher_free(Matcher*)` | 用一批媒体文件名（UTF-16 池 + `count + 1` 个偏移）建匹配器；Dart 侧挂 `NativeFinalizer` |
| `ffc_parse_anki_names_in(Matcher*, const u16*, usize, const u64* text_offsets, usize, const u64* group_offsets, usize, u8** out, usize* out_len) -> i32` | 一次扫一批「组」（一组 = 一条笔记的全部字段），输出 u32：组起点表 + 命中的名字下标 |
| `ffc_parse_anki_lower_utf16(u16*, usize) -> i32` | 原地按 Dart `toLowerCase` 折叠（口径自检用） |

| 调用方 | 之前（纯 Dart） | 现在 |
|---|---|---|
| `fushi_engine/lib/media/torrent/torrent_metainfo.dart` `inspectTorrentMetainfo` | `_BencodeReader` 建整棵值树 + `package:crypto` | `ffcInspectTorrentMetainfo`；Dart 只留空 / 超 16 MiB 入口检查、`expectedInfoHash` 比对、展示名 `trim()`，文件清单错误仍在 hash 比对之后抛 |
| `fushi_anki/lib/src/anki_media_dedup.dart` `MediaNameMatcher` | 按扩展名锚定的多模式子串匹配 | `FfcMediaNameMatcher`；新增 `namesInEach`，`AnkiConnectRepository` 建对照表 / 删前复核都整批一次调用 |

口径逐条照旧实现复现（Rust 模块注释里列了全部）：错误消息逐字一致；键按 Dart
`utf8.decode(allowMalformed: true)` 解码后判重——**开头的 UTF-8 BOM 被剥掉**（`\u{FEFF}info` 与
`info` 是同一个键）；字节串在 Dart 里是 `Uint8List`，也满足 `is List<Object?>`，所以 `files` /
`path` 写成字节串时按「元素全是整数的列表」处理；字节串长度让 `index + length` 溢出 i64 时
报旧实现 catch-all 的「truncated or malformed bencode」。大小写折叠用 crate 共用的 Dart
`toLowerCase` 冻结表（见下「Dart `toLowerCase` 口径」），测试对每个码点与 `String.toLowerCase` 比对。

SHA-1 用 RustCrypto `sha1` 0.10（MIT OR Apache-2.0）。

回归：删旧实现前用旧 Dart 跑真实种子（libtorrent 测试集 + 本机下载的种子）、手写边界样本与
模糊变异，以及本机真实 Anki 牌组（30794 条笔记、223572 个媒体名）全量对拍，0 处不一致；冻结的
向量在 `packages/fushi_compute/test/{bencode_test,anki_media_test}.dart` 与
`packages/fushi_engine/test/media/torrent/torrent_metainfo_native_test.dart`。

基准（AOT，2026-10-18，i5-12600KF / Windows 11；旧 Dart vs Rust + FFI，含结果解码）：

| 输入 | 字节 | 文件数 | 旧 Dart | Rust + FFI |
|---|---|---|---|---|
| 真实种子 | 542 KB | 290 | 13.80 ms | 0.91 ms |
| libtorrent `large.torrent` | 100 KB | 1 | 1.95 ms | 0.09 ms |
| `v2_multiple_files` | 97 KB | 0 | 0.03 ms | 0.03 ms |
| 合成 2 万文件 | 1.38 MB | 20000 | 198.6 ms | 53.8 ms |
| 合成 10 万文件 | 6.93 MB | 100000 | 880.1 ms | 395.4 ms（其中 FFI 本体 216.7 ms，余为 Dart 侧建文件清单对象） |

Anki 媒体引用扫描（真实牌组 30794 条笔记 / 9054 万 UTF-16 码元，扫全部笔记；Rust 每批 100 条笔记一次 FFI）。
建表是端到端（`MediaNameMatcher(names)`：Dart 侧打包 UTF-16 池 + 偏移、跨 FFI、Rust 建表），AOT，
2026-10-19 同机同轮（i5-12600KF / Windows 11，机器上有其它会话在跑，绝对值有 ±30% 噪声，同轮相对关系稳定）：

| 媒体名数 | 旧 Dart 建表 | 旧 Dart 扫描 | Rust 建表（改前 → 现在） | Rust 扫描（改前 → 现在） |
|---|---|---|---|---|
| 50 | 0.0 ms | 2,970–3,728 ms | 0.1 → 0.0 ms | 865 → 754 ms |
| 2,000 | 1.1–1.2 ms | 6,873–9,024 ms | 2.6–3.0 → 0.6–0.7 ms | 1,278 → 856 ms |
| 18,000 | 15.8–19.3 ms | 8,475–15,465 ms | 25.7–31.7 → 6.4–12.5 ms | 1,210 → 1,083 ms |
| 223,572 | 248–297 ms | 15,994–22,784 ms | 327–349 → 100–137 ms | 2,198 → 1,537 ms |

223,572 名建表的拆分（现在）：Dart 打包 UTF-16 池约 38 ms（逐码元写 `Pointer`，比堆上
`Uint16List` + memcpy、`join` 后拷贝都快）、原生建表约 53 ms（其中 Dart `toLowerCase` 口径折叠
约 15 ms、切片哈希约 10 ms）、其余 Dart 包装 < 10 ms。改前原生建表约 280 ms、释放约 55 ms：
逐键 `Box<[u16]>` + `Vec<u32>` 再进 `HashMap`（每个名字 4～5 次分配，释放同样逐个）。现在
不同的折叠名首尾相接放进一块预留好的缓冲区，查表是只存「哈希片段 | 编号」的开放寻址表，
原名下标用 CSR 存，建表与释放都只有几块大分配；折叠对全 ASCII / 无代理对的段走整段无分支
映射（扫描也因此变快）。真实牌组 × 6 组名单（含大小写重名、空名、无扩展名）与旧 Dart 逐条
对拍命中集合与顺序，0 处不一致。

## 解析域：视频标题打分 / AniDB 标题目录 / anime XML

| 调用方 | 之前（纯 Dart） | 现在 |
|---|---|---|
| `fushi_engine/.../scraper/title_normalizer.dart`（`TitleNormalizer`，39 处调用） | 逐码点查繁简 Map + 正则折叠空白；`tokens` / Levenshtein DP | 只剩 FFI 外壳（`TitleScoreNative`，`src/parse/title_score.rs`）；另有批量入口 `normalizeAll` / `similarityNormalizedBatch` / `similarityNormalizedMatrix` |
| `fushi_engine/.../metadata/anidb_title_catalog.dart` | 后台 isolate 里 `XmlEventDecoder` 流式事件 + Dart 建三张索引，Isolate.exit 交回整图 | 后台 isolate 把 gzip 解压块原样喂 `AniDbCatalogBuilderNative`；目录与索引驻留原生内存，句柄地址交回主 isolate `AniDbCatalogNative.adopt`（`NativeFinalizer` 兜底释放）；搜索一次 FFI。记录在同一后台 isolate 里一次物化：`AniDbCatalogNative.borrow` 借出扁平记录表（`ffc_parse_anidb_catalog_record_table`，原生内存上的零拷贝视图，type / language 去重），整表解码成按 id 的 Map 随句柄经 Isolate.exit 交回，`findByAnimeId` 与搜索命中取记录都是 Map 查找 |
| `fushi_engine/.../metadata/anidb_video_metadata_provider.dart` | DOCTYPE 正则预检 + `XmlDocument.parse` | `parseAniDbAnimeXml`：原生解析成只读元素树，取值逻辑（`getElement` / `findElements` / `innerText`）仍在 Dart |
| `fushi_engine/.../metadata/tmdb_episode_matcher.dart` | 四轮 × 来源 × 候选 × 标题² 逐对 `similarityNormalized` | 整池标题一次批量归一化 + 一次相似度矩阵，查表；匹配逻辑不变 |

**逐位一致是硬约束**，按 Dart 语义复刻而不是按 Rust 习惯：字符串一律 UTF-16（`String.runes`
解码规则、孤立代理照算）；长度比较用码元、编辑距离与分词用码点（原实现就是混用的）；`\s` / `trim()` /
分词字母判定是 `tool/gen_title_tables.dart` 从 Dart 运行时逐码点冻结的表（换 SDK 重生成会改口径），
`toLowerCase` 用 crate 共用的冻结表（见下「Dart `toLowerCase` 口径」）；`package:xml` 6.6 的事件语法、实体解码、嵌套校验、`int.tryParse`
（含 `0x` 前缀与 64 位回绕）、Dart UTF-8 解码器的报错文案与偏移、Dart `List.sort` 的不稳定
双轴快排（两处排序有打平且后面截断，换稳定排序会换掉选中的标题）都逐步照抄。编辑距离用 Myers 位
并行（≤64 码点），与 DP 随机对拍相等。唯一刻意差异：原实现在块尾把未见 `<` 的文本先吐成事件，
实体恰被 zlib 输出块切开时解不出来；这里等到 `<` 才吐（真实标题包上两者输出相同）。

回归：`fushi/test/media/video/metadata/anidb_native_parity_test.dart`（合成 3000 部目录 /
370 查询 / 3255 标题对 / 300 个分集匹配场景的输出摘要，由删除前的 Dart 实现冻结）、
`packages/fushi_compute/test/{title_score,anidb_native}_test.dart`。迁移时另对真实每日标题包
（17063 部 / 101889 标题、679 条查询的完整结果、8800 对相似度位模式）和 1500 个分集匹配场景做过
全量对拍，完全一致；畸形包 68 例 × 明文 / gzip 结局（异常文案 + cause）、anime XML DOM 19 例一致。

基准（2026-10-19 复测，本机仍有其它会话并发；JIT `dart run`；真实标题包 1.8 MB gzip /
8.0 MB XML；同一台机器、同一轮先跑旧实现再跑新实现）：

| 场景 | 规模 | 改动前（Dart） | 改动后（Rust 含 FFI） | 倍数 |
|---|---|---|---|---|
| 标题包首次加载（后台 isolate：解压 + 解析 + 建索引，3 次） | 17063 部 / 101889 标题 | 5.37 / 5.96 / 5.24 s | 0.93 / 0.81 / 0.90 s | ≈ 6× |
| 精确搜索 p50 / p90 | 283 条 | 25 / 160 µs | 21 / 41 µs | 1.2× / 3.9× |
| 前缀搜索 p50 / p90 / max | 58 条 | 141 µs / 11.3 / 61.6 ms | 44 µs / 1.5 / 3.4 ms | 3–18× |
| 模糊搜索 p50 / p90 / max（UI isolate 上） | 330 条 | 33.6 / 99.1 / 381.7 ms | 2.8 / 9.1 / 39.1 ms | ≈ 10–12× |
| `similarity`（含两次归一化） | 8800 对 | 237 ms | 83 ms | 2.9× |
| `similarityNormalized`（逐对 FFI） | 8800 对 | 114 ms | 36 ms | 3.2× |
| `normalize` | 101889 个标题 | 618 ms | 92 ms | 6.7× |
| TMDB 分集匹配（批量归一化 + 相似度矩阵） | 1500 场景 / ≈35k 链接 | 35.0 s | 6.4 s | 5.4× |
| `findByAnimeId`（异步 API，id 1..25000，见下） | 25000 次 | 稳态 10 / 12 ms（min / 中位） | 稳态 9 / 12–13 ms | ≈ 1×（两边都是 Map 查找） |

`findByAnimeId` 那一行是 2026-10-19 加粗边界之后重测的（同一进程里两份目录各加载一次，交替各跑
15 轮 id 1..25000、并交换先后顺序；首轮含 JIT 预热，谁先跑谁慢，不计）。加粗之前逐条
`ffc_parse_anidb_catalog_find`：每条记录在 Rust 侧逐字段 clone + 编码字符串列表、Dart 侧再解码，
首轮 25000 次 317–377 ms（同轮旧 Dart 47–55 ms，≈ 13 µs/条；拆开看纯 FFI 调用 25000 次只有
≈ 1 ms，钱全花在逐条复制 / 编码 / 解码上）。现在改成：Rust 目录本身就存成扁平记录表（同时省掉
原来每个标题 4 个 `Vec<u16>` 的堆分配，搜索索引直接读它的 normalized 区间），后台 isolate 一次
FFI 借出、整表物化成 Dart 记录。代价是首次加载多了这一步物化：同轮 7 次加载中位数 加粗前
739–925 ms → 加粗后 872–1016 ms（物化本身 36–130 ms，都在后台 isolate；旧 Dart 2911–3529 ms）。
搜索不变（同轮 600 条：加粗前 399–443 ms / 加粗后 411–543 ms / 旧 Dart 3617–4069 ms，结果摘要三者一致）。

## 解析域：字幕行内标签批量剥离

| 符号 | 说明 |
|---|---|
| `ffc_parse_subtitle_strip_html_tags_batch(const u16* units, usize len, const u32* ends[count], usize count, u8** out, usize* out_len) -> i32` | 一批行内 HTML / VTT / 增强 LRC 词级时间标签剥离（`ffc_parse_subtitle_strip_html_tags` 的批量版）：各条首尾相接的 UTF-16 + 每条结束下标（单调不减、末项 = `len`，否则 `INVALID_ARGUMENT`）；数据区 `count` 个字符串引用，逐条与单条入口相同，标签不跨条匹配 |

`packages/fushi_audio` 的 `LrcParser` 先收齐整份 LRC 带时间标签的行，再经 `stripHtmlTagsBatch`
一次剥离（增强 LRC 每行都有 `<MM:SS.xx>`，原先逐行一次 FFI，HBK-AUDIT-008）。

## Dart `toLowerCase` 口径（全 crate 共用）

凡是复刻 Dart `String.toLowerCase()` 的地方（Anki 媒体扫描、字幕段头 / 样式名、标题归一化与 AniDB
目录、媒体文件名、弹幕关键字、EPUB / html5lib 标签名比较）都走 `src/parse/dart_lower.rs`，查同一张
表 `src/parse/dart_lower/table.rs`。表由 `tool/gen_dart_lower_table.dart` 从**运行脚本的 Dart SDK**
逐码点导出（`--check` 只比对；2026-10-19 在 Flutter 3.47.6 / Dart 3.13.5 下与入库表一致），其它生成器
不再各自导出小写表。Dart VM 的 `toLowerCase` 是逐码点简单映射：不看上下文（词尾 Σ 照样折成 σ）、
U+0130 折成单个 `i`、UTF-16 长度与下标不变，孤立代理原样。

**不要用 Rust 的 `char::to_lowercase` / `str::to_lowercase`**：它是完整映射（U+0130 → `i` + U+0307），
Unicode 版本也比 Dart VM 的表新——Rust 1.96 下有 465 个码点 Dart 原样保留、Rust 会折叠（切罗基文、
格鲁吉亚 Mtavruli、拉丁扩展-D 新增字母、若干补充平面文字），测试
`dart_lower::tests::rust_std_differs_only_where_dart_keeps_the_code_point` 钉住这一形态。换 SDK 后
`--check` 不一致说明 Dart 的表变了，重生成会同时改变上述所有域的口径。

## 加密域（`ffc_crypto_*`，`src/crypto.rs` + `src/crypto/`）

| 符号 | 作用 | 调用方 |
|---|---|---|
| `ffc_crypto_aacs_open / _decrypt_units / _close` | AACS 1 内容解密：求单元密钥 + CBC + 0x47 校验 + 清 CPI + 多 key 轮换重试，一次处理一批 6144 字节单元；遇坏即停，失败码分三类：-20 标为未加密却不是合法 TS（全零单元落这里，数据坏）、-21 哪个 key 都解不开且还没解开过加密单元（key 不符或首单元坏，分不清）、-23 哪个 key 都解不开但此前已解开过加密单元 / 单元含整扇区全零（数据坏，不是 key） | `fushi_engine/.../aacs_content_decoder.dart`（relay 每 32 单元一次） |
| `ffc_crypto_aes128_ecb_decrypt` | unit key 表解密 | 同上 `fromVolumeUniqueKey` |
| `ffc_crypto_aes_cbc_pkcs7_decrypt` | AES-128/192/256-CBC + PKCS7，原地 | HLS 分片（`anime_episode_downloader.dart`）、comico 根 URL |
| `ffc_crypto_aes_cbc_encrypt` | AES-CBC 加密（不填充） | 只给测试造密文 |
| `ffc_crypto_sync_obfuscate_file / _deobfuscate_file(src, src_len, dst, dst_len)` | 云同步「防扫盘」混淆：文件 → 文件整段在 Rust 里流式读（1 MiB 块）、XOR、写（目标创建或截断）；还原时无魔数则原样复制。keystream = SHA-256("hibiki")、魔数 `HBKOBF 01 00`，**永远不能改**，云端旧文件靠它解开；读写失败返回 -30 | `fushi/lib/src/sync/sync_obfuscator.dart` `obfuscateFile` / `deobfuscateFile`（`Isolate.run`）← `ObfuscatingSyncBackend` 上传 / 下载临时文件。内存里的字节（封面、Range 流播）留 Dart，见下 |
| `ffc_crypto_p256_public_key / _sign_sha256 / _verify_sha256` | P-256 ECDSA/SHA-256，RFC 6979 确定性 k，P1363 `r‖s`，不做 low-s 归一 | `LeaderboardIdentity`（排行榜账户 / 安装身份）、`InterconnectDeviceKey`、host 自签 TLS 证书（`fushi_tls_identity.dart`，DER 在 Dart 拼） |

依赖：RustCrypto `aes` 0.8 / `cbc` 0.1 / `p256` 0.13（Apache-2.0 OR MIT）。仓库因此不再直接依赖
pointycastle / basic_utils（pointycastle 仍经 dartssh2 等第三方包间接进 lock）。

一致性：删 Dart 实现前用旧实现（pointycastle 3.9.1 / basic_utils 5.7.0 / Dart XOR）冻结向量
`packages/fushi_compute/test/crypto/crypto_vectors.json`（AACS / HLS）与 `crypto_vectors_v2.json`
（混淆、ECDSA 签名与验签边角、证书 TBS 与 PKCS#8 PEM）。旧实现的两处边角原样保留：空 HLS 分片旧版抛
`RangeError`（pointycastle 越界），现为 `ArgumentError`；验签收混合编码点（`06`/`07` 前缀，不核对 y 奇偶）
由 Dart 侧改写成 `04` 再交原生。证书签名值不同（旧实现 k 随机，现为 RFC 6979），TBS 与 PEM 版式逐字节相同。

**ARMv8 AES**：aes 0.8 在 aarch64 上要 `--cfg aes_armv8` 才用硬件指令（Linux / Android / Apple 运行时
检测），否则退回软件实现（结果相同、慢数倍）。本目录与 `native/fushi_ios_umbrella` 各有一份
`.cargo/config.toml` 带上它；cargo 按**工作目录**找配置（构建脚本都 `cd` 到各自目录），且设了
`RUSTFLAGS` / `CARGO_ENCODED_RUSTFLAGS` 环境变量时会**整个忽略**配置里的 rustflags，那时要在变量里
自己带 `--cfg aes_armv8`。丢了 cfg 不再静默：`src/crypto.rs` 在 aarch64 且无 `aes_armv8`（也没显式
`--cfg aes_force_soft`）时 `compile_error!`；`verify_abi.sh` 对 aarch64 的独立 `libfushi_compute.{so,dylib}`
另反汇编核对必有 `aese`/`aesd` 指令（arm64-v8a 实测硬件版 288 条、软件版 0 条；伞形 `.a` / Runner 混着别的
crate 的 AES 指令，跳过）。

基准（云同步混淆与 ECDSA，2026-10-19，i5-12600KF / Windows 11，AOT；旧实现从删除前的代码原样拷进仓库外的
临时脚本，pointycastle 3.9.1；本机同时有其它会话占 CPU，数字有噪声）。混淆的对照是**最好的 Dart 写法**
（64 位字长 XOR 循环），不是删除前的逐字节循环：

| 场景 | Dart（字长循环） | 本库 |
|---|---|---|
| 文件 → 文件混淆 64 KiB（`File.openRead` → XOR → `openWrite`；本库含 `Isolate.run`） | 2.84 ms | 1.31 ms（2.2×；同 isolate 直调 0.97 ms） |
| 同上 4 MiB | 44.5 ms | 15.0 ms（3.0×） |
| 同上 256 MiB | 1,686 ms | 534 ms（3.2×） |
| 同上，旧形态「Dart 流式 + 每块一次 FFI XOR」 | — | 64 KiB 1.28 ms / 4 MiB 50.3 ms / 256 MiB 1,887 ms（不比字长 Dart 快，已删） |
| 内存字节 XOR（封面整块、Range 流播），64 KiB / 1 MiB / 8 MiB 各 3 轮 | 520～1870 MB/s | 每块一次 FFI（拷入拷出）550～1280 MB/s，9 组里 8 组更慢 → **不搬，留 Dart** |
| ECDSA 签名（RFC 6979） | 22.7 ms | 0.92 ms（25×） |
| ECDSA 验签 | 40.2 ms | 0.89 ms（45×） |
| 私钥 → 公钥点 | 25.4 ms | 0.47 ms（54×） |

内存字节的 XOR 是纯内存带宽操作：Rust 内核本身远快于 Dart，但 FFI 必须把数据拷进原生暂存区再拷回 Dart 堆，
比 Dart 字长循环（拷一次 + 原地 XOR）多一趟内存。试过的加粗办法都走不通：
`TypedData.address` 免拷贝只给 `@Native` 静态绑定（本包按路径 `DynamicLibrary.open`，编译期即报错）；
`Pointer.asTypedList(finalizer:)` 让 Rust 结果直接当 Dart 字节交出去、省掉拷出——Dart 3.13.5 AOT
（Windows）下循环分配几次就访问违例崩溃（JIT 正常）；Range 数据来自 Dart 侧 HTTP 流，整段搬进 Rust 等于
把网络栈搬过去；封面本来就是内存里的小数据。所以这两条按规则留在 Dart（`SyncObfuscator.obfuscateBytes` /
`deobfuscateBytes` / `deobfuscateBodyAt`），keystream 在那里另有一份 SHA-256("hibiki")；
`sync_obfuscator_vectors_test.dart` 与 `crypto_vectors_v2_test.dart` 用删除前的冻结向量同时钉住 Dart 与 Rust 两侧。
同一份脚本核对了签名与旧实现逐字节相同。

## 构建

| 平台 | 命令 | 产物 | 怎么进包（缺产物 = 构建失败） | 体积（2026-10-19 实测，含 parse 域） |
|---|---|---|---|---|
| Windows x64 | `powershell -ExecutionPolicy Bypass -File native/fushi_compute/build_windows_dll.ps1` | `prebuilt/windows-x64/fushi_compute.dll` | `fushi/windows/CMakeLists.txt` 拷到 exe 同级（缺则配置期 `FATAL_ERROR`）；服务端放 `bundle/lib/` | 1,888,256 B（依赖只有 KERNEL32 / VCRUNTIME140 / api-ms-win-crt） |
| Android | `build_android_so.ps1 [-NdkRoot …] [-Abis …]` / `build_android_so.sh <ndk-root> [abi…]`（cargo-ndk，API 24） | `prebuilt/android/<abi>/libfushi_compute.so` | `fushi/android/app/build.gradle` 的 `jniLibs.srcDirs`；`preBuild` 上的 `checkFushiComputeNative` 按 Flutter 的 target-platform 逐 ABI 检查 | arm64-v8a 2,062,568 B / x86_64 2,291,104 B（NDK 28.2；armeabi-v7a 未重测；NEEDED 只有 libc / libdl） |
| Linux x64 | `build_linux_so.sh` | `prebuilt/linux-x64/libfushi_compute.so` | `fushi/linux/CMakeLists.txt` 装进 `bundle/lib/`（缺则 `FATAL_ERROR`）；服务端放 `bundle/lib/` | 本机无 Linux，CI 出 |
| macOS | `build_macos_dylib.sh`（只出 arm64，部署目标 13.4） | `prebuilt/macos/libfushi_compute.dylib`（install name `@rpath/…`） | Runner 构建阶段（`fushi/macos/bundle_fushi_compute.sh`）拷进 `Contents/Frameworks`，缺则 `exit 1` | 1,725,464 B |
| iOS | `native/fushi_ios_umbrella/build_ios_staticlib.sh [device\|simulator\|all]` | 伞形 `libfushi_ios_umbrella.a`（fushi_p2p + fushi_fsrs + fushi_compute） | `-force_load` 链进 Runner；Runner 构建阶段 `fushi/ios/check_fushi_compute.sh` 在缺 `.a` / `FUSHI_IOS_NATIVE_LDFLAGS` 为空 / `.a` 不导出 `ffc_abi_version` 时失败 | device `.a` 16,526,192 B（三合一，2026-10-18 测、未含 parse 域） |

- macOS 坑（2026-10-24 定根因）：macOS 27 的 dyld（dyld-27102）对链接 SDK ≥ 27 的 Mach-O 要求 LINKEDIT
  字符串表起点 8 字节对齐，否则 dlopen 报 `mis-aligned LINKEDIT string pool`。Apple ld 的输出是对齐的；
  弄坏它的是 rustc 的 `-C strip`（Apple 目标上调 `rust-objcopy` 重排 LINKEDIT，间接符号表项数为奇数时
  字符串表只对齐到 4）。cargo 在 release（`debug = 0`）下就算 profile 写 `strip = false` / `"none"` 也照样传
  `-C strip=debuginfo`，所以 `build_macos_dylib.sh` 在 `cargo rustc` 末尾加 `-C strip=none` 覆盖，改用
  `/usr/bin/strip -x` 去本地符号，install name 由链接时的 `-Wl,-install_name` 设好，再用 python ctypes 调
  `ffc_abi_version` 冒烟；`verify_abi.sh` 按同一套 dyld 规则（看二进制记录的链接 SDK）静态核对对齐。
  五个 Rust crate（fushi_compute / fushi_fsrs / fushi_p2p / fushi_rwkv / fushi_web_core）同一做法。
  iOS 静态库不经 rustc 链接、没有这一步，不受影响。
- 伞形库：`pub extern crate fushi_compute;`（不用 glob 重导出，`ABI_VERSION` 会与 fushi_fsrs 撞名）；
  fushi_compute 加依赖时要同步更新 `native/fushi_ios_umbrella/Cargo.lock`（构建用 `--locked`）。
  因为三个 crate 编成一个 `.a`，iOS 上 fushi_p2p / fushi_fsrs 实际也随之变成必需。
- `verify_abi.sh <二进制> [nm]` 递归抓 `packages/fushi_compute/lib/` 下所有 `'ffc_*'` 字面量，逐个核对
  导出表（ELF / Mach-O / ar 静态库）；规模哨兵下界 117。

## CI

| workflow / job | 做什么 |
|---|---|
| `native-compute-gate.yml`（PR，paths） | Android 三 ABI cargo-ndk + ELF 架构 + 符号；ubuntu `cargo test --release --locked` |
| `build-multiplatform.yml` windows / linux-server / macos / ios | 编库 + `verify_abi.sh`；Windows / linux-server 跑 `packages/fushi_compute` 整个 `dart test`；出包后硬核对 bundle / Frameworks（install name、架构、ctypes 冒烟）/ iOS Runner 符号；路径门 `app_common` / `server_only` 收 `native/fushi_compute/`、`packages/fushi_compute/` |
| `release.yml` build / tests | 三 ABI 编 + 核对、逐 APK 逐 ABI 核对 `libfushi_compute.so`；单测门先编 Linux .so 并设 `FUSHI_COMPUTE_LIB` |
| `release-desktop.yml` windows / macos / ios | 编、出包后硬核对 |
| `release-server.yml` linux / windows | 编、硬拷进 bundle、拿 bundle 里那份跑真 FFI 测试 |
| `main.yml` build / unit-tests、`server-gate.yml`、`golden-tests.yml` | 经 `.github/actions/setup-fushi-compute` 先编库并导出 `FUSHI_COMPUTE_LIB` |

`.github/actions/setup-fushi-compute`：Rust / cargo-ndk 版本取 `native-store-names/names.sh` 的
`P2P_RUST` / `CARGO_NDK`，按 runner 平台编库并把 `FUSHI_COMPUTE_LIB` 写进后续步骤（可选同时编
Android ABI）。守卫 `fushi/test/build/fushi_compute_hard_dependency_guard_test.dart`。

## 本地开发前提

- 需要 Rust（`rustup`，工具链与 fushi_p2p / fushi_fsrs 同钉）。`tool/setup_worktree.ps1` →
  `tool/bootstrap.ps1` 在 pub get 之后按主机平台编本库（Windows `build_windows_dll.ps1`、
  Linux `build_linux_so.sh`、macOS `build_macos_dylib.sh`）；没有 cargo 直接失败并说明怎么装。
  显式跳过：`-SkipNativeCompute`（或 `FUSHI_BOOTSTRAP_SKIP_NATIVE_COMPUTE=1`），之后 flutter
  build / test 之前必须手动跑对应脚本。
- `flutter test` / `dart test`：加载器在测试宿主（`dart` / `flutter_tester`）下从当前目录向上找
  `native/fushi_compute/prebuilt/<windows-x64|linux-x64|macos>/`，编过就能跑；也可以用
  `FUSHI_COMPUTE_LIB=<绝对路径>` 显式指定。正式 app / 服务端不查这个目录（DLL 投毒面）。
- Android 出包另需 cargo-ndk 编 `prebuilt/android/<abi>/`；iOS 出包需在 macOS 上编伞形库。

## 测试

```
cargo test --release                    # 本目录，Rust 单元测试
dart test                               # packages/fushi_compute 下（真 FFI，库缺失即失败）
```

## 许可

本 crate GPL-3.0-only（随 app）。依赖：`md4` / `sha1` / `sha2`（RustCrypto）、`crc32fast`，均 MIT OR Apache-2.0；
`brotli-decompressor`（及其 `alloc-no-stdlib` / `alloc-stdlib`）BSD-3-Clause / MIT；都可链进
GPL-3.0 的 app 本体；发版前确认 app 开源许可页带上它们的声明。
`regex`（MIT OR Apache-2.0）同理。`src/parse/html5lib/` 移植自 `package:html`（MIT，原许可全文保留在
`mod.rs` 头部），发版许可页同样要带上。

## 全景域（`ffc_pano_*`）

首页「媒体库全景」与分享用 16 秒开场动画的胖核心（`src/pano.rs`，Dart 绑定
`packages/fushi_compute/lib/src/pano/`，消费端 `fushi/lib/src/media/panorama/`）。状态全在 Rust：
布局（大爆炸 → 三旋臂星系 → 半径 12 球幕 + 词外壳 / 绕封面的随机倾斜轨道）、封面 3D 姿态（星系里面朝上
躺平并自转、过渡时四元数 slerp 错峰约 1.2 秒立起、球幕上正面朝球心大致直立；背面画正向略暗的封面）、
交互镜头（星系俯视开场，拉近连续收拢成球幕）、锁定飞入（其余暗到 10%、目标沿半径飞到正前方占视口 62% 高）、
每帧投影与远近样式（远：细小淡；近：粗大 + 白字心彩色描边，smoothstep 连续过渡）。

输出是三角网格：封面每张切 4×4 小格（斜看时纹理不沿对角线折开），词是屏幕空间字形片，按远到近排序、
按图集页切批（u16 索引，每批 ≤ 65535 顶点），Dart 每批一次 `drawVertices`。锁定目标单独一批（页号 -1、
纹理坐标 0..1），由 Dart 用高清带框封面画，和翻开的书是同一张图。

| 符号 | 作用 |
|---|---|
| `ffc_pano_new(cells…, works…, words…, glyphs…, em_px, seed, out**) -> i32` | 一次交完图集格子 / 作品 / 词 / 字形表 |
| `ffc_pano_buffers(p, pos**, uv**, color**, index**, batch**, info**, caps*)` | 取输出缓冲（建图后不变，Dart 一次性取视图） |
| `ffc_pano_frame(p, t, dt, w, h, counts*)` | 每帧一次：写出排好序、切好批的网格 + 帧信息 |
| `ffc_pano_set_mode / _input / _select / _pick / _free` | 模式切换、拖拽 / 缩放 / 松手、选中飞入、拾取、释放 |

每帧耗时（release，i5-12600KF）：合成大库 400 部作品 + 1.38 万词约 1.2 ms（`cargo test --release
pano::tests::big_library -- --nocapture`）；本机真实库（132 部作品、展示 2,603 词、峰值 3.5 万顶点）约 0.26 ms。
