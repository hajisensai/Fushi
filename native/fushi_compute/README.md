# fushi_compute

Fushi 的 Rust 计算内核：CPU 密集操作（哈希 / 图像 / 文本匹配）的薄 C ABI，给 Dart FFI
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
  重建数字索引）逐个走 `ffcHash53`——实测比先打包再一次调用更快（打包要攒下整批字符串与字节，
  GC 压力比哈希本身还大）。`fushi_srs` 因此依赖 `fushi_compute`（纯 Dart FFI，不违反「不依赖
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
| `hash53` 批量（`SrsIds.ankiNumericIds`，重建索引） | 10 万个 | 287 ms | 132 ms（392 → 137 ms） |
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
Dart `trim` / `int.tryParse` / `toLowerCase`（逐码点简单映射，只用于与常量比较、不进输出）。JSON 语法与 `jsonDecode` 一致（重复键后者生效、
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
报旧实现 catch-all 的「truncated or malformed bencode」。大小写折叠用
`tool/gen_dart_lower_table.dart` 从 Dart SDK 冻结的逐码点表（Dart 是简单映射、不看上下文：
词尾 Σ 照样折成 σ，U+0130 折成单个 `i`），测试对每个码点与 `String.toLowerCase` 比对。

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

Anki 媒体引用扫描（真实牌组 30794 条笔记 / 9054 万 UTF-16 码元，扫全部笔记；Rust 每批 100 条笔记一次 FFI）：

| 媒体名数 | 旧 Dart 建表 | 旧 Dart 扫描 | Rust 建表 | Rust 扫描 |
|---|---|---|---|---|
| 50 | 0.0 ms | 6,034 ms | 0.1 ms | 1,824 ms |
| 2,000 | 1.4 ms | 10,070 ms | 3.8 ms | 2,143 ms |
| 18,000 | 24.6 ms | 11,730 ms | 43.6 ms | 1,849 ms |
| 223,572 | 364.7 ms | 20,331 ms | 777.7 ms | 3,356 ms |

## 构建

| 平台 | 命令 | 产物 | 怎么进包（缺产物 = 构建失败） | 体积（2026-10-19 实测，含 parse 域） |
|---|---|---|---|---|
| Windows x64 | `powershell -ExecutionPolicy Bypass -File native/fushi_compute/build_windows_dll.ps1` | `prebuilt/windows-x64/fushi_compute.dll` | `fushi/windows/CMakeLists.txt` 拷到 exe 同级（缺则配置期 `FATAL_ERROR`）；服务端放 `bundle/lib/` | 1,888,256 B（依赖只有 KERNEL32 / VCRUNTIME140 / api-ms-win-crt） |
| Android | `build_android_so.ps1 [-NdkRoot …] [-Abis …]` / `build_android_so.sh <ndk-root> [abi…]`（cargo-ndk，API 24） | `prebuilt/android/<abi>/libfushi_compute.so` | `fushi/android/app/build.gradle` 的 `jniLibs.srcDirs`；`preBuild` 上的 `checkFushiComputeNative` 按 Flutter 的 target-platform 逐 ABI 检查 | arm64-v8a 2,062,568 B / x86_64 2,291,104 B（NDK 28.2；armeabi-v7a 未重测；NEEDED 只有 libc / libdl） |
| Linux x64 | `build_linux_so.sh` | `prebuilt/linux-x64/libfushi_compute.so` | `fushi/linux/CMakeLists.txt` 装进 `bundle/lib/`（缺则 `FATAL_ERROR`）；服务端放 `bundle/lib/` | 本机无 Linux，CI 出 |
| macOS | `build_macos_dylib.sh`（只出 arm64，部署目标 13.4） | `prebuilt/macos/libfushi_compute.dylib`（install name `@rpath/…`） | Runner 构建阶段（`fushi/macos/bundle_fushi_compute.sh`）拷进 `Contents/Frameworks`，缺则 `exit 1` | 1,725,464 B |
| iOS | `native/fushi_ios_umbrella/build_ios_staticlib.sh [device\|simulator\|all]` | 伞形 `libfushi_ios_umbrella.a`（fushi_p2p + fushi_fsrs + fushi_compute） | `-force_load` 链进 Runner；Runner 构建阶段 `fushi/ios/check_fushi_compute.sh` 在缺 `.a` / `FUSHI_IOS_NATIVE_LDFLAGS` 为空 / `.a` 不导出 `ffc_abi_version` 时失败 | device `.a` 16,526,192 B（三合一，2026-10-18 测、未含 parse 域） |

- macOS 坑：本机 Mac（macOS 27.2）上 rustc 自带 strip（`strip = true`）+ `MACOSX_DEPLOYMENT_TARGET` 出的
  dylib dlopen 报 `mis-aligned LINKEDIT string pool`，`verify_abi.sh` 查不出来；所以
  `build_macos_dylib.sh` 关掉 cargo strip、改用 `strip -x`，并用 python ctypes 调 `ffc_abi_version`
  冒烟。`Cargo.toml` 另设 `[profile.release.build-override] strip = false`：同一工具链上被 strip 的
  构建脚本 / 过程宏也会坏（hajisensai/Fushi#2329）。fushi_fsrs / fushi_p2p 用的是旧写法，可能同样受影响（未验证）。
- 伞形库：`pub extern crate fushi_compute;`（不用 glob 重导出，`ABI_VERSION` 会与 fushi_fsrs 撞名）；
  fushi_compute 加依赖时要同步更新 `native/fushi_ios_umbrella/Cargo.lock`（构建用 `--locked`）。
  因为三个 crate 编成一个 `.a`，iOS 上 fushi_p2p / fushi_fsrs 实际也随之变成必需。
- `verify_abi.sh <二进制> [nm]` 递归抓 `packages/fushi_compute/lib/` 下所有 `'ffc_*'` 字面量，逐个核对
  导出表（ELF / Mach-O / ar 静态库）；规模哨兵下界 16。

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

本 crate GPL-3.0-only（随 app）。依赖：`md4` / `sha1` / `sha2`（RustCrypto）、`crc32fast`，均 MIT OR Apache-2.0，可链进
GPL-3.0 的 app 本体；发版前确认 app 开源许可页带上它们的声明。
`regex`（MIT OR Apache-2.0）同理。`src/parse/html5lib/` 移植自 `package:html`（MIT，原许可全文保留在
`mod.rs` 头部），发版许可页同样要带上。
