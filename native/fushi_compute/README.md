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
galgame helper / hook 相关（Windows 专属规则域，另开任务）；`aacs_configuration` /
`srs_backup_store` / `utils/archive/native_zip.dart` 的 `getCrc32`（不在本次范围）。

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

## 构建

| 平台 | 命令 | 产物 | 怎么进包（缺产物 = 构建失败） | 体积（2026-10-18 实测） |
|---|---|---|---|---|
| Windows x64 | `powershell -ExecutionPolicy Bypass -File native/fushi_compute/build_windows_dll.ps1` | `prebuilt/windows-x64/fushi_compute.dll` | `fushi/windows/CMakeLists.txt` 拷到 exe 同级（缺则配置期 `FATAL_ERROR`）；服务端放 `bundle/lib/` | 156,672 B（依赖只有 KERNEL32 / VCRUNTIME140 / api-ms-win-crt） |
| Android | `build_android_so.ps1 [-NdkRoot …] [-Abis …]` / `build_android_so.sh <ndk-root> [abi…]`（cargo-ndk，API 24） | `prebuilt/android/<abi>/libfushi_compute.so` | `fushi/android/app/build.gradle` 的 `jniLibs.srcDirs`；`preBuild` 上的 `checkFushiComputeNative` 按 Flutter 的 target-platform 逐 ABI 检查 | arm64-v8a 320,216 B / armeabi-v7a 226,912 B / x86_64 353,072 B（加 CRC-32 前测；NEEDED 只有 libc / libdl） |
| Linux x64 | `build_linux_so.sh` | `prebuilt/linux-x64/libfushi_compute.so` | `fushi/linux/CMakeLists.txt` 装进 `bundle/lib/`（缺则 `FATAL_ERROR`）；服务端放 `bundle/lib/` | 本机无 Linux，CI 出 |
| macOS | `build_macos_dylib.sh`（只出 arm64，部署目标 13.4） | `prebuilt/macos/libfushi_compute.dylib`（install name `@rpath/…`） | Runner 构建阶段（`fushi/macos/bundle_fushi_compute.sh`）拷进 `Contents/Frameworks`，缺则 `exit 1` | 302,120 B |
| iOS | `native/fushi_ios_umbrella/build_ios_staticlib.sh [device\|simulator\|all]` | 伞形 `libfushi_ios_umbrella.a`（fushi_p2p + fushi_fsrs + fushi_compute） | `-force_load` 链进 Runner；Runner 构建阶段 `fushi/ios/check_fushi_compute.sh` 在缺 `.a` / `FUSHI_IOS_NATIVE_LDFLAGS` 为空 / `.a` 不导出 `ffc_abi_version` 时失败 | device `.a` 16,526,192 B（三合一） |

- macOS 坑：本机 Mac（macOS 27.2）上 rustc 自带 strip（`strip = true`）+ `MACOSX_DEPLOYMENT_TARGET` 出的
  dylib dlopen 报 `mis-aligned LINKEDIT string pool`，`verify_abi.sh` 查不出来；所以
  `build_macos_dylib.sh` 关掉 cargo strip、改用 `strip -x`，并用 python ctypes 调 `ffc_abi_version`
  冒烟。fushi_fsrs / fushi_p2p 用的是旧写法，可能同样受影响（未验证）。
- 伞形库：`pub extern crate fushi_compute;`（不用 glob 重导出，`ABI_VERSION` 会与 fushi_fsrs 撞名）；
  fushi_compute 加依赖时要同步更新 `native/fushi_ios_umbrella/Cargo.lock`（构建用 `--locked`）。
  因为三个 crate 编成一个 `.a`，iOS 上 fushi_p2p / fushi_fsrs 实际也随之变成必需。
- `verify_abi.sh <二进制> [nm]` 递归抓 `packages/fushi_compute/lib/` 下所有 `'ffc_*'` 字面量，逐个核对
  导出表（ELF / Mach-O / ar 静态库）；规模哨兵下界 11。

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

本 crate GPL-3.0-only（随 app）。依赖：`md4` / `sha2`（RustCrypto）、`crc32fast`，均 MIT OR Apache-2.0；
`brotli-decompressor`（及其 `alloc-no-stdlib` / `alloc-stdlib`）BSD-3-Clause / MIT；都可链进
GPL-3.0 的 app 本体；发版前确认 app 开源许可页带上它们的声明。
