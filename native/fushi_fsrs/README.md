# fushi_fsrs

Fushi SRS（间隔重复）的排程内核：[fsrs-rs](https://github.com/open-spaced-repetition/fsrs-rs)
的薄 C ABI，给 Dart FFI（`packages/fushi_srs/lib/src/ffi/`，纯 Dart，无 Flutter / 插件依赖）用。
五个平台 app 与无头服务端都调这一份 Rust，不维护第二套公式。设计见
`docs/specs/2026-10-14-fushi-srs-design.md`。

## C ABI

| 符号 | 作用 |
|---|---|
| `ffsrs_call(const char*) -> char*` | 请求 JSON → 响应 JSON，按 `op` 分派（见下） |
| `ffsrs_compute_parameters(const char*, AtomicI32* cancel, AtomicI64* progress[2]) -> char*` | 参数优化，阻塞；`cancel` 写非 0 即取消，`progress` 持续写 `[已处理, 总数]`，两者可空 |
| `ffsrs_free_string(char*)` | 释放上面两个返回的串 |
| `ffsrs_zstd_decompress(const u8*, usize, usize* out_len) -> u8*` | zstd 解码（.apkg 新格式），失败返回 NULL |
| `ffsrs_free_bytes(u8*, usize)` | 释放解码缓冲区 |
| `ffsrs_abi_version() -> i32` | ABI 版本（当前 1）；Dart 侧不一致即判不可用 |

响应恒为 `{"ok": …}` 或 `{"error": "…"}`；panic 一律接住转成 error，不越过 FFI。每个 op 带
`algorithm`（`"fsrs6"` 21 参 / `"fsrs7"` 34 参），`params` 空或缺省 = 该算法默认参数；elapsed
一律**小数天**。`op`：`version` / `defaults` / `validate` / `next_states` / `memory_state` /
`memory_state_from_sm2` / `retrievability` / `next_interval` / `evaluate` / `evaluate_tss`。
`ffsrs_compute_parameters` 的请求是 `{"algorithm", "items": [[{"rating","deltaT"},…],…], "cardIds"?}`，
取消后返回 `{"error":"cancelled"}`。

Dart 侧：`FushiFsrs`（`fushi_fsrs_library.dart`，定位 + ABI 核对，库缺失返回 null、永不抛）、
`FushiFsrsBindings`（lookup 名写成字符串字面量，`verify_abi.sh` 从这里抓期望符号集）、
`FfiFsrsEngine implements FsrsEngine`（JSON 往返，错误转 `SrsFsrsException`）、
`NativeSrsOptimizerControl`（calloc 的 int32 取消标志 + int64[2] 进度，地址可跨 isolate 传，
另一端 `fromAddress` 包装）、`FfiFsrsEngine.zstdDecompress`。

库定位顺序（与 `packages/fushi_p2p` 一致）：显式路径（给了就只试它）→ 环境变量
`FUSHI_FSRS_LIB` → exe 同级 → `bin/../lib/<名>`（无头服务端 bundle）→ 裸名（Android APK
native lib 目录、macOS `Contents/Frameworks`、Linux `bundle/lib/`）；iOS 用
`DynamicLibrary.process()`。

## 构建

| 平台 | 命令 | 产物 | 怎么进包 |
|---|---|---|---|
| Windows x64 | `powershell -ExecutionPolicy Bypass -File native/fushi_fsrs/build_windows_dll.ps1` | `prebuilt/windows-x64/fushi_fsrs.dll` | `fushi/windows/CMakeLists.txt` copy-if-present 到 exe 同级；服务端放 `bundle/lib/` |
| Android | `build_android_so.ps1 [-NdkRoot …] [-Abis …]` / `build_android_so.sh <ndk-root> [abi…]`（cargo-ndk，API 24） | `prebuilt/android/<abi>/libfushi_fsrs.so` | `fushi/android/app/build.gradle` 的 `jniLibs.srcDirs` copy-if-present |
| Linux x64 | `build_linux_so.sh` | `prebuilt/linux-x64/libfushi_fsrs.so` | `fushi/linux/CMakeLists.txt` copy-if-present 到 `bundle/lib/`；服务端放 `bundle/lib/` |
| macOS | `build_macos_dylib.sh`（只出 arm64，部署目标 13.4） | `prebuilt/macos/libfushi_fsrs.dylib`（install name `@rpath/…`） | Runner 构建阶段「Bundle fushi_fsrs dylib」（`fushi/macos/bundle_fushi_fsrs.sh`）copy-if-present 到 `Contents/Frameworks` |
| iOS | `native/fushi_ios_umbrella/build_ios_staticlib.sh [device\|simulator\|all]`（伞形 staticlib，部署目标 15.1） | `native/fushi_ios_umbrella/prebuilt/ios/{iphoneos,iphonesimulator}/libfushi_ios_umbrella.a` + `fushi_ios_umbrella.xcconfig` | `fushi/ios/Flutter/{Debug,Release}.xcconfig` 可选 `#include?` 那份 xcconfig → Runner `OTHER_LDFLAGS` 的 `$(FUSHI_IOS_NATIVE_LDFLAGS)`（`-force_load`），见下「iOS」 |

- **缺库 = 能力不可用，不是构建失败**：五端都是「prebuilt 有则随包」，没装 Rust 的机器照常出包。
- 构建脚本只断言文件存在；`verify_abi.sh <二进制> [nm]` 按 Dart 绑定里 lookup 的 `ffsrs_*`
  名逐个核对导出表（ELF `.so` / Mach-O dylib 与可执行文件 / ar 静态库）。
- `target/`、`prebuilt/` 不入库。访问 crates.io / GitHub（fsrs-rs 是钉 rev 的 git 依赖）不稳时设
  `CARGO_HTTP_PROXY`。
- 体积（release，`opt-level="z"` + fat LTO + strip，2026-10-14 本机实测）：Windows x64 DLL
  806,912 B；Android arm64-v8a 936,848 B（NEEDED 只有 libc / libm / libdl）。

### iOS：伞形静态库

每个 Rust staticlib 都自带一整份 Rust std / core / alloc。`libfushi_p2p.a` 与 `libfushi_fsrs.a`
同时 `-force_load` 进 Runner 会撞重复符号（`rust_eh_personality`、`__rdl_alloc` …），不
`-force_load` 又会被当无用成员整个丢掉。所以 iOS 走 `native/fushi_ios_umbrella`：一个 crate
依赖两个 path crate、re-export 两边，编成**一个** staticlib，std 只有一份，同时导出
`fp2p_*`（12 个）与 `ffsrs_*`（6 个）。为此 `native/fushi_p2p/Cargo.toml` 的 crate-type 加了
`rlib`（只用来被伞形 crate 依赖，其余平台产物不变）。伞形 crate 的 `Cargo.lock` 以两个 crate
各自的锁文件合并为种子再解析：fushi_p2p 那边的版本全部保持；fushi_fsrs 那边有 7 个
semver 兼容的小版本被统一到 fushi_p2p 锁的版本（libc、serde_json、syn 3.x、unicode-ident、
zerocopy 等）。

本机（Windows）只能验证到「伞形 crate 编得过、fat LTO 后归档里两组符号都在」：
`cargo build --release --target x86_64-pc-windows-msvc` 出的 `fushi_ios_umbrella.lib` 用
llvm-nm 核对，12 个 `fp2p_*` + 6 个 `ffsrs_*` 全是 `T`。真 iOS 链接只能在 macOS 上验。

`native/fushi_fsrs/build_ios_staticlib.sh` 仍保留：只出单独的 `libfushi_fsrs.a` 与
`FUSHI_FSRS_LDFLAGS`，供「只要 SRS 不要 P2P」的实验构建；**不能**与 fushi_p2p 的单独 .a 同时接。

**接线**（2026-10-15 起，此前 iOS 包里没有 `ffsrs_*`，复习页恒报「排程内核不可用」）：

- `fushi/ios/Flutter/Debug.xcconfig` 与 `Release.xcconfig` 可选
  `#include? "../../../native/fushi_ios_umbrella/prebuilt/ios/fushi_ios_umbrella.xcconfig"`；
  Runner 三个配置的 `OTHER_LDFLAGS` 用 `"$(FUSHI_IOS_NATIVE_LDFLAGS)"`。没编过伞形库 → 变量为空 →
  不链接，P2P 与 SRS 复习都判不可用，Runner 照常构建。
- CI：`build-multiplatform.yml` 的 ios job 与 `release-desktop.yml` 的 iOS job 编伞形库 device 切片，
  持久库名 `ios_native`（`.github/actions/native-store-names/names.sh`，输入
  `native/fushi_ios_umbrella` + `native/fushi_p2p` + `native/fushi_fsrs`），出包后在 Runner（debug
  构建是 `Runner.debug.dylib`）上 `native/fushi_p2p/verify_abi.sh` 与本目录的 `verify_abi.sh` 都跑；
  App Store archive 同样两个都跑。

## CI

| workflow | 平台 | 做什么 |
|---|---|---|
| `build-multiplatform.yml`（PR，路径门） | Windows | 编 DLL → 跑 `packages/fushi_srs` 真 FFI 测试 → 出包后核对 bundle 里有 `fushi_fsrs.dll` |
| | macOS | 编 arm64 dylib + ABI 核对 → 出包后核对 `Contents/Frameworks` 里的 dylib（install name / 架构 / 符号 / ctypes 冒烟） |
| | iOS | 编伞形 staticlib device 切片 + 核对归档两组符号 → 链进 Runner 后再核对 Runner 两组符号 |
| | linux-server | 编 .so + ABI 核对 → 装进服务端 bundle → 拿 bundle 里那份跑真 FFI 测试 |
| `native-fsrs-gate.yml`（PR，paths） | Android 三 ABI | cargo-ndk → ELF 架构 + 符号 |
| | ubuntu | `cargo test --release --locked`（lib.rs 单元测试） |
| `release-server.yml` | Linux x64 / Windows x64 | 编 → 放 `bundle/lib/` → 拿 bundle 里那份跑真 FFI 测试 |

真 FFI 测试在库加载失败时整组 skip 且退出码 0，所以 CI 额外断言输出里没有
`native library not found`。路径门正则（`changes` job）已把 `native/fushi_fsrs/`、
`packages/fushi_srs/` 路由给四个平台 job、`native/fushi_ios_umbrella/` 路由给 iOS，守卫
`fushi/test/build/multiplatform_pr_gating_guard_test.dart`。

`release.yml`（Android APK）与 `release-desktop.yml`（Windows / macOS / iOS，iOS 走伞形库）
的发布包都随带 fushi_fsrs，出包后逐一核对。
fushi_fsrs 编译只要约 20 s（本机，热缓存），没进 native-artifact-store。

## 测试

```
FUSHI_FSRS_LIB=<绝对路径>/fushi_fsrs.dll dart test test/ffi_fsrs_engine_test.dart   # 在 packages/fushi_srs 下
```

不设环境变量时测试按平台找本目录 `prebuilt/` 下的产物。覆盖：默认参数 21 / 34、参数校验
（个数错、FSRS-6/7 参数互换、NaN）、next_states 按评分单调、FSRS-7 小数天敏感、由历史重建
记忆状态、SM-2 换算、可提取度衰减、两种算法在合成数据上的参数优化、从另一个 isolate 在进度
> 0 后取消、外样本 / 训练集内评估、zstd 解码（预生成帧）与坏帧返回 null。库缺失时整组 skip。
Rust 侧单元测试：`cargo test --release`（本目录）。

## 许可

本 crate GPL-3.0-only（随 app）。依赖：fsrs-rs **BSD-3-Clause**、ruzstd **MIT**、serde /
serde_json MIT OR Apache-2.0——都可以链进 GPL-3.0 的 app 本体。BSD-3 与 MIT 要求在二进制
分发的文档里保留版权与许可声明：发版前要确认 app 的开源许可页（`fushi/assets/licenses/`
与 `LicensePage` 注册）带上 fsrs-rs 与 ruzstd 的声明。
