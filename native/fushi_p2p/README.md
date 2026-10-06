# fushi_p2p

iroh（1.2.0，MIT/Apache-2.0）上的 TCP-over-P2P 隧道，dumbpipe 形态，C ABI 给
Dart FFI（`packages/fushi_p2p`，纯 Dart，无 Flutter / 插件依赖）。设计见
`docs/specs/2026-09-28-interconnect-remote-reach.md` §5 / §6。

## 形态

- **主机** `fp2p_host_listen(h, port)`：接受 ALPN `fushi/tcp/1` 的连接；每条双向流
  → `127.0.0.1:port`，双向泵字节。`port = 0` 停止接受。
- **客户端** `fp2p_client_forward(h, nodeId, hint?)`：在 `127.0.0.1:0` 监听并返回端口；
  每条本地 TCP → 在到 `nodeId` 的 iroh 连接上开一条新双向流。连接按节点缓存，
  开流失败（对端重启 / 网络切换）换新连接重试一次；并发的首批本地连接只拨一次号。
- 每条流开头客户端写 4 字节魔数 `FTP1`：QUIC 流在发送方写出首字节前对端看不见，
  服务端先说话的协议会卡死（dumbpipe 用同样的握手字节）；顺带挡掉乱入的流。
- 半关闭：任一方向读到 EOF 就把对侧写端关掉（TCP `shutdown(Write)` / QUIC `finish`），
  两个方向都结束才收尾；任一方向出错就 reset/stop 流、丢掉 TCP。
- 地址提示 `{"directAddrs":["ip:port"],"relayUrl":"https://..."}`：给了就直接拨，
  不必等 n0 DNS / DHT 发现。主机地址集里带着直连地址时应当传。

## 发现与中继

- 默认 `presets::N0`：n0 的 pkarr 发布 + DNS 解析（`iroh.link`）+ n0 公共中继。
- **Mainline DHT 发现：已开启**（cargo feature `dht`，默认开）。iroh 1.x 把它拆成了独立
  crate `iroh-mainline-address-lookup` 0.5。按其默认只往 DHT 发布 **home relay**（`AddrFilter::relay_only`），
  不把本机 IP 泄进公共 DHT。关掉：`cargo build --no-default-features`。
- `relay_urls_json` 非空 = 只用这些自建 `iroh-relay`（`RelayMode::Custom`），见 spec §6。

## 连接状态

`fp2p_conn_status` 读 `Connection::paths()`（iroh 1.x 多路径 API）：选中路径是 IP →
`direct`，是中继 → `relay`；没选中但两种路径都开着 → `mixed`（打洞中）；无连接 → `none`。
`rttMs` 取选中路径的 RTT。出站连接优先，其次入站连接（主机也能查对端）。
桌面开 Clash TUN 等改写 UDP 源端口的环境会长期停在 `relay`，UI 据此提示。

## C ABI 约定

- 永不 panic 过 FFI（每个导出函数 `catch_unwind`；`panic = "unwind"`）。
- 返回的 `char*` 用 `fp2p_string_free` 释放（`fp2p_version` 是静态串除外）。
- 复杂返回值是 JSON：`{"ok":true,...}` / `{"ok":false,"error":"..."}`。
- `fp2p_endpoint_create` 失败返回 NULL，原因用 `fp2p_last_error()`（线程局部）。
- `fp2p_endpoint_close` 同步：iroh 的 `Endpoint::close` 会等对端确认，实测有过连接时
  0.8~2.1 s（空闲端点 ~10 ms），上限 3 s。Dart 侧 UI isolate 用 `closeAsync()`。

## 构建

| 平台 | 命令 | 产物 | 怎么进包 |
|---|---|---|---|
| Windows x64 | `powershell -ExecutionPolicy Bypass -File native/fushi_p2p/build_windows_dll.ps1` | `prebuilt/windows-x64/fushi_p2p.dll` | `fushi/windows/CMakeLists.txt` copy-if-present 到 exe 同级；服务端放 `bundle/lib/` |
| Android | `build_android_so.ps1 [-NdkRoot …] [-Abis …]` / `build_android_so.sh <ndk-root> [abi…]`（cargo-ndk，API 24） | `prebuilt/android/<abi>/libfushi_p2p.so` | `fushi/android/app/build.gradle` 的 `jniLibs.srcDirs` copy-if-present |
| Linux x64 | `build_linux_so.sh` | `prebuilt/linux-x64/libfushi_p2p.so` | `fushi/linux/CMakeLists.txt` copy-if-present 到 `bundle/lib/`；服务端放 `bundle/lib/` |
| macOS | `build_macos_dylib.sh`（只出 arm64：macOS 版不再支持 Intel Mac；部署目标 13.4） | `prebuilt/macos/libfushi_p2p.dylib`（install name `@rpath/…`） | Runner 构建阶段「Bundle fushi_p2p dylib」（`fushi/macos/bundle_fushi_p2p.sh`）copy-if-present 到 `Contents/Frameworks` |
| iOS | `build_ios_staticlib.sh [device\|simulator\|all]`（staticlib，部署目标 15.1） | `prebuilt/ios/{iphoneos,iphonesimulator}/libfushi_p2p.a` + `prebuilt/ios/fushi_p2p.xcconfig` | `fushi/ios/Flutter/{Debug,Release}.xcconfig` 可选 `#include?` 那份 xcconfig → Runner `OTHER_LDFLAGS` 的 `$(FUSHI_P2P_LDFLAGS)` = `-force_load <.a>` + rustc 报的系统库；Dart 侧 `DynamicLibrary.process()` |

- **缺库 = 能力不可用，不是构建失败**：五端都是「prebuilt 有则随包」，没装 Rust 的机器照常出包，
  P2P 开关不出现。发布包的保证在 CI：见下「CI / 发布」。
- iOS 为什么是 staticlib + `-force_load`：App 不能加载自带的任意 dylib；静态库没人引用 `fp2p_*`，
  普通链接会整包丢掉。符号在 dead-strip 下靠 Runner 既有的 `-Wl,-export_dynamic` +
  `STRIP_STYLE = non-global` 保住（与 fushidicts 同一套）。系统库清单来自
  `rustc --print native-static-libs`，脚本每次先 `cargo clean -p fushi_p2p` 保证它真的打印。
- 构建脚本只断言文件存在；`verify_abi.sh <二进制> [nm]` 按 Dart 绑定里 lookup 的 `fp2p_*` 名
  逐个核对导出表（ELF `.so` / Mach-O dylib / iOS Runner 主二进制都支持）。
- 本机（Windows）只能验证 Windows / Android / 语法；macOS、iOS 脚本只在 CI 的 macOS runner 上跑过。

`target/`、`prebuilt/` 不入库。访问 crates.io 不稳时设 `CARGO_HTTP_PROXY`。

## CI / 发布

工具链钉 Rust 1.95.0（`dtolnay/rust-toolchain`），`Swatinem/rust-cache` 按平台分 key，
Android 用 `taiki-e/install-action` 装 cargo-ndk 4.1.2。**失败口径与内置 libtorrent 一致：
构建失败即 job 失败**，不降级出一个悄悄少了 P2P 的包（缺库只在运行期表现为能力隐藏，出包时
没人会发现）。出包后每个平台再核对一次「真的进包了」：

| workflow | 平台 | 构建 | 出包后核对 |
|---|---|---|---|
| `release.yml` | Android arm64-v8a / armeabi-v7a / x86_64 | `build_android_so.sh` + `verify_abi.sh` | 每个 APK 里有 `libflutter.so` 的 ABI 都必须有 `libfushi_p2p.so` |
| `release-desktop.yml` | Windows / macOS arm64 / iOS device | 各自脚本 | bundle 里有 DLL；Frameworks 里 dylib 架构与 app 一致（arm64）+ 符号齐；Runner（未签名包与 App Store archive）导出 `fp2p_*` |
| `release-server.yml` | Linux x64（ubuntu-22.04）/ Windows x64 | 同上 | 拿 bundle 里那一份跑 `packages/fushi_p2p` 真隧道测试 |
| `build-multiplatform.yml`（PR） | Linux / Windows / macOS / iOS | 同上 | Linux、Windows 跑真隧道测试；macOS ctypes 冒烟；iOS 查 Runner 符号 |
| `native-p2p-gate.yml`（PR，paths） | Android 三 ABI | 同上 | ELF 架构 + 符号 |

真隧道测试在库加载失败时整组 skip 且退出码 0，所以 CI 额外断言输出里没有 skip 原因。

体积（release，`opt-level="s"` + fat LTO + `codegen-units=1` + strip，2026-09-28 实测）：
Windows x64 DLL 7.68 MB；Android arm64-v8a 6.6 MB、x86_64 7.4 MB（只依赖 libc/libm/libdl）。
`opt-level="z"` 可再省约 0.57 MB（Windows 7.11 MB），但隧道要扛视频流，QUIC 包处理
变慢不划算，未采用。cargo-ndk 会顺带拷出 `libiroh-<hash>.so` 等无人加载的 cdylib
副本，构建脚本会删掉它们。

## 测试

```
FUSHI_P2P_LIB=<绝对路径>/fushi_p2p.dll dart test   # 在 packages/fushi_p2p 下
```

同进程两个端点经直连地址提示互拨：并发 HTTP、3 MB 请求体回显、8 MB blob 的多段
Range、半关闭、连接状态、停止转发口；库缺失时整组 skip。
