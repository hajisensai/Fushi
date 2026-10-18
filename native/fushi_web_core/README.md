# fushi_web_core

app 内网页浏览（InAppWebView：网页漫画 / 视频站点 / 在线源登录页等）的广告与跟踪拦截内核。
Brave 的 [adblock-rust](https://github.com/brave/adblock-rust)（crate `adblock`）上的薄 C ABI，
给 Dart FFI（`packages/fushi_web_core`，纯 Dart，无 Flutter / 插件依赖）用；WebView 接线在
`fushi/lib/src/web_adblock/`。

## 上游与许可

| 项 | 值 |
|---|---|
| 上游 crate | `adblock` **0.13.3**（crates.io，2026-08-20 发布；2026-10-19 核实为最新稳定版） |
| 上游许可 | **MPL-2.0**（crates.io 元数据 `license = "MPL-2.0"`） |
| 本 crate 许可 | MPL-2.0（与上游一致） |
| 启用特性 | `embedded-domain-resolver`、`full-regex-handling`、`content-blocking`；**关掉**默认的 `single-thread`（引擎因此是 `Send + Sync`，正则缓存走 Mutex） |

MPL-2.0 是文件级 copyleft：adblock-rust 的源码文件改了才需要以 MPL 公开改动，链接进本体
（GPL-3.0）作为「更大作品」分发是许可明文允许的（MPL-2.0 §3.3 / Secondary License）。本仓
**没有改**上游源码，只通过 crates.io 依赖使用。iOS 伞形库 `native/fushi_ios_umbrella`
（GPL-3.0-only）把它与 fushi_p2p / fushi_fsrs 合成一个归档，同理。

版本钉成 `=0.13.3`：adblock-rust 的序列化格式**不保证跨 minor 兼容**。升级时同步 bump 本 crate
的 `version`——Dart 侧引擎缓存键里有 `fwc_version()`，旧缓存会自动作废重编。

过滤列表（EasyList / EasyPrivacy / AdGuard 中文 / 日文）**不随包分发**，运行时从官方地址下载，
见 `packages/fushi_web_core/lib/src/adblock_filter_list_service.dart`。

## C ABI

约定与 `native/fushi_p2p` 一致：前缀 `fwc_`；每个导出函数 `catch_unwind`（`panic = "unwind"`），
永不 panic 过 FFI；返回的 `char*` 用 `fwc_string_free` 释放（`fwc_version` 是静态串除外）；
`fwc_engine_serialize` 的缓冲用 `fwc_bytes_free(ptr, len)` 释放；创建 / 反序列化失败返回 NULL，
原因用 `fwc_last_error()`（线程局部）。

| 函数 | 作用 |
|---|---|
| `fwc_engine_create(texts, count)` | 从 `count` 份过滤列表文本编译引擎 |
| `fwc_engine_serialize(e, &len)` / `fwc_engine_deserialize(data, len)` | 序列化缓存（避免每次启动重编列表） |
| `fwc_engine_check(e, url, source_url, type) -> i32` | 热路径，不分配：`0` 放行 / `1` 拦截 / `2` redirect / `3` 例外规则放行 / `-1` 参数错误 |
| `fwc_engine_check_json(...)` | 同上，完整 JSON（含 `redirect` 替身 data URL、`rewrittenUrl`、命中规则） |
| `fwc_engine_cosmetic(e, url)` | 页面级 JSON：`hideSelectors` / `proceduralActions` / `exceptions` / `injectedScript` / `generichide` |
| `fwc_engine_generic_selectors(e, classes, ids, exceptions)` | 通用 hide 选择器按需取（页面上出现的 class / id，扣掉例外） |
| `fwc_engine_use_resources(e, json)` | 加载 `$redirect` 替身 / `##+js()` scriptlet 资源（不加载时 redirect 退化为普通拦截、scriptlet 为空） |
| `fwc_content_blocking_rules(texts, count)` | 列表 → Apple / WebKit 内容拦截规则 JSON（给不能逐请求拦截的 WKWebView） |
| `fwc_engine_free` / `fwc_string_free` / `fwc_bytes_free` / `fwc_last_error` / `fwc_version` | 生命周期 / 内存 / 诊断 |

实测（Windows x64 release，四份默认列表共 ~5.1 MB 文本，2026-10-19）：编译 110 ms、序列化 8.0 MB /
3 ms、反序列化 25 ms、`check` 约 4.4 µs/次；导出内容拦截规则 16.7 万条（超过 WKContentRuleList
单表上限，Dart 侧截到 5 万条，只丢拦截规则、保留例外）。

## 构建

| 平台 | 命令 | 产物 | 怎么进包 |
|---|---|---|---|
| Windows x64 | `powershell -ExecutionPolicy Bypass -File native/fushi_web_core/build_windows_dll.ps1` | `prebuilt/windows-x64/fushi_web_core.dll` | `fushi/windows/CMakeLists.txt` copy-if-present 到 exe 同级 |
| Android | `build_android_so.ps1 [-NdkRoot …] [-Abis …]` / `build_android_so.sh <ndk-root> [abi…]`（cargo-ndk，API 24） | `prebuilt/android/<abi>/libfushi_web_core.so` | `fushi/android/app/build.gradle` 的 `jniLibs.srcDirs` copy-if-present |
| Linux x64 | `build_linux_so.sh` | `prebuilt/linux-x64/libfushi_web_core.so` | `fushi/linux/CMakeLists.txt` copy-if-present 到 `bundle/lib/` |
| macOS | `build_macos_dylib.sh`（只出 arm64，部署目标 13.4） | `prebuilt/macos/libfushi_web_core.dylib` | Runner 构建阶段「Bundle fushi_web_core dylib」（`fushi/macos/bundle_fushi_web_core.sh`）copy-if-present 到 `Contents/Frameworks` |
| iOS | **并入伞形库** `native/fushi_ios_umbrella/build_ios_staticlib.sh`（与 fushi_p2p / fushi_fsrs 共用一份 Rust std） | `libfushi_ios_umbrella.a` | Runner `-force_load`，Dart 侧 `DynamicLibrary.process()`；本目录的 `build_ios_staticlib.sh` 只留给单独实验 |

- **缺库 = 能力不可用，不是构建失败**：五端都是「prebuilt 有则随包」，WebView 照常、只是不拦。
  发布包的保证在 CI（`build-multiplatform.yml` / `release-desktop.yml` / `release.yml` 先跑构建脚本、
  出包后核对库确实进包；`native-web-core-gate.yml` 管 Android 三 ABI + `cargo test`）。
- `verify_abi.sh <二进制> [nm]`：按 Dart 绑定 `packages/fushi_web_core/lib/src/ffi/fushi_web_core_bindings.dart`
  里 lookup 的 `fwc_*` 名逐个核对导出表（ELF / Mach-O）。期望集取自绑定文件里**单引号包住的**
  `fwc_` 名字面量，注释里别那样写。
- 本机（Windows）实测过 Windows DLL、Android arm64 `.so`、`cargo test`；macOS / iOS / Linux 脚本
  照 fushi_p2p 同构，只在 CI 上跑。

`target/`、`prebuilt/` 不入库。访问 crates.io 不稳时设 `CARGO_HTTP_PROXY` / `HTTPS_PROXY`。
