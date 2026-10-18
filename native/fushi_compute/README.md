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

## 加密域（`ffc_crypto_*`，`src/crypto.rs` + `src/crypto/`）

| 符号 | 作用 | 调用方 |
|---|---|---|
| `ffc_crypto_aacs_open / _decrypt_units / _close` | AACS 1 内容解密：求单元密钥 + CBC + 0x47 校验 + 清 CPI + 多 key 轮换重试，一次处理一批 6144 字节单元 | `fushi_engine/.../aacs_content_decoder.dart`（relay 每 32 单元一次） |
| `ffc_crypto_aes128_ecb_decrypt` | unit key 表解密 | 同上 `fromVolumeUniqueKey` |
| `ffc_crypto_aes_cbc_pkcs7_decrypt` | AES-128/192/256-CBC + PKCS7，原地 | HLS 分片（`anime_episode_downloader.dart`）、comico 根 URL |
| `ffc_crypto_aes_cbc_encrypt` | AES-CBC 加密（不填充） | 只给测试造密文 |
| `ffc_crypto_sync_xor` | 云同步「防扫盘」XOR（keystream = SHA-256("hibiki")，**永远不能改**，云端旧文件靠它解开） | `fushi/lib/src/sync/sync_obfuscator.dart` 整块 / 流式 / Range 三条路径 |
| `ffc_crypto_p256_public_key / _sign_sha256 / _verify_sha256` | P-256 ECDSA/SHA-256，RFC 6979 确定性 k，P1363 `r‖s`，不做 low-s 归一 | `LeaderboardIdentity`（排行榜账户 / 安装身份）、`InterconnectDeviceKey`、host 自签 TLS 证书（`fushi_tls_identity.dart`，DER 在 Dart 拼） |

依赖：RustCrypto `aes` 0.8 / `cbc` 0.1 / `p256` 0.13（Apache-2.0 OR MIT）。仓库因此不再直接依赖
pointycastle / basic_utils（pointycastle 仍经 dartssh2 等第三方包间接进 lock）。

一致性：删 Dart 实现前用旧实现（pointycastle 3.9.1 / basic_utils 5.7.0 / Dart XOR）冻结向量
`packages/fushi_compute/test/crypto/crypto_vectors.json`（AACS / HLS）与 `crypto_vectors_v2.json`
（XOR、ECDSA 签名与验签边角、证书 TBS 与 PKCS#8 PEM）。旧实现的两处边角原样保留：空 HLS 分片旧版抛
`RangeError`（pointycastle 越界），现为 `ArgumentError`；验签收混合编码点（`06`/`07` 前缀，不核对 y 奇偶）
由 Dart 侧改写成 `04` 再交原生。证书签名值不同（旧实现 k 随机，现为 RFC 6979），TBS 与 PEM 版式逐字节相同。

**ARMv8 AES**：aes 0.8 在 aarch64 上要 `--cfg aes_armv8` 才用硬件指令（Linux / Android / Apple 运行时
检测），否则退回软件实现（结果相同、慢数倍）。本目录与 `native/fushi_ios_umbrella` 各有一份
`.cargo/config.toml` 带上它；cargo 按**工作目录**找配置（构建脚本都 `cd` 到各自目录），且设了
`RUSTFLAGS` / `CARGO_ENCODED_RUSTFLAGS` 环境变量时会**整个忽略**配置里的 rustflags，那时要在变量里
自己带 `--cfg aes_armv8`。

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
  导出表（ELF / Mach-O / ar 静态库）；规模哨兵下界 21。

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

本 crate GPL-3.0-only（随 app）。依赖：`md4` / `sha2`（RustCrypto）、`crc32fast`，均 MIT OR Apache-2.0，可链进
GPL-3.0 的 app 本体；发版前确认 app 开源许可页带上它们的声明。
